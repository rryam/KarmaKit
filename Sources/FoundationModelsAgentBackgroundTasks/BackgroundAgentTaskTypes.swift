import Foundation
import FoundationModelsAgent

public struct BackgroundAgentTaskID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }

  /// The canonical task identifier used by run lineage, evidence, and receipts.
  public var agentTaskID: AgentTaskID {
    AgentTaskID(rawValue: rawValue)
  }

  public var description: String {
    rawValue.uuidString.lowercased()
  }
}

public enum BackgroundAgentTaskState: String, Codable, CaseIterable, Sendable {
  case queued
  case preparing
  case generating
  case awaitingApproval
  case executingTool
  case settling
  case completed
  case failed
  case cancelled
  case ambiguousAfterCrash

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .ambiguousAfterCrash:
      true
    case .queued, .preparing, .generating, .awaitingApproval, .executingTool, .settling:
      false
    }
  }
}

public enum BackgroundAgentTaskPriority: Int, Codable, CaseIterable, Comparable, Sendable {
  case low = 0
  case normal = 1
  case high = 2
  case critical = 3

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// Declares what the coordinator may replay after an interrupted attempt.
public enum BackgroundAgentTaskRecoveryPolicy: Codable, Equatable, Sendable {
  /// The execution performs no mutations and can start again.
  case readOnly
  /// A mutation may have happened and must never be replayed automatically.
  case nonReplayableMutation
  /// The task's single mutation uses this key at its external idempotency boundary.
  case idempotentMutation(idempotencyKey: String)
}

public struct BackgroundAgentTaskBudget: Codable, Equatable, Sendable {
  public var maximumWallClock: TimeInterval
  public var maximumAttempts: Int
  public var maximumTurns: Int
  public var maximumToolCalls: Int
  public var maximumTokens: Int

  public init(
    maximumWallClock: TimeInterval = 300,
    maximumAttempts: Int = 3,
    maximumTurns: Int = 8,
    maximumToolCalls: Int = 16,
    maximumTokens: Int = 100_000
  ) {
    self.maximumWallClock = maximumWallClock
    self.maximumAttempts = maximumAttempts
    self.maximumTurns = maximumTurns
    self.maximumToolCalls = maximumToolCalls
    self.maximumTokens = maximumTokens
  }

  public static let `default` = BackgroundAgentTaskBudget()
}

public struct BackgroundAgentTaskUsage: Codable, Equatable, Sendable {
  public internal(set) var turns: Int
  public internal(set) var toolCalls: Int
  public internal(set) var tokens: Int

  public init(turns: Int = 0, toolCalls: Int = 0, tokens: Int = 0) {
    self.turns = turns
    self.toolCalls = toolCalls
    self.tokens = tokens
  }
}

public struct BackgroundAgentTaskLease: Codable, Equatable, Sendable {
  public let executorID: UUID
  public let acquiredAt: Date
  public let expiresAt: Date

  public init(executorID: UUID, acquiredAt: Date, expiresAt: Date) {
    self.executorID = executorID
    self.acquiredAt = acquiredAt
    self.expiresAt = expiresAt
  }

  public func isExpired(at date: Date) -> Bool {
    expiresAt <= date
  }
}

public struct BackgroundAgentTaskToolExecution: Codable, Equatable, Sendable {
  public let name: String
  public let isMutation: Bool
  public let idempotencyKey: String?
  public let beganAt: Date

  public init(
    name: String,
    isMutation: Bool,
    idempotencyKey: String?,
    beganAt: Date
  ) {
    self.name = name
    self.isMutation = isMutation
    self.idempotencyKey = idempotencyKey
    self.beganAt = beganAt
  }
}

public enum BackgroundAgentTaskTerminalCode: String, Codable, Sendable {
  case completed
  case denied
  case executionFailed
  case cancelled
  case timedOut
  case budgetExceeded
  case ambiguousAfterCrash
}

public struct BackgroundAgentTaskTerminalReason: Codable, Equatable, Sendable {
  public let code: BackgroundAgentTaskTerminalCode
  public let detail: String?

  public init(code: BackgroundAgentTaskTerminalCode, detail: String? = nil) {
    self.code = code
    self.detail = detail
  }
}

/// Scheduler evidence for one distinct native run attempt.
public struct BackgroundAgentTaskAttempt: Codable, Equatable, Sendable {
  public let lineage: AgentRunLineage
  public let startedAt: Date
  public internal(set) var endedAt: Date?
  public internal(set) var terminalCode: BackgroundAgentTaskTerminalCode?
  public internal(set) var terminalDetail: String?
  public internal(set) var taskResult: AgentTaskResult?
  public internal(set) var mutationName: String?
  public internal(set) var mutationIdempotencyKey: String?

