import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

public struct CoreAgentDeepSubagentRequest: Sendable {
  public let taskID: UUID
  public let subagentType: String
  public let description: String
  public let parentRunID: UUID?
  public let parentToolInvocationID: UUID?
  public let budget: CoreAgentDeepSubagentBudgetState?

  public init(
    taskID: UUID,
    subagentType: String,
    description: String,
    parentRunID: UUID? = nil,
    parentToolInvocationID: UUID? = nil,
    budget: CoreAgentDeepSubagentBudgetState? = nil
  ) {
    self.taskID = taskID
    self.subagentType = subagentType
    self.description = description
    self.parentRunID = parentRunID
    self.parentToolInvocationID = parentToolInvocationID
    self.budget = budget
  }
}

public struct CoreAgentDeepSubagentResult: Sendable {
  public let subagentName: String
  public let content: String
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let checkpointKey: String?
  public let transcriptEntryCount: Int?
  public let usage: CoreAgentUsage?

  public init(
    subagentName: String,
    content: String,
    childRunID: UUID? = nil,
    childReceiptRootHash: String? = nil,
    checkpointKey: String? = nil,
    transcriptEntryCount: Int? = nil,
    usage: CoreAgentUsage? = nil
  ) {
    self.subagentName = subagentName
    self.content = content
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.checkpointKey = checkpointKey
    self.transcriptEntryCount = transcriptEntryCount
    self.usage = usage
  }
}

public struct CoreAgentDeepSubagentFailure: Error, Sendable {
  public let subagentName: String
  public let checkpointKey: String?
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let underlyingErrorDescription: String
  public let underlyingErrorType: String

  public init(
    subagentName: String,
    checkpointKey: String?,
    childRunID: UUID?,
    childReceiptRootHash: String?,
    underlyingError: any Error
  ) {
    self.subagentName = subagentName
    self.checkpointKey = checkpointKey
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.underlyingErrorDescription = String(describing: underlyingError)
    self.underlyingErrorType = String(reflecting: Swift.type(of: underlyingError))
  }
}

public protocol CoreAgentDeepSubagent: Sendable {
  var name: String { get }
  var description: String { get }

  func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
}

public struct ClosureCoreAgentDeepSubagent: CoreAgentDeepSubagent {
  public let name: String
  public let description: String
  private let handler:
    @Sendable (CoreAgentDeepSubagentRequest) async throws -> CoreAgentDeepSubagentResult

  public init(
    name: String,
    description: String,
    handler:
      @escaping @Sendable (CoreAgentDeepSubagentRequest) async throws
      -> CoreAgentDeepSubagentResult
  ) {
    self.name = name
    self.description = description
    self.handler = handler
  }

  public func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
  {
    try await handler(request)
  }
}

public struct CoreAgentDeepSessionSubagent<Model: LanguageModel>: CoreAgentDeepSubagent {
  public let name: String
  public let description: String

  private let model: Model
  private let tools: [any Tool]
  private let instructions: Instructions?
  private let configuration: CoreAgentConfiguration
  private let toolConfiguration: CoreAgentToolConfiguration
  private let checkpointStore: (any CoreAgentCheckpointStore)?
  private let checkpointKey: @Sendable (CoreAgentDeepSubagentRequest) -> String
  private let transcriptRetention: CoreAgentTranscriptRetention
  private let requiresMatchingToolset: Bool
  private let plugins: [any CoreAgentSessionPlugin]
  private let metadata: @Sendable (CoreAgentDeepSubagentRequest) -> CoreAgentRequestMetadata

  public init(
    name: String,
    description: String,
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .denyAll,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: (@escaping @Sendable (CoreAgentDeepSubagentRequest) -> String) =
      Self.defaultCheckpointKey,
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    plugins: [any CoreAgentSessionPlugin] = [],
    metadata: (@escaping @Sendable (CoreAgentDeepSubagentRequest) -> CoreAgentRequestMetadata) =
      Self.defaultMetadata
  ) {
    self.name = name
    self.description = description
    self.model = model
    self.tools = tools
    self.instructions = instructions
    self.configuration = configuration
    self.toolConfiguration = toolConfiguration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.transcriptRetention = transcriptRetention
    self.requiresMatchingToolset = requiresMatchingToolset
    self.plugins = plugins
    self.metadata = metadata
  }

  public func run(request: CoreAgentDeepSubagentRequest) async throws
    -> CoreAgentDeepSubagentResult
  {
    let key = checkpointKey(request)
    let durableKeyCandidate = checkpointStore == nil ? nil : key
    var session: CoreAgentSession?
    do {
      let child = try CoreAgentSession(
        model: model,
        tools: tools,
        instructions: instructions,
        configuration: configuration,
        toolConfiguration: toolConfiguration,
        checkpointStore: checkpointStore,
        checkpointKey: key,
        transcriptRetention: transcriptRetention,
        requiresMatchingToolset: requiresMatchingToolset,
        plugins: plugins
      )
      session = child
      let response = try await child.respond(
        to: request.description,
        metadata: metadata(request),
        contextQuery: request.description
      )
      let receipt = try CoreAgentRunReceipt(run: response.run)
      let checkpointFailed = response.run.events.contains {
        $0.kind == .transcriptCheckpointFailed
      }
      return CoreAgentDeepSubagentResult(
        subagentName: name,
        content: response.content,
        childRunID: response.run.id,
        childReceiptRootHash: receipt.rootHash,
        checkpointKey: checkpointFailed ? nil : durableKeyCandidate,
        transcriptEntryCount: response.transcriptEntries.count,
        usage: response.usage
      )
    } catch {
      let run = await session?.lastRun()
      let checkpointFailed =
        run?.events.contains {
          $0.kind == .transcriptCheckpointFailed
        } ?? false
      let receipt = run.flatMap { try? CoreAgentRunReceipt(run: $0) }
      throw CoreAgentDeepSubagentFailure(
        subagentName: name,
        checkpointKey: run == nil || checkpointFailed ? nil : durableKeyCandidate,
        childRunID: run?.id,
        childReceiptRootHash: receipt?.rootHash,
        underlyingError: error
      )
    }
  }

