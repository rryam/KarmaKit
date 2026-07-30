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
  /// Maximum consultations started by this child tool in one parent run.
  public var maximumChildrenPerParentRun: Int

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
    maximumChildrenPerParentRun: Int = 4,
    maximumDepth: Int = 1,
    maximumTurns: Int = 1,
    maximumToolCalls: Int? = 4,
    wallClockTimeout: Duration? = .seconds(30),
    maximumOutputBytes: Int = 8_192,
    maximumFailureBytes: Int = 512
  ) {
    self.maximumChildrenPerParentRun = maximumChildrenPerParentRun
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
  /// Canonical lineage assigned before policy or session construction.
  public let lineage: AgentRunLineage
  public let limits: ChildAgentLimits

  public var depth: Int { lineage.depth.rawValue }

  public init(
    identifier: String,
    task: String,
    lineage: AgentRunLineage,
    limits: ChildAgentLimits
  ) {
    self.identifier = identifier
    self.task = task
    self.lineage = lineage
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
  case invalidMaximumChildrenPerParentRun(Int)
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
    case .invalidMaximumChildrenPerParentRun(let value):
      "The per-parent child limit must be zero or greater; received \(value)."
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
  public let resultRedactionPolicy: FoundationModelsAgentRedactionPolicy

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
    resultRedactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    sessionFactory:
      nonisolated(nonsending) @escaping @Sendable (ChildAgentInvocation) async throws
      -> AgentSession
  ) throws {
    try Self.validate(identifier: identifier, description: description, limits: limits)
    self.identifier = identifier
    self.description = description
    self.limits = limits
    self.policy = policy
    self.resultRedactionPolicy = resultRedactionPolicy
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
    resultRedactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    toolGovernance: DynamicProfileToolGovernanceConfiguration? = nil,
    profile makeProfile:
      @escaping @Sendable (ChildAgentInvocation) -> sending Profile
  ) throws {
    let compatibilityID = checkpointCompatibilityID ?? "child-agent:\(identifier)"
    try self.init(
      identifier: identifier,
      description: description,
      limits: limits,
      policy: policy,
      resultRedactionPolicy: resultRedactionPolicy
    ) { invocation in
      try makeChildProfileSession(
        checkpointCompatibilityID: compatibilityID,
        invocation: invocation,
        limits: limits,
        toolGovernance: toolGovernance,
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
    guard limits.maximumChildrenPerParentRun >= 0 else {
      throw ChildAgentDefinitionError.invalidMaximumChildrenPerParentRun(
        limits.maximumChildrenPerParentRun)
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

/// Structured tool output returned to the parent model.
///
/// `taskResult` is the package's canonical settlement/evidence model. The
/// receipt is available to application code, while the parent model receives a
/// bounded JSON projection containing only the settlement and bounded content.
public enum ChildAgentResultError: Error, LocalizedError, Equatable, Sendable {
  case invalidTurnsUsed(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidTurnsUsed(let turns):
      "A foreground child result must use zero or one turn; received \(turns)."
    }
  }
}

public struct ChildAgentResult: Codable, Equatable, Sendable, PromptRepresentable {
  public let identifier: String
  public let taskResult: AgentTaskResult
  public let content: String?
  public let receipt: FoundationModelsAgentRunReceipt?
  public let wasTruncated: Bool
  public let turnsUsed: Int

  public var status: AgentTaskSettlementStatus { taskResult.status }

  private enum CodingKeys: String, CodingKey {
    case identifier
    case taskResult
    case content
    case receipt
    case wasTruncated
    case turnsUsed
  }

  public init(
    identifier: String,
    taskResult: AgentTaskResult,
    content: String? = nil,
    receipt: FoundationModelsAgentRunReceipt? = nil,
    wasTruncated: Bool = false,
    turnsUsed: Int = 0
  ) throws {
    guard let taskID = taskResult.lineage.taskID else {
      throw AgentExecutionEvidenceError.invalidDescendantLineage
    }
    guard (0...1).contains(turnsUsed) else {
      throw ChildAgentResultError.invalidTurnsUsed(turnsUsed)
    }
    switch (receipt, taskResult.receipt) {
    case (.none, .none):
      break
    case (.some(let receipt), .some(let reference)):
      guard receipt.verify(),
        receipt.runID == taskResult.lineage.runID.rawValue,
        receipt.lineage == taskResult.lineage,
        reference.runID == taskResult.lineage.runID,
        reference.rootHash == receipt.rootHash
      else {
        throw AgentExecutionEvidenceError.taskReceiptMismatch(taskID)
      }
    case (.none, .some), (.some, .none):
      throw AgentExecutionEvidenceError.taskReceiptMismatch(taskID)
    }
    self.identifier = identifier
    self.taskResult = taskResult
    self.content = content
    self.receipt = receipt
    self.wasTruncated = wasTruncated
    self.turnsUsed = turnsUsed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      identifier: container.decode(String.self, forKey: .identifier),
      taskResult: container.decode(AgentTaskResult.self, forKey: .taskResult),
      content: container.decodeIfPresent(String.self, forKey: .content),
      receipt: container.decodeIfPresent(FoundationModelsAgentRunReceipt.self, forKey: .receipt),
      wasTruncated: container.decode(Bool.self, forKey: .wasTruncated),
      turnsUsed: container.decode(Int.self, forKey: .turnsUsed)
    )
  }

  public var promptRepresentation: Prompt {
    struct Projection: Encodable {
      let identifier: String
      let taskResult: AgentTaskResult
      let content: String?
      let wasTruncated: Bool
      let turnsUsed: Int
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded =
      (try? encoder.encode(
        Projection(
          identifier: identifier,
          taskResult: taskResult,
          content: content,
          wasTruncated: wasTruncated,
          turnsUsed: turnsUsed
        )
      )).map { String(decoding: $0, as: UTF8.self) }
      ?? #"{"identifier":"\#(identifier)","status":"failed"}"#
    return Prompt(encoded)
  }
}

actor ChildAgentInvocationBudget {
  private var countsByIdentifier: [String: Int] = [:]

  func reserve(identifier: String, maximum: Int) -> Bool {
    let count = countsByIdentifier[identifier, default: 0]
    guard count < maximum else { return false }
    countsByIdentifier[identifier] = count + 1
    return true
  }
}

struct AgentSessionExecutionContextValue: Sendable {
  let lineage: AgentRunLineage
  let childBudget: ChildAgentInvocationBudget
  let maximumChildDepth: Int
}

enum AgentSessionExecutionContext {
  @TaskLocal static var current: AgentSessionExecutionContextValue?
}

private func makeChildProfileSession<
  Profile: LanguageModelSession.DynamicProfile & Sendable & SendableMetatype
>(
  checkpointCompatibilityID: String,
  invocation: ChildAgentInvocation,
  limits: ChildAgentLimits,
  toolGovernance: DynamicProfileToolGovernanceConfiguration?,
  makeProfile: @escaping @Sendable (ChildAgentInvocation) -> sending Profile
) throws -> AgentSession {
  let governance: DynamicProfileToolGovernanceConfiguration?
  if let toolGovernance {
    let narrowedMaximum: Int? =
      switch (toolGovernance.maximumCallsPerRun, limits.maximumToolCalls) {
      case (.some(let configured), .some(let child)): Swift.min(configured, child)
      case (.some(let configured), .none): configured
      case (.none, .some(let child)): child
      case (.none, .none): nil
      }
    governance = try DynamicProfileToolGovernanceConfiguration(
      registry: toolGovernance.registry,
      trustedManifestDigests: toolGovernance.trustedManifestDigests,
      authorizer: toolGovernance.authorizer,
      maximumCallsPerRun: narrowedMaximum,
      maximumCallsPerToolPerRun: toolGovernance.maximumCallsPerToolPerRun
    )
  } else {
    governance = nil
  }
  return try AgentSession(
    checkpointCompatibilityID: checkpointCompatibilityID,
    toolGovernance: governance
  ) {
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
    let startedAt = Date()
    let limits = definition.limits
    let inheritedContext = AgentSessionExecutionContext.current
    let parentLineage = inheritedContext?.lineage ?? .root()
    let childBudget = inheritedContext?.childBudget ?? ChildAgentInvocationBudget()
    let effectiveMaximumDepth = Swift.min(
      inheritedContext?.maximumChildDepth ?? .max,
      limits.maximumDepth
    )
    let lineage = try parentLineage.descendant()

    guard lineage.depth.rawValue <= effectiveMaximumDepth else {
      return try failure(
        lineage: lineage,
        status: .failed,
        code: "depth_limit_exceeded",
        message: "The child-agent depth limit was reached.",
        startedAt: startedAt
      )
    }
    guard limits.maximumTurns >= 1 else {
      return try failure(
        lineage: lineage,
        status: .failed,
        code: "turn_limit_exceeded",
        message: "The child-agent turn limit does not permit a foreground consultation.",
        startedAt: startedAt
      )
    }
    if limits.wallClockTimeout == .zero {
      return try failure(
        lineage: lineage,
        status: .timedOut,
        code: "wall_clock_timeout",
        message: "The child-agent consultation has no available wall-clock time.",
        startedAt: startedAt
      )
    }

    var effectiveLimits = limits
    effectiveLimits.maximumDepth = effectiveMaximumDepth
    let invocation = ChildAgentInvocation(
      identifier: definition.identifier,
      task: arguments.task,
      lineage: lineage,
      limits: effectiveLimits
    )
    let runCapture = ChildAgentRunCapture()

    do {
      let operation: @Sendable () async throws -> ChildAgentResult = {
        switch try await definition.policy.decision(for: invocation) {
        case .allow:
          break
        case .deny(let reason):
          return try failure(
            lineage: lineage,
            status: .denied,
            code: "policy_denied",
            message: reason,
            startedAt: startedAt
          )
        }

        try Task.checkCancellation()
        guard
          await childBudget.reserve(
            identifier: definition.identifier,
            maximum: limits.maximumChildrenPerParentRun
          )
        else {
          return try failure(
            lineage: lineage,
            status: .failed,
            code: "child_limit_exceeded",
            message: "The parent run exhausted this child-agent consultation budget.",
            startedAt: startedAt
          )
        }
        let session = try await definition.session(for: invocation)
        await runCapture.set(session)
        let response = try await AgentSessionExecutionContext.$current.withValue(
          AgentSessionExecutionContextValue(
            lineage: lineage,
            childBudget: ChildAgentInvocationBudget(),
            maximumChildDepth: effectiveMaximumDepth
          )
        ) {
          try await session.respondForChild(
            to: invocation.task,
            lineage: lineage,
            maximumToolCalls: limits.maximumToolCalls
          )
        }
        return try success(response: response, lineage: lineage, startedAt: startedAt)
      }

      guard let timeout = limits.wallClockTimeout else {
        return try await operation()
      }
      do {
        return try await withFoundationModelsAgentTimeout(timeout, operation: operation)
      } catch is FoundationModelsAgentTimeoutMarker {
        return try await failure(
          lineage: lineage,
          status: .timedOut,
          code: "wall_clock_timeout",
          message: "The child-agent consultation exceeded its wall-clock limit.",
          startedAt: startedAt,
          run: runCapture.run()
        )
      }
    } catch is CancellationError {
      return try await failure(
        lineage: lineage,
        status: .cancelled,
        code: "child_cancelled",
        message: "The child-agent consultation was cancelled.",
        startedAt: startedAt,
        run: runCapture.run()
      )
    } catch {
      return try await result(
        for: error,
        lineage: lineage,
        startedAt: startedAt,
        run: runCapture.run()
      )
    }
  }

  private func success(
    response: FoundationModelsAgentResponse<String>,
    lineage: AgentRunLineage,
    startedAt: Date
  ) throws -> ChildAgentResult {
    let redacted = definition.resultRedactionPolicy.redact(response.content)
    let bounded = boundedUTF8(redacted, maximumBytes: definition.limits.maximumOutputBytes)
    let receipt = try FoundationModelsAgentRunReceipt(run: response.run)
    let timing = try AgentTaskTiming(
      startedAt: startedAt,
      endedAt: response.run.endedAt
    )
    guard let taskID = lineage.taskID else {
      throw AgentExecutionEvidenceError.invalidDescendantLineage
    }
    let taskResult = try AgentTaskResult(
      lineage: lineage,
      status: .succeeded,
      outputReferences: [
        AgentEvidenceReference(
          id: AgentEvidenceReferenceID("task:\(taskID):output"),
          kind: .output,
          runID: lineage.runID,
          attributes: ["truncated": String(bounded.truncated)]
        )
      ],
      evidenceReferences: [.run(lineage.runID)],
      usage: response.usage,
      receipt: AgentReceiptReference(runID: lineage.runID, rootHash: receipt.rootHash),
      timing: timing
    )
    return try ChildAgentResult(
      identifier: definition.identifier,
      taskResult: taskResult,
      content: bounded.value,
      receipt: receipt,
      wasTruncated: bounded.truncated,
      turnsUsed: 1
    )
  }

  private func result(
    for error: any Error,
    lineage: AgentRunLineage,
    startedAt: Date,
    run: FoundationModelsAgentRun?
  ) throws -> ChildAgentResult {
    if let toolCallError = error as? LanguageModelSession.ToolCallError {
      return try result(
        for: toolCallError.underlyingError,
        lineage: lineage,
        startedAt: startedAt,
        run: run
      )
    }
    if error is CancellationError {
      return try failure(
        lineage: lineage,
        status: .cancelled,
        code: "child_cancelled",
        message: "The child-agent consultation was cancelled.",
        startedAt: startedAt,
        run: run
      )
    }
    if let agentError = error as? FoundationModelsAgentError {
      switch agentError {
      case .responseTimedOut, .toolExecutionTimedOut:
        return try failure(
          lineage: lineage,
          status: .timedOut,
          code: "child_timeout",
          message: "The child-agent model or tool response timed out.",
          startedAt: startedAt,
          run: run
        )
      case .toolCallBudgetExceeded:
        return try failure(
          lineage: lineage,
          status: .failed,
          code: "tool_call_limit_exceeded",
          message: "The child-agent tool-call limit was reached.",
          startedAt: startedAt,
          run: run
        )
      default:
        break
      }
    }
    if let policyError = error as? FoundationModelsAgentPolicyError {
      return try failure(
        lineage: lineage,
        status: .denied,
        code: "tool_policy_denied",
        message: policyError.localizedDescription,
        startedAt: startedAt,
        run: run
      )
    }
    if let governanceError = error as? DynamicProfileToolGovernanceError {
      return try failure(
        lineage: lineage,
        status: governanceError.isDenial ? .denied : .failed,
        code: governanceError.resultCode,
        message: governanceError.localizedDescription,
        startedAt: startedAt,
        run: run
      )
    }
    return try failure(
      lineage: lineage,
      status: .failed,
      code: "child_failure",
      message: "The child-agent consultation failed.",
      startedAt: startedAt,
      run: run
    )
  }

  private func failure(
    lineage: AgentRunLineage,
    status: AgentTaskSettlementStatus,
    code: String,
    message: String,
    startedAt: Date,
    run: FoundationModelsAgentRun? = nil
  ) throws -> ChildAgentResult {
    let redacted = definition.resultRedactionPolicy.redact(message)
    let bounded = boundedUTF8(
      redacted,
      maximumBytes: definition.limits.maximumFailureBytes
    )
    let endedAt = run?.endedAt ?? Date()
    let evidenceRun =
      run
      ?? FoundationModelsAgentRun(
        id: lineage.runID.rawValue,
        startedAt: startedAt,
        endedAt: endedAt,
        usage: nil,
        events: [],
        lineage: lineage
      )
    let receipt = try FoundationModelsAgentRunReceipt(run: evidenceRun)
    let reason = AgentTaskSettlementReason(code: code, message: bounded.value)
    let taskResult = try AgentTaskResult(
      lineage: lineage,
      status: status,
      evidenceReferences: [.run(lineage.runID)],
      usage: run?.usage,
      receipt: AgentReceiptReference(runID: lineage.runID, rootHash: receipt.rootHash),
      failureReason: status == .cancelled ? nil : reason,
      cancellationReason: status == .cancelled ? reason : nil,
      timing: AgentTaskTiming(
        startedAt: startedAt,
        endedAt: endedAt
      )
    )
    return try ChildAgentResult(
      identifier: definition.identifier,
      taskResult: taskResult,
      receipt: receipt,
      wasTruncated: bounded.truncated,
      turnsUsed: run == nil ? 0 : 1
    )
  }
}

private actor ChildAgentRunCapture {
  private var session: AgentSession?

  func set(_ session: AgentSession) {
    self.session = session
  }

  func run() async -> FoundationModelsAgentRun? {
    await session?.lastRun()
  }
}

extension DynamicProfileToolGovernanceError {
  fileprivate var isDenial: Bool {
    if case .denied = self { return true }
    return false
  }

  fileprivate var resultCode: String {
    switch self {
    case .unknownTool: "profile_unknown_tool"
    case .untrustedManifest: "profile_untrusted_manifest"
    case .denied: "profile_tool_denied"
    case .totalBudgetExhausted: "tool_call_limit_exceeded"
    case .toolBudgetExhausted: "tool_call_limit_exceeded"
    }
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