  public init(
    lineage: AgentRunLineage,
    startedAt: Date,
    endedAt: Date? = nil,
    terminalCode: BackgroundAgentTaskTerminalCode? = nil,
    terminalDetail: String? = nil,
    taskResult: AgentTaskResult? = nil,
    mutationName: String? = nil,
    mutationIdempotencyKey: String? = nil
  ) {
    self.lineage = lineage
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.terminalCode = terminalCode
    self.terminalDetail = terminalDetail
    self.taskResult = taskResult
    self.mutationName = mutationName
    self.mutationIdempotencyKey = mutationIdempotencyKey
  }
}

/// A durable task description. `prompt` remains a native `String` prompt; the execution
/// factory decides how to pass it to `AgentSession`. `parentLineage` identifies the
/// canonical run that scheduled the task.
public struct BackgroundAgentTaskRequest: Codable, Equatable, Sendable {
  public let id: BackgroundAgentTaskID
  public let prompt: String
  public let ownerID: String
  /// The canonical run that scheduled this work.
  public let parentLineage: AgentRunLineage
  public let parentTaskID: BackgroundAgentTaskID?
  /// Scheduler-owned values that a future lineage adapter can populate without changing IDs.
  public let metadata: [String: String]
  public let priority: BackgroundAgentTaskPriority
  public let recoveryPolicy: BackgroundAgentTaskRecoveryPolicy
  public let budget: BackgroundAgentTaskBudget

  public init(
    id: BackgroundAgentTaskID = BackgroundAgentTaskID(),
    prompt: String,
    ownerID: String,
    parentLineage: AgentRunLineage,
    parentTaskID: BackgroundAgentTaskID? = nil,
    metadata: [String: String] = [:],
    priority: BackgroundAgentTaskPriority = .normal,
    recoveryPolicy: BackgroundAgentTaskRecoveryPolicy,
    budget: BackgroundAgentTaskBudget = .default
  ) {
    self.id = id
    self.prompt = prompt
    self.ownerID = ownerID
    self.parentLineage = parentLineage
    self.parentTaskID = parentTaskID
    self.metadata = metadata
    self.priority = priority
    self.recoveryPolicy = recoveryPolicy
    self.budget = budget
  }
}

public struct BackgroundAgentTaskRecord: Codable, Equatable, Sendable {
  public static let currentRecordVersion = 2

  public let recordVersion: Int
  public let id: BackgroundAgentTaskID
  public let prompt: String
  public let ownerID: String
  /// The canonical run that scheduled this task.
  public let parentLineage: AgentRunLineage
  public let rootTaskID: BackgroundAgentTaskID
  public let parentTaskID: BackgroundAgentTaskID?
  public let metadata: [String: String]
  public let depth: Int
  public let priority: BackgroundAgentTaskPriority
  public let sequence: UInt64
  public let recoveryPolicy: BackgroundAgentTaskRecoveryPolicy
  public let budget: BackgroundAgentTaskBudget
  public let submittedAt: Date
  public internal(set) var updatedAt: Date
  public internal(set) var firstStartedAt: Date?
  public internal(set) var settledAt: Date?
  public internal(set) var state: BackgroundAgentTaskState
  public internal(set) var attemptCount: Int
  public internal(set) var lease: BackgroundAgentTaskLease?
  public internal(set) var usage: BackgroundAgentTaskUsage
  public internal(set) var usageOverflowed: Bool
  public internal(set) var hasBegunMutation: Bool
  public internal(set) var currentToolExecution: BackgroundAgentTaskToolExecution?
  public internal(set) var terminalReason: BackgroundAgentTaskTerminalReason?
  /// One distinct canonical run plus its scheduler settlement for every execution attempt.
  public internal(set) var attempts: [BackgroundAgentTaskAttempt]

  public init(
    recordVersion: Int = Self.currentRecordVersion,
    id: BackgroundAgentTaskID,
    prompt: String,
    ownerID: String,
    parentLineage: AgentRunLineage,
    rootTaskID: BackgroundAgentTaskID,
    parentTaskID: BackgroundAgentTaskID?,
    metadata: [String: String] = [:],
    depth: Int,
    priority: BackgroundAgentTaskPriority,
    sequence: UInt64,
    recoveryPolicy: BackgroundAgentTaskRecoveryPolicy,
    budget: BackgroundAgentTaskBudget,
    submittedAt: Date,
    updatedAt: Date,
    firstStartedAt: Date? = nil,
    settledAt: Date? = nil,
    state: BackgroundAgentTaskState = .queued,
    attemptCount: Int = 0,
    lease: BackgroundAgentTaskLease? = nil,
    usage: BackgroundAgentTaskUsage = BackgroundAgentTaskUsage(),
    usageOverflowed: Bool = false,
    hasBegunMutation: Bool = false,
    currentToolExecution: BackgroundAgentTaskToolExecution? = nil,
    terminalReason: BackgroundAgentTaskTerminalReason? = nil,
    attempts: [BackgroundAgentTaskAttempt] = []
  ) {
    self.recordVersion = recordVersion
    self.id = id
    self.prompt = prompt
    self.ownerID = ownerID
    self.parentLineage = parentLineage
    self.rootTaskID = rootTaskID
    self.parentTaskID = parentTaskID
    self.metadata = metadata
    self.depth = depth
    self.priority = priority
    self.sequence = sequence
    self.recoveryPolicy = recoveryPolicy
    self.budget = budget
    self.submittedAt = submittedAt
    self.updatedAt = updatedAt
    self.firstStartedAt = firstStartedAt
    self.settledAt = settledAt
    self.state = state
    self.attemptCount = attemptCount
    self.lease = lease
    self.usage = usage
    self.usageOverflowed = usageOverflowed
    self.hasBegunMutation = hasBegunMutation
    self.currentToolExecution = currentToolExecution
    self.terminalReason = terminalReason
    self.attempts = attempts
  }