  public static func defaultCheckpointKey(
    request: CoreAgentDeepSubagentRequest
  ) -> String {
    let subagent = sanitizePathComponent(request.subagentType)
    let taskID = request.taskID.uuidString.lowercased()
    return "coreagent-deep/subagents/\(subagent)/\(taskID)"
  }

  public static func defaultMetadata(
    request: CoreAgentDeepSubagentRequest
  ) -> CoreAgentRequestMetadata {
    [:]
  }

  private static func sanitizePathComponent(_ value: String) -> String {
    CoreAgentDeepSubagentIdentifier.sanitized(value, fallback: "subagent")
  }
}

public enum CoreAgentDeepSubagentRunStatus: String, Codable, Equatable, Sendable {
  case completed
  case denied
  case failed
}

public struct CoreAgentDeepSubagentAuditConfiguration: Sendable {
  public var redactionPolicy: CoreAgentRedactionPolicy
  public var maximumErrorCharacters: Int
  public var maximumDescriptionCharacters: Int

  public init(
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    maximumErrorCharacters: Int = 2_000,
    maximumDescriptionCharacters: Int = 2_000
  ) {
    self.redactionPolicy = redactionPolicy
    self.maximumErrorCharacters = max(0, maximumErrorCharacters)
    self.maximumDescriptionCharacters = max(0, maximumDescriptionCharacters)
  }

  public func summarize(error: any Error) -> String {
    let raw: String
    if let failure = error as? CoreAgentDeepSubagentFailure {
      raw = failure.underlyingErrorDescription
    } else {
      raw = String(describing: error)
    }
    let redacted = redactionPolicy.redact(raw)
    guard redacted.count > maximumErrorCharacters else {
      return redacted
    }
    let end = redacted.index(redacted.startIndex, offsetBy: maximumErrorCharacters)
    return "\(redacted[..<end])..."
  }

  public func errorType(for error: any Error) -> String {
    if let failure = error as? CoreAgentDeepSubagentFailure {
      return failure.underlyingErrorType
    }
    return String(reflecting: Swift.type(of: error))
  }

  public func summarize(description: String) -> String {
    let redacted = redactionPolicy.redact(description)
    guard redacted.count > maximumDescriptionCharacters else {
      return redacted
    }
    let end = redacted.index(redacted.startIndex, offsetBy: maximumDescriptionCharacters)
    return "\(redacted[..<end])..."
  }
}

public struct CoreAgentDeepSubagentAuditRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let subagentName: String
  public let description: String
  public let parentRunID: UUID?
  public let parentToolInvocationID: UUID?
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let checkpointKey: String?
  public let status: CoreAgentDeepSubagentRunStatus
  public let errorDescription: String?
  public let errorType: String?
  public let outputCharacterCount: Int?
  public let budgetDepth: Int?
  public let budgetDelegationsUsed: Int?
  public let budgetMaximumDepth: Int?
  public let budgetMaximumDelegations: Int?
  public let budgetTotalTokensUsed: Int?
  public let budgetMaximumTotalTokens: Int?
  public let startedAt: Date
  public let endedAt: Date

  public init(
    id: UUID,
    subagentName: String,
    description: String,
    parentRunID: UUID?,
    parentToolInvocationID: UUID?,
    childRunID: UUID?,
    childReceiptRootHash: String?,
    checkpointKey: String?,
    status: CoreAgentDeepSubagentRunStatus,
    errorDescription: String?,
    errorType: String? = nil,
    outputCharacterCount: Int?,
    budget: CoreAgentDeepSubagentBudgetState? = nil,
    startedAt: Date,
    endedAt: Date
  ) {
    self.id = id
    self.subagentName = subagentName
    self.description = description
    self.parentRunID = parentRunID
    self.parentToolInvocationID = parentToolInvocationID
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.checkpointKey = checkpointKey
    self.status = status
    self.errorDescription = errorDescription
    self.errorType = errorType
    self.outputCharacterCount = outputCharacterCount
    self.budgetDepth = budget?.depth
    self.budgetDelegationsUsed = budget?.delegationsUsed
    self.budgetMaximumDepth = budget?.maximumDepth
    self.budgetMaximumDelegations = budget?.maximumDelegations
    self.budgetTotalTokensUsed = budget?.totalTokensUsed
    self.budgetMaximumTotalTokens = budget?.maximumTotalTokens
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}

public actor CoreAgentDeepSubagentAuditStore {
  private var values: [CoreAgentDeepSubagentAuditRecord] = []

  public init() {}

  public func append(_ record: CoreAgentDeepSubagentAuditRecord) {
    values.append(record)
  }

  public func records() -> [CoreAgentDeepSubagentAuditRecord] {
    values
  }
}
