import Foundation
import FoundationModels

/// Metadata accepted by Foundation Models for a single generation request.
public typealias FoundationModelsAgentRequestMetadata = [String: any Sendable & Codable & Equatable]

public enum FoundationModelsAgentError: Error, LocalizedError, Sendable {
  case invalidRetryAttemptCount(Int)
  case invalidDuration(name: String)
  case invalidToolCallLimit(Int)
  case invalidHistoryLimit(Int)
  case invalidObserverQueueLimit(Int)
  case invalidReservedResponseTokens(Int)
  case invalidMaximumUsableFraction(Double)
  case invalidMaximumUsableTokens(Int)
  case duplicateToolName(String)
  case duplicatePluginIdentifier(String)
  case emptyPluginIdentifier
  case emptyCheckpointCompatibilityID
  case concurrentOperation
  case unsafeRetryConfiguration(String)
  case noActiveRun
  case unsupportedCheckpointVersion(Int)
  case checkpointCompatibilityMismatch(expected: String, actual: String)
  case responseTimedOut
  case streamFinishedWithoutResponse
  case toolCallBudgetExceeded(maximum: Int)
  case toolExecutionTimedOut(toolName: String)
  case pluginContextSanitizationFailed
  case pluginContextUnsupportedForDynamicProfile
  case contextMeasurementRequired
  case contextBudgetUnsupportedForDynamicProfile
  case contextBudgetFixedComponentsExceeded(required: Int, limit: Int)
  case contextBudgetExceeded(required: Int, limit: Int)
  case contextTransformStillExceedsBudget(required: Int, limit: Int)
  case invalidContextTransform(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRetryAttemptCount(let count):
      "Retry attempt count must be at least one; received \(count)."
    case .invalidDuration(let name):
      "\(name) must not be negative."
    case .invalidToolCallLimit(let limit):
      "The tool call limit must be zero or greater; received \(limit)."
    case .invalidHistoryLimit(let limit):
      "The transcript history limit must be zero or greater; received \(limit)."
    case .invalidObserverQueueLimit(let limit):
      "The observer queue limit must be at least one; received \(limit)."
    case .invalidReservedResponseTokens(let count):
      "Reserved response tokens must be zero or greater; received \(count)."
    case .invalidMaximumUsableFraction(let fraction):
      "The maximum usable context fraction must be greater than zero and at most one; received \(fraction)."
    case .invalidMaximumUsableTokens(let count):
      "Maximum usable context tokens must be zero or greater; received \(count)."
    case .duplicateToolName(let name):
      "Tool names must be unique; found more than one tool named '\(name)'."
    case .duplicatePluginIdentifier(let identifier):
      "FoundationModelsAgent session plugin identifiers must be unique; found '\(identifier)' more than once."
    case .emptyPluginIdentifier:
      "FoundationModelsAgent session plugin identifiers must not be empty."
    case .emptyCheckpointCompatibilityID:
      "The dynamic profile checkpoint compatibility ID must not be empty."
    case .concurrentOperation:
      "AgentSession already has an operation in flight."
    case .unsafeRetryConfiguration(let reason):
      "Unsafe retry configuration: \(reason)"
    case .noActiveRun:
      "A governed tool was called without an active FoundationModelsAgent run."
    case .unsupportedCheckpointVersion(let version):
      "Checkpoint format version \(version) is unsupported."
    case .checkpointCompatibilityMismatch(let expected, let actual):
      "Checkpoint compatibility revision '\(actual)' does not match the current revision '\(expected)'."
    case .responseTimedOut:
      "The model response exceeded the configured timeout."
    case .streamFinishedWithoutResponse:
      "The model response stream finished without producing a snapshot."
    case .toolCallBudgetExceeded(let maximum):
      "The run exceeded its budget of \(maximum) tool calls."
    case .toolExecutionTimedOut(let toolName):
      "Tool '\(toolName)' exceeded its configured timeout."
    case .pluginContextSanitizationFailed:
      "FoundationModelsAgent could not remove transient plugin context from the native transcript."
    case .pluginContextUnsupportedForDynamicProfile:
      "Dynamic-profile sessions do not support automatic plugin prompt context. Use a profile-owned tool instead."
    case .contextMeasurementRequired:
      "This explicit LanguageModel does not expose native context measurement. Supply an AgentSessionContextMeasurer bound to the selected model."
    case .contextBudgetUnsupportedForDynamicProfile:
      "Dynamic-profile context budgeting is unavailable because the active model and modifier-produced history are opaque. Apply model-aware history policy inside the profile."
    case .contextBudgetFixedComponentsExceeded(let required, let limit):
      "Instructions, tools, prompt, and schema require \(required) tokens, exceeding the usable input limit of \(limit) before history is included."
    case .contextBudgetExceeded(let required, let limit):
      "The request requires \(required) input tokens, exceeding the usable input limit of \(limit)."
    case .contextTransformStillExceedsBudget(let required, let limit):
      "The transformed request still requires \(required) input tokens, exceeding the usable input limit of \(limit)."
    case .invalidContextTransform(let reason):
      "Invalid context transform: \(reason)"
    }
  }
}