  /// The canonical lineage the execution factory must pass into `AgentSession`.
  public var currentAttemptLineage: AgentRunLineage? {
    attempts.last?.lineage
  }

  /// Canonical evidence returned by the most recent settled native run.
  public var taskResult: AgentTaskResult? {
    attempts.last?.taskResult
  }
}

public struct BackgroundAgentTaskOutcome: Sendable {
  /// The canonical terminal evidence for the native `AgentSession` run.
  public let taskResult: AgentTaskResult

  public init(taskResult: AgentTaskResult) {
    self.taskResult = taskResult
  }
}

public struct BackgroundAgentTaskCoordinatorConfiguration: Sendable {
  public var maximumConcurrentTasks: Int
  public var maximumConcurrentTasksPerParent: Int
  public var maximumDepth: Int
  public var maximumFanOutPerParent: Int
  public var leaseDuration: TimeInterval
  public var starvationInterval: TimeInterval

  public init(
    maximumConcurrentTasks: Int = 4,
    maximumConcurrentTasksPerParent: Int = 2,
    maximumDepth: Int = 4,
    maximumFanOutPerParent: Int = 8,
    leaseDuration: TimeInterval = 30,
    starvationInterval: TimeInterval = 30
  ) {
    self.maximumConcurrentTasks = maximumConcurrentTasks
    self.maximumConcurrentTasksPerParent = maximumConcurrentTasksPerParent
    self.maximumDepth = maximumDepth
    self.maximumFanOutPerParent = maximumFanOutPerParent
    self.leaseDuration = leaseDuration
    self.starvationInterval = starvationInterval
  }

  public static let `default` = BackgroundAgentTaskCoordinatorConfiguration()
}

public enum BackgroundAgentTaskCoordinatorError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration(String)
  case invalidRequest(String)
  case duplicateTaskID(BackgroundAgentTaskID)
  case taskNotFound(BackgroundAgentTaskID)
  case parentNotFound(BackgroundAgentTaskID)
  case parentNotAcceptingChildren(BackgroundAgentTaskID)
  case parentLineageMismatch
  case ownerMismatch
  case depthLimitExceeded(maximum: Int)
  case fanOutLimitExceeded(parent: BackgroundAgentTaskID, maximum: Int)
  case budgetExceeded(String)
  case invalidStateTransition(from: BackgroundAgentTaskState, to: BackgroundAgentTaskState)
  case mutationDeclarationRequired
  case idempotencyKeyMismatch
  case multipleMutationsUnsupported
  case taskResultMismatch
  case persistenceFailed(String)
  case unsupportedRecordVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let detail):
      "Invalid task coordinator configuration: \(detail)"
    case .invalidRequest(let detail):
      "Invalid task request: \(detail)"
    case .duplicateTaskID(let id):
      "Task \(id) already exists."
    case .taskNotFound(let id):
      "Task \(id) does not exist."
    case .parentNotFound(let id):
      "Parent task \(id) does not exist."
    case .parentNotAcceptingChildren(let id):
      "Parent task \(id) no longer accepts child work."
    case .parentLineageMismatch:
      "The canonical parent run does not match the scheduler parent task."
    case .ownerMismatch:
      "A child task must have the same owner as its parent."
    case .depthLimitExceeded(let maximum):
      "The task exceeds the configured depth limit of \(maximum)."
    case .fanOutLimitExceeded(let parent, let maximum):
      "Parent task \(parent) already reached its fan-out limit of \(maximum)."
    case .budgetExceeded(let detail):
      "Task budget exceeded: \(detail)"
    case .invalidStateTransition(let from, let to):
      "Task state cannot move from \(from.rawValue) to \(to.rawValue)."
    case .mutationDeclarationRequired:
      "The task must declare a mutation recovery policy before executing a mutation."
    case .idempotencyKeyMismatch:
      "The mutation idempotency key does not match the task recovery declaration."
    case .multipleMutationsUnsupported:
      "A durable background task may cross at most one mutation boundary."
    case .taskResultMismatch:
      "The canonical task result does not match this background task or its terminal state."
    case .persistenceFailed(let detail):
      "Task state could not be persisted: \(detail)"
    case .unsupportedRecordVersion(let version):
      "Task record version \(version) is unsupported."
    }
  }
}
