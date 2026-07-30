import Foundation
import FoundationModels

public enum AgentSessionMode: String, Codable, Equatable, Sendable {
  case explicitModel
  case dynamicProfile
}

public enum FoundationModelsAgentPluginFailurePolicy: Sendable {
  /// Record the failure and continue without the plugin contribution.
  case recordAndContinue
  /// Fail the run when the plugin operation cannot complete.
  case failRun
}

public struct FoundationModelsAgentPluginFailurePolicies: Sendable {
  public var preparation: FoundationModelsAgentPluginFailurePolicy
  public var completion: FoundationModelsAgentPluginFailurePolicy
  public var sanitization: FoundationModelsAgentPluginFailurePolicy

  public init(
    preparation: FoundationModelsAgentPluginFailurePolicy = .recordAndContinue,
    completion: FoundationModelsAgentPluginFailurePolicy = .recordAndContinue,
    sanitization: FoundationModelsAgentPluginFailurePolicy = .failRun
  ) {
    self.preparation = preparation
    self.completion = completion
    self.sanitization = sanitization
  }

  public static let `default` = FoundationModelsAgentPluginFailurePolicies()
}

/// One deterministic text block contributed before the original user prompt.
public struct FoundationModelsAgentContextBlock: Equatable, Sendable, Identifiable {
  public let id: String
  public let content: String
  public let attributes: [String: String]

  public init(
    id: String,
    content: String,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.content = content
    self.attributes = attributes
  }
}

public struct FoundationModelsAgentPluginEvent: Equatable, Sendable {
  public let name: String
  public let message: String
  public let attributes: [String: String]

  public init(
    name: String,
    message: String,
    attributes: [String: String] = [:]
  ) {
    self.name = name
    self.message = message
    self.attributes = attributes
  }
}

public struct FoundationModelsAgentPluginRequest: Sendable {
  public let runID: UUID
  public let prompt: Prompt
  public let contextQuery: String?
  public let metadata: FoundationModelsAgentRequestMetadata
  public let mode: AgentSessionMode

  public init(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata,
    mode: AgentSessionMode
  ) {
    self.runID = runID
    self.prompt = prompt
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.mode = mode
  }
}

public struct FoundationModelsAgentPluginPreparation: Sendable {
  public let contextBlocks: [FoundationModelsAgentContextBlock]
  public let events: [FoundationModelsAgentPluginEvent]

  public init(
    contextBlocks: [FoundationModelsAgentContextBlock] = [],
    events: [FoundationModelsAgentPluginEvent] = []
  ) {
    self.contextBlocks = contextBlocks
    self.events = events
  }

  public static let empty = FoundationModelsAgentPluginPreparation()
}

public struct FoundationModelsAgentPluginCompletion: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: FoundationModelsAgentRequestMetadata
  public let rawContent: GeneratedContent
  public let transcriptEntries: [Transcript.Entry]
  public let usage: FoundationModelsAgentUsage
  public let mode: AgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata,
    rawContent: GeneratedContent,
    transcriptEntries: [Transcript.Entry],
    usage: FoundationModelsAgentUsage,
    mode: AgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.mode = mode
  }
}

public struct FoundationModelsAgentPluginFailure: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: FoundationModelsAgentRequestMetadata
  public let errorDescription: String
  public let errorType: String
  public let mode: AgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata,
    error: any Error,
    mode: AgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.errorDescription = String(describing: error)
    self.errorType = String(reflecting: Swift.type(of: error))
    self.mode = mode
  }
}

/// Extends a native FoundationModelsAgent run without introducing another model abstraction.
public protocol AgentSessionPlugin: Sendable {
  var identifier: String { get }
  var tools: [any Tool] { get }
  var failurePolicies: FoundationModelsAgentPluginFailurePolicies { get }

  func prepare(for request: FoundationModelsAgentPluginRequest) async throws
    -> FoundationModelsAgentPluginPreparation
  func didComplete(_ completion: FoundationModelsAgentPluginCompletion) async throws
    -> [FoundationModelsAgentPluginEvent]
  func didFail(_ failure: FoundationModelsAgentPluginFailure) async
    -> [FoundationModelsAgentPluginEvent]
}

extension AgentSessionPlugin {
  public var tools: [any Tool] { [] }
  public var failurePolicies: FoundationModelsAgentPluginFailurePolicies { .default }

  public func prepare(for request: FoundationModelsAgentPluginRequest) async throws
    -> FoundationModelsAgentPluginPreparation
  {
    .empty
  }

  public func didComplete(_ completion: FoundationModelsAgentPluginCompletion) async throws
    -> [FoundationModelsAgentPluginEvent]
  {
    []
  }

  public func didFail(_ failure: FoundationModelsAgentPluginFailure) async
    -> [FoundationModelsAgentPluginEvent]
  {
    []
  }
}
