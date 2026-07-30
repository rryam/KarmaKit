import Foundation
import FoundationModels

/// The bounded task sent by a parent model to a foreground child agent.
@Generable
public struct ChildAgentRequest: Sendable {
  /// The focused question or task the child should investigate.
  @Guide(description: "A self-contained task for the child agent to investigate.")
  public let task: String

  public init(task: String) {
    self.task = task
  }
}

/// Limits applied to one foreground child-agent consultation.
public struct ChildAgentLimits: Equatable, Sendable {
  /// Maximum recursive child depth. Zero rejects the consultation.
  public var maximumDepth: Int

  /// Maximum child conversation turns. Foreground consultations use exactly one turn.
  public var maximumTurns: Int

  /// Maximum native tool calls made by the child during its turn.
  public var maximumToolCalls: Int?

  /// Maximum elapsed time for policy, construction, and the child response.
  public var wallClockTimeout: Duration?

  /// Maximum UTF-8 size of successful child content returned to the parent.
  public var maximumOutputBytes: Int

  /// Maximum UTF-8 size of a failure explanation returned to the parent.
  public var maximumFailureBytes: Int

  public init(
    maximumDepth: Int = 1,
    maximumTurns: Int = 1,
    maximumToolCalls: Int? = 4,
    wallClockTimeout: Duration? = .seconds(30),
    maximumOutputBytes: Int = 8_192,
    maximumFailureBytes: Int = 512
  ) {
    self.maximumDepth = maximumDepth
    self.maximumTurns = maximumTurns
    self.maximumToolCalls = maximumToolCalls
    self.wallClockTimeout = wallClockTimeout
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumFailureBytes = maximumFailureBytes
  }

  public static let `default` = ChildAgentLimits()
}

/// Context supplied to child policy and session factories.
public struct ChildAgentInvocation: Sendable {
  public let identifier: String
  public let task: String
  public let depth: Int
  public let limits: ChildAgentLimits

  public init(
    identifier: String,
    task: String,
    depth: Int,
    limits: ChildAgentLimits
  ) {
    self.identifier = identifier
    self.task = task
    self.depth = depth
    self.limits = limits
  }
}

/// An explicit delegation decision made before constructing a child session.
public enum ChildAgentPolicyDecision: Equatable, Sendable {
  case allow
  case deny(reason: String)
}

/// A narrow policy seam for delegation and capability narrowing.
///
/// Parent permissions are never passed to a child implicitly. A policy can
/// carry parent denials into this boundary, deny delegation, or coordinate
/// narrower capabilities with the `sessionFactory`.
public protocol ChildAgentPolicy: Sendable {
  func decision(for invocation: ChildAgentInvocation) async throws -> ChildAgentPolicyDecision
}

/// Allows delegation without granting the child any capabilities.
///
/// The fresh session returned by the definition's factory remains the sole
/// source of the child's tools, plugins, checkpoint scope, and memory scope.
public struct AllowChildAgentPolicy: ChildAgentPolicy {
  public init() {}

  public func decision(for invocation: ChildAgentInvocation) async throws
    -> ChildAgentPolicyDecision
  {
    .allow
  }
}

/// Adapts an application policy closure to ``ChildAgentPolicy``.
public struct ClosureChildAgentPolicy: ChildAgentPolicy {
  private let handler: @Sendable (ChildAgentInvocation) async throws -> ChildAgentPolicyDecision

  public init(
    _ handler:
      @escaping @Sendable (ChildAgentInvocation) async throws -> ChildAgentPolicyDecision
  ) {
    self.handler = handler
  }

  public func decision(for invocation: ChildAgentInvocation) async throws
    -> ChildAgentPolicyDecision
  {
    try await handler(invocation)
  }
}

public enum ChildAgentDefinitionError: Error, LocalizedError, Sendable {
  case emptyIdentifier
  case invalidIdentifier(String)
  case emptyDescription
  case invalidMaximumDepth(Int)
  case invalidMaximumTurns(Int)
  case invalidMaximumToolCalls(Int)
  case invalidWallClockTimeout
  case invalidMaximumOutputBytes(Int)
  case invalidMaximumFailureBytes(Int)

