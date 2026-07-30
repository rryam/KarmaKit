import Foundation
import OSLog

/// Stable names used by AgentSession signposts.
public enum AgentSessionInstrumentationNames {
  public static let subsystem = "com.rudrankriyam.FoundationModelsAgent"
  public static let lifecycleCategory = "AgentSession.Lifecycle"
  public static let checkpointCategory = "AgentSession.Checkpoint"
  public static let policyCategory = "AgentSession.Policy"
  public static let profileCategory = "AgentSession.Profile"
}

/// Controls diagnostic-message capture. Prompt, tool arguments, tool outputs,
/// model output, and reasoning text are never supplied to instrumentation.
public enum AgentSessionInstrumentationContentPolicy: Sendable {
  /// The production default. No diagnostic message content is projected.
  case redacted
  /// A conspicuous opt-in for bounded, redacted diagnostic messages.
  ///
  /// This does not enable prompt, argument, output, or reasoning capture.
  case unsafeExplicitlyEnabled(maximumCharacters: Int)
}

public enum AgentSessionInstrumentationSpanKind: String, Equatable, Sendable {
  case run
  case modelAttempt
  case checkpointRestore
  case checkpointWrite
  case approvalWait
  case governedToolCall
  case toolExecution
  case profileLifecycle
  case profileTransition
  case retry
  case cancellation
}

public enum AgentSessionInstrumentationPhase: String, Equatable, Sendable {
  case began
  case ended
  case event
}

public enum AgentSessionInstrumentationOutcome: String, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
  case denied
  case retrying
}

/// A deterministic projection of each signpost span or event.
///
/// This is not a trace store and does not replace run observers or receipts.
public struct AgentSessionInstrumentationEvent: Equatable, Sendable {
  public let sequence: Int
  public let timestamp: Date
  public let runID: UUID
  public let spanID: UUID
  public let parentSpanID: UUID?
  /// Generic caller-supplied correlation metadata.
  ///
  /// Future lineage APIs can pass UUID strings under keys such as `root_id`,
  /// `parent_id`, or `task_id` without instrumentation defining that hierarchy.
  public let correlationMetadata: [String: String]
  public let kind: AgentSessionInstrumentationSpanKind
  public let phase: AgentSessionInstrumentationPhase
  public let outcome: AgentSessionInstrumentationOutcome?
  public let attributes: [String: String]
  public let diagnosticMessage: String?

  public init(
    sequence: Int,
    timestamp: Date,
    runID: UUID,
    spanID: UUID,
    parentSpanID: UUID?,
    correlationMetadata: [String: String],
    kind: AgentSessionInstrumentationSpanKind,
    phase: AgentSessionInstrumentationPhase,
    outcome: AgentSessionInstrumentationOutcome? = nil,
    attributes: [String: String] = [:],
    diagnosticMessage: String? = nil
  ) {
    self.sequence = sequence
    self.timestamp = timestamp
    self.runID = runID
    self.spanID = spanID
    self.parentSpanID = parentSpanID
    self.correlationMetadata = correlationMetadata
    self.kind = kind
    self.phase = phase
    self.outcome = outcome
    self.attributes = attributes
    self.diagnosticMessage = diagnosticMessage
  }
}

/// A synchronous projection sink. Throwing sinks are isolated from session behavior.
public protocol AgentSessionInstrumentationSink: Sendable {
  func receive(_ event: AgentSessionInstrumentationEvent) throws
}

public struct ClosureAgentSessionInstrumentationSink: AgentSessionInstrumentationSink {
  private let handler: @Sendable (AgentSessionInstrumentationEvent) throws -> Void

  public init(
    _ handler: @escaping @Sendable (AgentSessionInstrumentationEvent) throws -> Void
  ) {
    self.handler = handler
  }

  public func receive(_ event: AgentSessionInstrumentationEvent) throws {
    try handler(event)
  }
}

public struct NoOpAgentSessionInstrumentationSink: AgentSessionInstrumentationSink {
  public init() {}
  public func receive(_ event: AgentSessionInstrumentationEvent) {}
}

/// Opt-in OSLog/signpost configuration for one AgentSession.
public struct AgentSessionInstrumentationConfiguration: Sendable {
  public var isEnabled: Bool
  /// Generic UUID/string metadata for optional root, parent, task, or child correlation.
  public var correlationMetadata: [String: String]
  public var contentPolicy: AgentSessionInstrumentationContentPolicy
  public var sink: (any AgentSessionInstrumentationSink)?

