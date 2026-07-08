import CoreAgent
import Foundation

public typealias CoreAgentTalonSessionFactory =
  @Sendable (CoreAgentTalonConversationID) async throws -> CoreAgentSession
public typealias CoreAgentTalonConversationIDGenerator =
  @Sendable (CoreAgentTalonConversationID) -> CoreAgentTalonConversationID

public struct CoreAgentTalonRunCompletion: Codable, Equatable, Sendable {
  public let conversationID: CoreAgentTalonConversationID
  public let runID: UUID
  public let content: String

  public init(conversationID: CoreAgentTalonConversationID, runID: UUID, content: String) {
    self.conversationID = conversationID
    self.runID = runID
    self.content = content
  }
}

public enum CoreAgentTalonCancellationReason: String, Codable, Equatable, Sendable {
  case stopRequested
  case taskCancelled
}

public struct CoreAgentTalonRunCancellation: Codable, Equatable, Sendable {
  public let conversationID: CoreAgentTalonConversationID
  public let reason: CoreAgentTalonCancellationReason

  public init(
    conversationID: CoreAgentTalonConversationID,
    reason: CoreAgentTalonCancellationReason
  ) {
    self.conversationID = conversationID
    self.reason = reason
  }
}

public struct CoreAgentTalonRunFailure: Codable, Equatable, Sendable {
  public let conversationID: CoreAgentTalonConversationID
  public let errorType: String
  public let message: String

  public init(conversationID: CoreAgentTalonConversationID, errorType: String, message: String) {
    self.conversationID = conversationID
    self.errorType = errorType
    self.message = message
  }
}

public enum CoreAgentTalonRunResult: Codable, Equatable, Sendable {
  case completed(CoreAgentTalonRunCompletion)
  case cancelled(CoreAgentTalonRunCancellation)
  case failed(CoreAgentTalonRunFailure)

  public var status: CoreAgentTalonRunStatus {
    switch self {
    case .completed:
      .completed
    case .cancelled:
      .cancelled
    case .failed:
      .failed
    }
  }

  public var content: String? {
    if case .completed(let completion) = self {
      return completion.content
    }
    return nil
  }
}