  public var errorDescription: String? {
    switch self {
    case .emptyIdentifier:
      "A child-agent identifier must not be empty."
    case .invalidIdentifier(let value):
      "The child-agent identifier '\(value)' must contain 1–64 ASCII letters, digits, underscores, or hyphens."
    case .emptyDescription:
      "A child-agent description must not be empty."
    case .invalidMaximumDepth(let value):
      "The child-agent maximum depth must be zero or greater; received \(value)."
    case .invalidMaximumTurns(let value):
      "The child-agent maximum turns must be zero or greater; received \(value)."
    case .invalidMaximumToolCalls(let value):
      "The child-agent tool-call limit must be zero or greater; received \(value)."
    case .invalidWallClockTimeout:
      "The child-agent wall-clock timeout must not be negative."
    case .invalidMaximumOutputBytes(let value):
      "The child-agent output limit must be zero or greater; received \(value)."
    case .invalidMaximumFailureBytes(let value):
      "The child-agent failure limit must be zero or greater; received \(value)."
    }
  }
}

/// A fresh-session recipe for one foreground child-agent role.
public struct ChildAgentDefinition: Sendable {
  public let identifier: String
  public let description: String
  public let limits: ChildAgentLimits
  public let policy: any ChildAgentPolicy

  private let makeSession:
    nonisolated(nonsending) @Sendable (ChildAgentInvocation) async throws -> AgentSession

  /// Creates a child definition from a factory that returns a fresh `AgentSession`.
  ///
  /// Do not return a parent session or reuse a previous child session. Construct
  /// the child's tools, plugins, checkpoint, and memory scope explicitly here.
  public init(
    identifier: String,
    description: String,
    limits: ChildAgentLimits = .default,
    policy: any ChildAgentPolicy = AllowChildAgentPolicy(),
    sessionFactory:
      nonisolated(nonsending) @escaping @Sendable (ChildAgentInvocation) async throws
      -> AgentSession
  ) throws {
    try Self.validate(identifier: identifier, description: description, limits: limits)
    self.identifier = identifier
    self.description = description
    self.limits = limits
    self.policy = policy
    self.makeSession = sessionFactory
  }

  /// Creates a fresh dynamic-profile session for every consultation.
  ///
  /// Only transcript history lives inside that newly created session. No
  /// checkpoint store or plugins are installed, so checkpoint and memory scope
  /// are isolated unless the profile itself deliberately reaches shared state.
  public init<
    Profile: LanguageModelSession.DynamicProfile & Sendable & SendableMetatype
  >(
    identifier: String,
    description: String,
    checkpointCompatibilityID: String? = nil,
    limits: ChildAgentLimits = .default,
    policy: any ChildAgentPolicy = AllowChildAgentPolicy(),
    profile makeProfile:
      @escaping @Sendable (ChildAgentInvocation) -> sending Profile
  ) throws {
    let compatibilityID = checkpointCompatibilityID ?? "child-agent:\(identifier)"
    try self.init(
      identifier: identifier,
      description: description,
      limits: limits,
      policy: policy
    ) { invocation in
      try makeChildProfileSession(
        checkpointCompatibilityID: compatibilityID,
        invocation: invocation,
        makeProfile: makeProfile
      )
    }
  }

  fileprivate func session(for invocation: ChildAgentInvocation) async throws -> AgentSession {
    try await makeSession(invocation)
  }

  private static func validate(
    identifier: String,
    description: String,
    limits: ChildAgentLimits
  ) throws {
    guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChildAgentDefinitionError.emptyIdentifier
    }
    let allowedIdentifierCharacters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )
    guard identifier.utf8.count <= 64,
      identifier.unicodeScalars.allSatisfy(allowedIdentifierCharacters.contains)
    else {
      throw ChildAgentDefinitionError.invalidIdentifier(identifier)
    }
    guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChildAgentDefinitionError.emptyDescription
    }
    guard limits.maximumDepth >= 0 else {
      throw ChildAgentDefinitionError.invalidMaximumDepth(limits.maximumDepth)
    }
    guard limits.maximumTurns >= 0 else {
      throw ChildAgentDefinitionError.invalidMaximumTurns(limits.maximumTurns)
    }
    if let maximumToolCalls = limits.maximumToolCalls, maximumToolCalls < 0 {
      throw ChildAgentDefinitionError.invalidMaximumToolCalls(maximumToolCalls)
    }
    if let timeout = limits.wallClockTimeout, timeout < .zero {
      throw ChildAgentDefinitionError.invalidWallClockTimeout
    }
    guard limits.maximumOutputBytes >= 0 else {
      throw ChildAgentDefinitionError.invalidMaximumOutputBytes(limits.maximumOutputBytes)
    }
    guard limits.maximumFailureBytes >= 0 else {
      throw ChildAgentDefinitionError.invalidMaximumFailureBytes(limits.maximumFailureBytes)
    }
  }
}