  public init(
    isEnabled: Bool = true,
    correlationMetadata: [String: String] = [:],
    contentPolicy: AgentSessionInstrumentationContentPolicy = .redacted,
    sink: (any AgentSessionInstrumentationSink)? = nil
  ) {
    self.isEnabled = isEnabled
    self.correlationMetadata = correlationMetadata
    self.contentPolicy = contentPolicy
    self.sink = sink
  }

  /// The zero-work default used by AgentSession.
  public static let disabled = AgentSessionInstrumentationConfiguration(isEnabled: false)
}

private struct AgentSessionActiveInstrumentationSpan {
  let id: UUID
  let parentID: UUID?
  let kind: AgentSessionInstrumentationSpanKind
  let signpostID: OSSignpostID
  let key: String
}

actor AgentSessionInstrumentationRuntime {
  private let configuration: AgentSessionInstrumentationConfiguration
  private let lifecycleLog: OSLog
  private let checkpointLog: OSLog
  private let policyLog: OSLog
  private let profileLog: OSLog
  private var sequence = 0
  private var activeByRun: [UUID: [AgentSessionActiveInstrumentationSpan]] = [:]

  init(configuration: AgentSessionInstrumentationConfiguration) {
    self.configuration = configuration
    self.lifecycleLog = OSLog(
      subsystem: AgentSessionInstrumentationNames.subsystem,
      category: AgentSessionInstrumentationNames.lifecycleCategory
    )
    self.checkpointLog = OSLog(
      subsystem: AgentSessionInstrumentationNames.subsystem,
      category: AgentSessionInstrumentationNames.checkpointCategory
    )
    self.policyLog = OSLog(
      subsystem: AgentSessionInstrumentationNames.subsystem,
      category: AgentSessionInstrumentationNames.policyCategory
    )
    self.profileLog = OSLog(
      subsystem: AgentSessionInstrumentationNames.subsystem,
      category: AgentSessionInstrumentationNames.profileCategory
    )
  }

  func record(_ source: FoundationModelsAgentEvent) {
    switch source.kind {
    case .runStarted:
      begin(.run, key: "run", source: source, parent: nil)

    case .modelAttemptStarted:
      begin(
        .modelAttempt,
        key: "attempt:\(source.attributes["attempt"] ?? "unknown")",
        source: source,
        parent: activeID(for: .run, runID: source.runID)
      )
    case .modelAttemptFailed:
      endLatest(.modelAttempt, source: source, outcome: outcome(for: source))
    case .modelResponseCompleted:
      endLatest(.modelAttempt, source: source, outcome: .succeeded)

    case .checkpointRestoreStarted:
      begin(
        .checkpointRestore,
        key: "checkpoint-restore",
        source: source,
        parent: activeID(for: .run, runID: source.runID)
      )
    case .checkpointRestoreCompleted:
      if source.attributes["restored_before_run"] == "true" {
        emit(
          .checkpointRestore,
          source: source,
          outcome: .succeeded,
          parent: activeID(for: .run, runID: source.runID)
        )
      } else {
        endLatest(.checkpointRestore, source: source, outcome: .succeeded)
      }
    case .checkpointRestoreFailed:
      endLatest(.checkpointRestore, source: source, outcome: outcome(for: source))
    case .checkpointWriteStarted:
      begin(
        .checkpointWrite,
        key: "checkpoint-write",
        source: source,
        parent: activeID(for: .run, runID: source.runID)
      )
    case .transcriptCheckpointed:
      endLatest(.checkpointWrite, source: source, outcome: .succeeded)
    case .transcriptCheckpointFailed:
      endLatest(.checkpointWrite, source: source, outcome: outcome(for: source))

    case .toolAuthorizationStarted:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      begin(
        .governedToolCall,
        key: "tool:\(invocation)",
        source: source,
        parent: activeID(for: .modelAttempt, runID: source.runID)
          ?? activeID(for: .run, runID: source.runID)
      )
      begin(
        .approvalWait,
        key: "approval:\(invocation)",
        source: source,
        parent: activeID(
          forKey: "tool:\(invocation)",
          runID: source.runID
        )
      )
    case .toolAuthorizationSucceeded:
      end(
        key: "approval:\(source.attributes["invocation_id"] ?? "unknown")",
        source: source,
        outcome: .succeeded
      )
    case .toolAuthorizationDenied:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      end(key: "approval:\(invocation)", source: source, outcome: .denied)
      end(key: "tool:\(invocation)", source: source, outcome: .denied)
    case .toolAuthorizationCancelled:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      end(key: "approval:\(invocation)", source: source, outcome: .cancelled)
      end(key: "tool:\(invocation)", source: source, outcome: .cancelled)
    case .toolAuthorizationFailed:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      end(key: "approval:\(invocation)", source: source, outcome: .failed)
      end(key: "tool:\(invocation)", source: source, outcome: .failed)
    case .toolExecutionStarted:
      begin(
        .toolExecution,
        key: "execution:\(source.attributes["invocation_id"] ?? "unknown")",
        source: source,
        parent: activeID(for: .governedToolCall, runID: source.runID)
      )
    case .toolExecutionCompleted:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      end(key: "execution:\(invocation)", source: source, outcome: .succeeded)
      end(key: "tool:\(invocation)", source: source, outcome: .succeeded)
    case .toolExecutionFailed:
      let invocation = source.attributes["invocation_id"] ?? "unknown"
      let terminal = outcome(for: source)
      end(key: "execution:\(invocation)", source: source, outcome: terminal)
      end(key: "tool:\(invocation)", source: source, outcome: terminal)

    case .modelRetryScheduled:
      emit(
        .retry,
        source: source,
        outcome: .retrying,
        parent: activeID(for: .run, runID: source.runID)
      )

    case .profileToolAuditBestEffort:
      begin(
        .profileLifecycle,
        key: "profile",
        source: source,
        parent: activeID(for: .run, runID: source.runID)
      )
    case .nativeToolCallRecorded, .nativeToolOutputRecorded:
      if source.attributes["profile_owned"] == "true" {
        emit(
          .profileTransition,
          source: source,
          parent: activeID(for: .profileLifecycle, runID: source.runID)
            ?? activeID(for: .run, runID: source.runID)
        )
      }

    case .runCancelled:
      emit(
        .cancellation,
        source: source,
        outcome: .cancelled,
        parent: activeID(for: .run, runID: source.runID)
      )
      endRun(source, outcome: .cancelled)
    case .runFailed:
      endRun(source, outcome: .failed)
    case .runCompleted:
      endRun(source, outcome: .succeeded)

    case .pluginPreparationStarted, .pluginPreparationCompleted, .pluginPreparationFailed,
      .pluginCompletionStarted, .pluginCompletionCompleted, .pluginCompletionFailed,
      .pluginEvent:
      break
    }
  }

  private func begin(
    _ kind: AgentSessionInstrumentationSpanKind,
    key: String,
    source: FoundationModelsAgentEvent,
    parent: UUID?
  ) {
    let log = log(for: kind)
    let active = AgentSessionActiveInstrumentationSpan(
      id: UUID(),
      parentID: parent,
      kind: kind,
      signpostID: OSSignpostID(log: log),
      key: key
    )
    activeByRun[source.runID, default: []].append(active)
    emitOSLog(.begin, active: active, source: source, outcome: nil)
    project(active: active, phase: .began, source: source, outcome: nil)
  }

  private func endLatest(
    _ kind: AgentSessionInstrumentationSpanKind,
    source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome
  ) {
    guard var active = activeByRun[source.runID],
      let index = active.lastIndex(where: { $0.kind == kind })
    else {
      return
    }
    let span = active.remove(at: index)
    activeByRun[source.runID] = active
    emitOSLog(.end, active: span, source: source, outcome: outcome)
    project(active: span, phase: .ended, source: source, outcome: outcome)
  }

  private func end(
    key: String,
    source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome
  ) {
    guard var active = activeByRun[source.runID],
      let index = active.lastIndex(where: { $0.key == key })
    else {
      return
    }
    let span = active.remove(at: index)
    activeByRun[source.runID] = active
    emitOSLog(.end, active: span, source: source, outcome: outcome)
    project(active: span, phase: .ended, source: source, outcome: outcome)
  }

  private func emit(
    _ kind: AgentSessionInstrumentationSpanKind,
    source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome? = nil,
    parent: UUID?
  ) {
    let log = log(for: kind)
    let active = AgentSessionActiveInstrumentationSpan(
      id: UUID(),
      parentID: parent,
      kind: kind,
      signpostID: OSSignpostID(log: log),
      key: kind.rawValue
    )
    emitOSLog(.event, active: active, source: source, outcome: outcome)
    project(active: active, phase: .event, source: source, outcome: outcome)
  }

  private func endRun(
    _ source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome
  ) {
    let open = activeByRun[source.runID] ?? []
    for span in open.reversed() where span.kind != .run {
      emitOSLog(.end, active: span, source: source, outcome: outcome)
      project(active: span, phase: .ended, source: source, outcome: outcome)
    }
    if let run = open.first(where: { $0.kind == .run }) {
      emitOSLog(.end, active: run, source: source, outcome: outcome)
      project(active: run, phase: .ended, source: source, outcome: outcome)
    }
    activeByRun.removeValue(forKey: source.runID)
  }

  private func activeID(
    for kind: AgentSessionInstrumentationSpanKind,
    runID: UUID
  ) -> UUID? {
    activeByRun[runID]?.last(where: { $0.kind == kind })?.id
  }

  private func activeID(forKey key: String, runID: UUID) -> UUID? {
    activeByRun[runID]?.last(where: { $0.key == key })?.id
  }

  private func project(
    active: AgentSessionActiveInstrumentationSpan,
    phase: AgentSessionInstrumentationPhase,
    source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome?
  ) {
    let event = AgentSessionInstrumentationEvent(
      sequence: sequence,
      timestamp: source.timestamp,
      runID: source.runID,
      spanID: active.id,
      parentSpanID: active.parentID,
      correlationMetadata: configuration.correlationMetadata,
      kind: active.kind,
      phase: phase,
      outcome: outcome,
      attributes: safeAttributes(from: source.attributes),
      diagnosticMessage: diagnosticMessage(from: source.message)
    )
    sequence += 1
    do {
      try configuration.sink?.receive(event)
    } catch {
      // Instrumentation must never affect AgentSession correctness.
    }
  }

  private func diagnosticMessage(from message: String) -> String? {
    guard case .unsafeExplicitlyEnabled(let maximumCharacters) = configuration.contentPolicy,
      maximumCharacters > 0
    else {
      return nil
    }
    return String(message.prefix(maximumCharacters))
  }

  private func safeAttributes(from attributes: [String: String]) -> [String: String] {
    let allowed = [
      "attempt",
      "cancelled",
      "emitted_partial_response",
      "history_entries",
      "input_tokens",
      "output_tokens",
      "transcript_entries",
      "checkpoint_found",
      "next_attempt",
      "restored_before_run",
    ]
    return attributes.filter { allowed.contains($0.key) }
  }

  private func outcome(for source: FoundationModelsAgentEvent)
    -> AgentSessionInstrumentationOutcome
  {
    if source.attributes["cancelled"] == "true"
      || source.attributes["error_type"]?.contains("CancellationError") == true
    {
      return .cancelled
    }
    return .failed
  }

  private func log(for kind: AgentSessionInstrumentationSpanKind) -> OSLog {
    switch kind {
    case .checkpointRestore, .checkpointWrite:
      checkpointLog
    case .approvalWait, .governedToolCall, .toolExecution:
      policyLog
    case .profileLifecycle, .profileTransition:
      profileLog
    case .run, .modelAttempt, .retry, .cancellation:
      lifecycleLog
    }
  }

  private func emitOSLog(
    _ type: OSSignpostType,
    active: AgentSessionActiveInstrumentationSpan,
    source: FoundationModelsAgentEvent,
    outcome: AgentSessionInstrumentationOutcome?
  ) {
    let run = source.runID.uuidString.lowercased() as NSString
    let span = active.id.uuidString.lowercased() as NSString
    let parent = (active.parentID?.uuidString.lowercased() ?? "none") as NSString
    let root = (configuration.correlationMetadata["root_id"] ?? "none") as NSString
    let correlationParent =
      (configuration.correlationMetadata["parent_id"] ?? "none") as NSString
    let task = (configuration.correlationMetadata["task_id"] ?? "none") as NSString
    let child = (configuration.correlationMetadata["child_id"] ?? "none") as NSString
    let result = (outcome?.rawValue ?? "none") as NSString
    let log = log(for: active.kind)
    let name: StaticString
    switch active.kind {
    case .run:
      name = "AgentSession Run"
    case .modelAttempt:
      name = "Model Attempt"
    case .checkpointRestore:
      name = "Checkpoint Restore"
    case .checkpointWrite:
      name = "Checkpoint Write"
    case .approvalWait:
      name = "Approval Wait"
    case .governedToolCall:
      name = "Governed Tool Call"
    case .toolExecution:
      name = "Tool Execution"
    case .profileLifecycle:
      name = "Profile Lifecycle"
    case .profileTransition:
      name = "Profile Transition"
    case .retry:
      name = "Retry"
    case .cancellation:
      name = "Cancellation"
    }
    os_signpost(
      type, log: log, name: name, signpostID: active.signpostID,
      "run_id=%{private,mask.hash}@ span_id=%{private,mask.hash}@ parent_span_id=%{private,mask.hash}@ root_id=%{private,mask.hash}@ parent_id=%{private,mask.hash}@ task_id=%{private,mask.hash}@ child_id=%{private,mask.hash}@ outcome=%{public}@",
      run, span, parent, root, correlationParent, task, child, result)
  }
}
