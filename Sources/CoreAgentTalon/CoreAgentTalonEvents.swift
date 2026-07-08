import Foundation

public enum CoreAgentTalonEventType: String, Codable, Equatable, Sendable {
  case talonEvent = "talon_event"
}

public enum CoreAgentTalonEventSource: String, Codable, Equatable, Sendable {
  case host
  case cron
}

public struct CoreAgentTalonEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let type: CoreAgentTalonEventType
  public let sequence: Int
  public let source: CoreAgentTalonEventSource
  public let timestamp: Date?
  public let conversationID: CoreAgentTalonConversationID?
  public let payload: CoreAgentTalonEventPayload

  public init(
    id: String,
    type: CoreAgentTalonEventType = .talonEvent,
    sequence: Int,
    source: CoreAgentTalonEventSource,
    timestamp: Date? = nil,
    conversationID: CoreAgentTalonConversationID? = nil,
    payload: CoreAgentTalonEventPayload
  ) {
    self.id = id
    self.type = type
    self.sequence = sequence
    self.source = source
    self.timestamp = timestamp
    self.conversationID = conversationID
    self.payload = payload
  }
}

public enum CoreAgentTalonEventPayload: Equatable, Sendable {
  case conversation(CoreAgentTalonConversationEvent)
  case command(CoreAgentTalonCommandEvent)
  case run(CoreAgentTalonRunEvent)
  case cron(CoreAgentTalonCronEvent)
}

extension CoreAgentTalonEventPayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case command
    case conversation
    case cron
    case run
  }

  private enum Kind: String, Codable {
    case command
    case conversation
    case cron
    case run
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .command:
      self = .command(try container.decode(CoreAgentTalonCommandEvent.self, forKey: .command))
    case .conversation:
      self = .conversation(
        try container.decode(CoreAgentTalonConversationEvent.self, forKey: .conversation)
      )
    case .cron:
      self = .cron(try container.decode(CoreAgentTalonCronEvent.self, forKey: .cron))
    case .run:
      self = .run(try container.decode(CoreAgentTalonRunEvent.self, forKey: .run))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .command(let event):
      try container.encode(Kind.command, forKey: .kind)
      try container.encode(event, forKey: .command)
    case .conversation(let event):
      try container.encode(Kind.conversation, forKey: .kind)
      try container.encode(event, forKey: .conversation)
    case .cron(let event):
      try container.encode(Kind.cron, forKey: .kind)
      try container.encode(event, forKey: .cron)
    case .run(let event):
      try container.encode(Kind.run, forKey: .kind)
      try container.encode(event, forKey: .run)
    }
  }
}

public enum CoreAgentTalonConversationTransition: String, Codable, Equatable, Sendable {
  case created
  case resetStarted
  case resetCompleted
  case rotated
}

public struct CoreAgentTalonConversationEvent: Codable, Equatable, Sendable {
  public let transition: CoreAgentTalonConversationTransition
  public let previousConversationID: CoreAgentTalonConversationID?
  public let newConversationID: CoreAgentTalonConversationID?
  public let removingCheckpoint: Bool?

  public init(
    transition: CoreAgentTalonConversationTransition,
    previousConversationID: CoreAgentTalonConversationID? = nil,
    newConversationID: CoreAgentTalonConversationID? = nil,
    removingCheckpoint: Bool? = nil
  ) {
    self.transition = transition
    self.previousConversationID = previousConversationID
    self.newConversationID = newConversationID
    self.removingCheckpoint = removingCheckpoint
  }
}

public enum CoreAgentTalonCommandTransition: String, Codable, Equatable, Sendable {
  case stopRequested
  case newRequested
}

public struct CoreAgentTalonCommandEvent: Codable, Equatable, Sendable {
  public let transition: CoreAgentTalonCommandTransition
  public let targetConversationID: CoreAgentTalonConversationID

  public init(
    transition: CoreAgentTalonCommandTransition,
    targetConversationID: CoreAgentTalonConversationID
  ) {
    self.transition = transition
    self.targetConversationID = targetConversationID
  }
}

public enum CoreAgentTalonRunTransition: String, Codable, Equatable, Sendable {
  case started
  case completed
  case cancelled
  case failed
}

public enum CoreAgentTalonRunStatus: String, Codable, Equatable, Sendable {
  case running
  case completed
  case cancelled
  case failed
}

public struct CoreAgentTalonRunEvent: Codable, Equatable, Sendable {
  public let transition: CoreAgentTalonRunTransition
  public let runID: UUID?
  public let status: CoreAgentTalonRunStatus?
  public let contentCharacterCount: Int?
  public let errorType: String?

  public init(
    transition: CoreAgentTalonRunTransition,
    runID: UUID? = nil,
    status: CoreAgentTalonRunStatus? = nil,
    contentCharacterCount: Int? = nil,
    errorType: String? = nil
  ) {
    self.transition = transition
    self.runID = runID
    self.status = status
    self.contentCharacterCount = contentCharacterCount
    self.errorType = errorType
  }
}

public enum CoreAgentTalonCronTransition: String, Codable, Equatable, Sendable {
  case jobFired
  case jobCreated
  case jobRemoved
}

public struct CoreAgentTalonCronEvent: Codable, Equatable, Sendable {
  public let transition: CoreAgentTalonCronTransition
  public let jobID: String
  public let nextRunAt: Date?
  public let outcome: CoreAgentTalonCronJobOutcome?

  public init(
    transition: CoreAgentTalonCronTransition,
    jobID: String,
    nextRunAt: Date? = nil,
    outcome: CoreAgentTalonCronJobOutcome? = nil
  ) {
    self.transition = transition
    self.jobID = jobID
    self.nextRunAt = nextRunAt
    self.outcome = outcome
  }
}

public actor CoreAgentTalonEventLog {
  private let clock: CoreAgentTalonClock
  private var sequence = 0
  private var entries: [CoreAgentTalonEvent] = []

  public init(clock: CoreAgentTalonClock = .system) {
    self.clock = clock
  }

  @discardableResult
  public func record(
    source: CoreAgentTalonEventSource,
    conversationID: CoreAgentTalonConversationID? = nil,
    payload: CoreAgentTalonEventPayload
  ) -> CoreAgentTalonEvent {
    let nextSequence = sequence
    sequence += 1
    let event = CoreAgentTalonEvent(
      id: "talon_event:\(nextSequence)",
      sequence: nextSequence,
      source: source,
      timestamp: clock.now(),
      conversationID: conversationID,
      payload: payload
    )
    entries.append(event)
    return event
  }

  public func events() -> [CoreAgentTalonEvent] {
    entries
  }
}