public enum ChildAgentResultStatus: String, Codable, Equatable, Sendable {
  case success
  case denied
  case cancelled
  case timedOut = "timed_out"
  case depthLimitExceeded = "depth_limit_exceeded"
  case turnLimitExceeded = "turn_limit_exceeded"
  case toolCallLimitExceeded = "tool_call_limit_exceeded"
  case failed
}

public enum ChildAgentFailureKind: String, Codable, Equatable, Sendable {
  case policyDenied = "policy_denied"
  case childCancelled = "child_cancelled"
  case wallClockTimeout = "wall_clock_timeout"
  case childTimeout = "child_timeout"
  case depthLimit = "depth_limit"
  case turnLimit = "turn_limit"
  case toolCallLimit = "tool_call_limit"
  case childFailure = "child_failure"
}

public struct ChildAgentFailure: Codable, Equatable, Sendable {
  public let kind: ChildAgentFailureKind
  public let message: String

  public init(kind: ChildAgentFailureKind, message: String) {
    self.kind = kind
    self.message = message
  }
}

/// Structured tool output returned to the parent model.
///
/// The parent receives this value as bounded JSON and remains responsible for
/// deciding how to answer the user.
public struct ChildAgentResult: Codable, Equatable, Sendable, PromptRepresentable {
  public let identifier: String
  public let status: ChildAgentResultStatus
  public let content: String?
  public let failure: ChildAgentFailure?
  public let wasTruncated: Bool
  public let turnsUsed: Int

  public init(
    identifier: String,
    status: ChildAgentResultStatus,
    content: String? = nil,
    failure: ChildAgentFailure? = nil,
    wasTruncated: Bool = false,
    turnsUsed: Int = 0
  ) {
    self.identifier = identifier
    self.status = status
    self.content = content
    self.failure = failure
    self.wasTruncated = wasTruncated
    self.turnsUsed = turnsUsed
  }

  public var promptRepresentation: Prompt {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fallback =
      #"{"status":"failed","failure":{"kind":"child_failure","message":"Unable to encode child result."}}"#
    let encoded =
      (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
      ?? fallback
    return Prompt(encoded)
  }
}

private struct ChildAgentExecutionState: Sendable {
  let depth: Int
  let maximumDepth: Int

  static let root = ChildAgentExecutionState(depth: 0, maximumDepth: .max)
}

private enum ChildAgentExecutionContext {
  @TaskLocal static var state = ChildAgentExecutionState.root
}

private func makeChildProfileSession<
  Profile: LanguageModelSession.DynamicProfile & Sendable & SendableMetatype
>(
  checkpointCompatibilityID: String,
  invocation: ChildAgentInvocation,
  makeProfile: @escaping @Sendable (ChildAgentInvocation) -> sending Profile
) throws -> AgentSession {
  try AgentSession(checkpointCompatibilityID: checkpointCompatibilityID) {
    makeProfile(invocation)
  }
}

/// A native foreground `Tool` that consults a fresh child `AgentSession`.
public struct ChildAgentTool: Tool {
  public typealias Arguments = ChildAgentRequest
  public typealias Output = ChildAgentResult

  public let definition: ChildAgentDefinition

  public init(definition: ChildAgentDefinition) {
    self.definition = definition
  }

  public var name: String { definition.identifier }
  public var description: String { definition.description }