public struct FoundationModelsAgentRetryPolicy: Sendable {
  public let maximumAttempts: Int
  public let delay: Duration
  private let classifier: @Sendable (any Error) -> Bool

  public init(
    maximumAttempts: Int,
    delay: Duration = .zero,
    shouldRetry: @escaping @Sendable (any Error) -> Bool
  ) throws {
    guard maximumAttempts >= 1 else {
      throw FoundationModelsAgentError.invalidRetryAttemptCount(maximumAttempts)
    }
    guard delay >= .zero else {
      throw FoundationModelsAgentError.invalidDuration(name: "Retry delay")
    }
    self.maximumAttempts = maximumAttempts
    self.delay = delay
    self.classifier = shouldRetry
  }

  public func shouldRetry(_ error: any Error) -> Bool {
    classifier(error)
  }

  public static let none = try! FoundationModelsAgentRetryPolicy(maximumAttempts: 1) { _ in false }

  public static func transient(maximumAttempts: Int = 3, delay: Duration = .milliseconds(250))
    throws -> Self
  {
    try Self(maximumAttempts: maximumAttempts, delay: delay) { error in
      if error is CancellationError || error is FoundationModelsAgentPolicyError
        || error is FoundationModelsAgentError
      {
        if let coreError = error as? FoundationModelsAgentError, case .responseTimedOut = coreError
        {
          return true
        }
        return false
      }
      guard let modelError = error as? LanguageModelError else {
        return false
      }
      switch modelError {
      case .rateLimited, .timeout:
        return true
      default:
        return false
      }
    }
  }
}

public struct FoundationModelsAgentConfiguration: Sendable {
  public var responseTimeout: Duration?
  public var retryPolicy: FoundationModelsAgentRetryPolicy
  public var transcriptErrorHandlingPolicy: FoundationModelsAgentTranscriptErrorPolicy
  public var savesTranscriptAfterFailedResponse: Bool
  public var allowsRetryAfterToolInvocation: Bool
  public var checkpointFailurePolicy: FoundationModelsAgentCheckpointFailurePolicy
  public var contextBudget: AgentSessionContextBudget?

  public init(
    responseTimeout: Duration? = nil,
    retryPolicy: FoundationModelsAgentRetryPolicy = .none,
    transcriptErrorHandlingPolicy: FoundationModelsAgentTranscriptErrorPolicy = .revert,
    savesTranscriptAfterFailedResponse: Bool = true,
    allowsRetryAfterToolInvocation: Bool = false,
    checkpointFailurePolicy: FoundationModelsAgentCheckpointFailurePolicy = .recordAndContinue,
    contextBudget: AgentSessionContextBudget? = nil
  ) {
    self.responseTimeout = responseTimeout
    self.retryPolicy = retryPolicy
    self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    self.savesTranscriptAfterFailedResponse = savesTranscriptAfterFailedResponse
    self.allowsRetryAfterToolInvocation = allowsRetryAfterToolInvocation
    self.checkpointFailurePolicy = checkpointFailurePolicy
    self.contextBudget = contextBudget
  }

  public static let `default` = FoundationModelsAgentConfiguration()
}

public enum FoundationModelsAgentTranscriptErrorPolicy: Sendable {
  case revert
  case preserve

  var nativeValue: TranscriptErrorHandlingPolicy {
    switch self {
    case .revert:
      .revertTranscript
    case .preserve:
      .preserveTranscript
    }
  }
}

public enum FoundationModelsAgentCheckpointFailurePolicy: Sendable {
  /// Return a successful model response and record the checkpoint error in the run.
  case recordAndContinue
  /// Fail the run when checkpoint durability is mandatory.
  case failRun
}

public enum FoundationModelsAgentInstructionRestorationPolicy: Sendable {
  /// Reuse the instructions encoded in the checkpoint.
  case preserveCheckpoint
  /// Replace checkpoint instructions when current instructions were supplied.
  case replaceWithCurrent
}

public struct FoundationModelsAgentUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int

  public init(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    reasoningTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
  }

  init(_ usage: LanguageModelSession.Usage) {
    self.init(
      inputTokens: usage.input.totalTokenCount,
      cachedInputTokens: usage.input.cachedTokenCount,
      outputTokens: usage.output.totalTokenCount,
      reasoningTokens: usage.output.reasoningTokenCount
    )
  }
}

public struct FoundationModelsAgentResponse<Content>: Sendable where Content: Generable & Sendable {
  public let content: Content
  public let rawContent: GeneratedContent
  public let transcriptEntries: [Transcript.Entry]
  public let usage: FoundationModelsAgentUsage
  public let run: FoundationModelsAgentRun

  public init(
    content: Content,
    rawContent: GeneratedContent,
    transcriptEntries: [Transcript.Entry],
    usage: FoundationModelsAgentUsage,
    run: FoundationModelsAgentRun
  ) {
    self.content = content
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.run = run
  }
}