public actor CoreAgentTalonHost {
  private let sessionFactory: CoreAgentTalonSessionFactory
  private let conversationIDGenerator: CoreAgentTalonConversationIDGenerator
  private let eventLog: CoreAgentTalonEventLog
  private var conversations: [CoreAgentTalonConversationID: CoreAgentTalonConversation] = [:]
  /// In-flight conversation creations keyed by id. Because the actor suspends across the
  /// `await sessionFactory(id)` call, two concurrent callers for the same *new* id would
  /// otherwise both pass the `conversations[id] == nil` check and each build a session,
  /// with the second overwriting the first. Concurrent callers await the same creation
  /// task instead so exactly one session is created per id.
  private var creatingConversations:
    [CoreAgentTalonConversationID: Task<CoreAgentTalonConversation, any Error>] = [:]
  /// Conversation ids currently being replaced by `newConversation(replacing:)`. The
  /// replacement suspends across `conversation(for:)` and `reset(to:)`, so without a claim
  /// two concurrent replacements of the same source (e.g. a duplicated `/new` delivery)
  /// would both pass the guards and both rotate the *shared* source conversation. With the
  /// default id generator each mints a distinct new id, so the two would alias two map keys
  /// onto one conversation actor whose internal id becomes the last writer. Reserving both
  /// the source and the target id for the whole critical section serializes replacements and
  /// fails the losers closed.
  private var replacingConversations: Set<CoreAgentTalonConversationID> = []

  public init(
    clock: CoreAgentTalonClock = .system,
    eventLog: CoreAgentTalonEventLog? = nil,
    conversationIDGenerator: @escaping CoreAgentTalonConversationIDGenerator = { _ in
      CoreAgentTalonConversationID(UUID().uuidString.lowercased())
    },
    sessionFactory: @escaping CoreAgentTalonSessionFactory
  ) {
    self.sessionFactory = sessionFactory
    self.conversationIDGenerator = conversationIDGenerator
    self.eventLog = eventLog ?? CoreAgentTalonEventLog(clock: clock)
  }

  public func respond(
    to prompt: String,
    conversationID: CoreAgentTalonConversationID
  ) async -> CoreAgentTalonRunResult {
    do {
      let conversation = try await conversation(for: conversationID)
      return await conversation.run(prompt: prompt)
    } catch {
      let failure = CoreAgentTalonRunFailure(
        conversationID: conversationID,
        errorType: String(reflecting: Swift.type(of: error)),
        message: String(describing: error)
      )
      await eventLog.record(
        source: .host,
        conversationID: conversationID,
        payload: .run(
          CoreAgentTalonRunEvent(
            transition: .failed,
            status: .failed,
            errorType: failure.errorType
          )
        )
      )
      return .failed(failure)
    }
  }

  public func stop(
    conversationID: CoreAgentTalonConversationID
  ) async -> CoreAgentTalonRunResult {
    await eventLog.record(
      source: .host,
      conversationID: conversationID,
      payload: .command(
        CoreAgentTalonCommandEvent(
          transition: .stopRequested,
          targetConversationID: conversationID
        )
      )
    )
    guard let conversation = conversations[conversationID] else {
      return .cancelled(
        CoreAgentTalonRunCancellation(
          conversationID: conversationID,
          reason: .stopRequested
        )
      )
    }
    return await conversation.stop()
  }

  public func newConversation(
    replacing conversationID: CoreAgentTalonConversationID,
    removingCheckpoint: Bool = true
  ) async throws -> CoreAgentTalonConversationID {
    await eventLog.record(
      source: .host,
      conversationID: conversationID,
      payload: .command(
        CoreAgentTalonCommandEvent(
          transition: .newRequested,
          targetConversationID: conversationID
        )
      )
    )
    let newID = conversationIDGenerator(conversationID)
    guard newID != conversationID, conversations[newID] == nil,
      creatingConversations[newID] == nil,
      !replacingConversations.contains(conversationID),
      !replacingConversations.contains(newID)
    else {
      throw CoreAgentTalonHostError.duplicateConversationID(newID)
    }
    // Claim both the source and target ids synchronously (no await in between) so a
    // concurrent replacement of the same source, or one targeting the same new id, fails
    // the guard above instead of racing through the suspensions below.
    replacingConversations.insert(conversationID)
    replacingConversations.insert(newID)
    defer {
      replacingConversations.remove(conversationID)
      replacingConversations.remove(newID)
    }
    let conversation = try await conversation(for: conversationID)
    // Re-validate after the suspension: a concurrent caller may have claimed `newID` (or
    // created its own conversation for it) between the generator call and here.
    guard conversations[newID] == nil, creatingConversations[newID] == nil else {
      throw CoreAgentTalonHostError.duplicateConversationID(newID)
    }
    try await conversation.reset(to: newID, removingCheckpoint: removingCheckpoint)
    conversations.removeValue(forKey: conversationID)
    conversations[newID] = conversation
    return newID
  }

  public func events() async -> [CoreAgentTalonEvent] {
    await eventLog.events()
  }

  public func activeConversationIDs() -> [CoreAgentTalonConversationID] {
    conversations.keys.sorted { $0.rawValue < $1.rawValue }
  }

  private func conversation(
    for id: CoreAgentTalonConversationID
  ) async throws -> CoreAgentTalonConversation {
    if let conversation = conversations[id] {
      return conversation
    }
    // Coalesce concurrent creations for the same id onto a single task so the
    // `await sessionFactory(id)` suspension cannot produce duplicate sessions.
    if let existing = creatingConversations[id] {
      return try await existing.value
    }
    let creation = Task<CoreAgentTalonConversation, any Error> { [sessionFactory, eventLog] in
      let session = try await sessionFactory(id)
      let conversation = CoreAgentTalonConversation(id: id, session: session, eventLog: eventLog)
      await eventLog.record(
        source: .host,
        conversationID: id,
        payload: .conversation(CoreAgentTalonConversationEvent(transition: .created))
      )
      return conversation
    }
    creatingConversations[id] = creation
    defer { creatingConversations[id] = nil }
    do {
      let conversation = try await creation.value
      conversations[id] = conversation
      return conversation
    } catch {
      throw error
    }
  }
}