  @concurrent
  public func call(arguments: ChildAgentRequest) async throws -> ChildAgentResult {
    let executionState = ChildAgentExecutionContext.state
    let limits = definition.limits
    let effectiveMaximumDepth = Swift.min(
      executionState.maximumDepth,
      limits.maximumDepth
    )

    guard executionState.depth < effectiveMaximumDepth else {
      return failure(
        status: .depthLimitExceeded,
        kind: .depthLimit,
        message: "The child-agent depth limit was reached."
      )
    }
    guard limits.maximumTurns >= 1 else {
      return failure(
        status: .turnLimitExceeded,
        kind: .turnLimit,
        message: "The child-agent turn limit does not permit a foreground consultation."
      )
    }
    if limits.wallClockTimeout == .zero {
      return failure(
        status: .timedOut,
        kind: .wallClockTimeout,
        message: "The child-agent consultation has no available wall-clock time."
      )
    }

    var effectiveLimits = limits
    effectiveLimits.maximumDepth = effectiveMaximumDepth
    let invocation = ChildAgentInvocation(
      identifier: definition.identifier,
      task: arguments.task,
      depth: executionState.depth + 1,
      limits: effectiveLimits
    )

    do {
      let operation: @Sendable () async throws -> ChildAgentResult = {
        switch try await definition.policy.decision(for: invocation) {
        case .allow:
          break
        case .deny(let reason):
          return failure(
            status: .denied,
            kind: .policyDenied,
            message: reason
          )
        }

        try Task.checkCancellation()
        let session = try await definition.session(for: invocation)
        let childExecutionState = ChildAgentExecutionState(
          depth: invocation.depth,
          maximumDepth: effectiveMaximumDepth
        )
        let response = try await ChildAgentExecutionContext.$state.withValue(
          childExecutionState
        ) {
          try await session.respondForChild(
            to: invocation.task,
            maximumToolCalls: limits.maximumToolCalls
          )
        }
        let bounded = boundedUTF8(response.content, maximumBytes: limits.maximumOutputBytes)
        return ChildAgentResult(
          identifier: definition.identifier,
          status: .success,
          content: bounded.value,
          wasTruncated: bounded.truncated,
          turnsUsed: 1
        )
      }

      guard let timeout = limits.wallClockTimeout else {
        return try await operation()
      }
      do {
        return try await withFoundationModelsAgentTimeout(timeout, operation: operation)
      } catch is FoundationModelsAgentTimeoutMarker {
        return failure(
          status: .timedOut,
          kind: .wallClockTimeout,
          message: "The child-agent consultation exceeded its wall-clock limit."
        )
      }
    } catch is CancellationError {
      return failure(
        status: .cancelled,
        kind: .childCancelled,
        message: "The child-agent consultation was cancelled."
      )
    } catch {
      return result(for: error)
    }
  }

  private func result(for error: any Error) -> ChildAgentResult {
    if let toolCallError = error as? LanguageModelSession.ToolCallError {
      return result(for: toolCallError.underlyingError)
    }
    if error is CancellationError {
      return failure(
        status: .cancelled,
        kind: .childCancelled,
        message: "The child-agent consultation was cancelled."
      )
    }
    if let agentError = error as? FoundationModelsAgentError {
      switch agentError {
      case .responseTimedOut, .toolExecutionTimedOut:
        return failure(
          status: .timedOut,
          kind: .childTimeout,
          message: "The child-agent model or tool response timed out."
        )
      case .toolCallBudgetExceeded:
        return failure(
          status: .toolCallLimitExceeded,
          kind: .toolCallLimit,
          message: "The child-agent tool-call limit was reached."
        )
      default:
        break
      }
    }
    if let policyError = error as? FoundationModelsAgentPolicyError {
      return failure(
        status: .denied,
        kind: .policyDenied,
        message: policyError.localizedDescription
      )
    }
    return failure(
      status: .failed,
      kind: .childFailure,
      message: "The child-agent consultation failed."
    )
  }

  private func failure(
    status: ChildAgentResultStatus,
    kind: ChildAgentFailureKind,
    message: String
  ) -> ChildAgentResult {
    let bounded = boundedUTF8(
      message,
      maximumBytes: definition.limits.maximumFailureBytes
    )
    return ChildAgentResult(
      identifier: definition.identifier,
      status: status,
      failure: ChildAgentFailure(kind: kind, message: bounded.value),
      wasTruncated: bounded.truncated
    )
  }
}

private func boundedUTF8(_ value: String, maximumBytes: Int) -> (value: String, truncated: Bool) {
  guard value.utf8.count > maximumBytes else {
    return (value, false)
  }

  var result = ""
  var byteCount = 0
  for character in value {
    let rendered = String(character)
    let characterBytes = rendered.utf8.count
    guard byteCount + characterBytes <= maximumBytes else {
      break
    }
    result.append(character)
    byteCount += characterBytes
  }
  return (result, true)
}