private actor CoreAgentTalonConversation {
  private var id: CoreAgentTalonConversationID
  private let session: CoreAgentSession
  private let eventLog: CoreAgentTalonEventLog
  private let lock = CoreAgentTalonAsyncLock()
  private var inFlight: Task<CoreAgentTalonRunResult, Never>?

  init(
    id: CoreAgentTalonConversationID,
    session: CoreAgentSession,
    eventLog: CoreAgentTalonEventLog
  ) {
    self.id = id
    self.session = session
    self.eventLog = eventLog
  }

  func run(prompt: String) async -> CoreAgentTalonRunResult {
    await lock.withLock {
      await self.performRun(prompt: prompt)
    }
  }

  func stop() -> CoreAgentTalonRunResult {
    inFlight?.cancel()
    return .cancelled(
      CoreAgentTalonRunCancellation(conversationID: id, reason: .stopRequested)
    )
  }

  func reset(to newID: CoreAgentTalonConversationID, removingCheckpoint: Bool) async throws {
    try await lock.withLock {
      let previousID = await self.currentID()
      await self.recordConversationResetStarted(
        previousID: previousID,
        newID: newID,
        removingCheckpoint: removingCheckpoint
      )
      try await self.session.reset(removingCheckpoint: removingCheckpoint)
      await self.updateID(newID)
      await self.recordConversationResetCompleted(previousID: previousID, newID: newID)
    }
  }

  private func performRun(prompt: String) async -> CoreAgentTalonRunResult {
    let conversationID = id
    let session = session
    let eventLog = eventLog
    let task = Task { @Sendable () -> CoreAgentTalonRunResult in
      await eventLog.record(
        source: .host,
        conversationID: conversationID,
        payload: .run(CoreAgentTalonRunEvent(transition: .started, status: .running))
      )
      do {
        try Task.checkCancellation()
        let response = try await session.respond(to: prompt)
        try Task.checkCancellation()
        await eventLog.record(
          source: .host,
          conversationID: conversationID,
          payload: .run(
            CoreAgentTalonRunEvent(
              transition: .completed,
              runID: response.run.id,
              status: .completed,
              contentCharacterCount: response.content.count
            )
          )
        )
        return .completed(
          CoreAgentTalonRunCompletion(
            conversationID: conversationID,
            runID: response.run.id,
            content: response.content
          )
        )
      } catch is CancellationError {
        await eventLog.record(
          source: .host,
          conversationID: conversationID,
          payload: .run(CoreAgentTalonRunEvent(transition: .cancelled, status: .cancelled))
        )
        return .cancelled(
          CoreAgentTalonRunCancellation(conversationID: conversationID, reason: .taskCancelled)
        )
      } catch {
        let errorType = String(reflecting: Swift.type(of: error))
        await eventLog.record(
          source: .host,
          conversationID: conversationID,
          payload: .run(
            CoreAgentTalonRunEvent(
              transition: .failed,
              status: .failed,
              errorType: errorType
            )
          )
        )
        return .failed(
          CoreAgentTalonRunFailure(
            conversationID: conversationID,
            errorType: errorType,
            message: String(describing: error)
          )
        )
      }
    }
    inFlight = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    inFlight = nil
    return result
  }

  private func currentID() -> CoreAgentTalonConversationID {
    id
  }

  private func updateID(_ newID: CoreAgentTalonConversationID) {
    id = newID
  }

  private func recordConversationResetStarted(
    previousID: CoreAgentTalonConversationID,
    newID: CoreAgentTalonConversationID,
    removingCheckpoint: Bool
  ) async {
    await eventLog.record(
      source: .host,
      conversationID: previousID,
      payload: .conversation(
        CoreAgentTalonConversationEvent(
          transition: .resetStarted,
          previousConversationID: previousID,
          newConversationID: newID,
          removingCheckpoint: removingCheckpoint
        )
      )
    )
  }

  private func recordConversationResetCompleted(
    previousID: CoreAgentTalonConversationID,
    newID: CoreAgentTalonConversationID
  ) async {
    await eventLog.record(
      source: .host,
      conversationID: newID,
      payload: .conversation(
        CoreAgentTalonConversationEvent(
          transition: .resetCompleted,
          previousConversationID: previousID,
          newConversationID: newID
        )
      )
    )
    await eventLog.record(
      source: .host,
      conversationID: newID,
      payload: .conversation(
        CoreAgentTalonConversationEvent(
          transition: .rotated,
          previousConversationID: previousID,
          newConversationID: newID
        )
      )
    )
  }
}
