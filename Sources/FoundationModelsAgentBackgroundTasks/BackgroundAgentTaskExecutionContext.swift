import Foundation

public struct BackgroundAgentTaskExecutionContext: Sendable {
  private let taskID: BackgroundAgentTaskID
  private let update:
    @Sendable (BackgroundAgentTaskID, BackgroundAgentTaskExecutionUpdate) async throws -> Void

  init(
    taskID: BackgroundAgentTaskID,
    update:
      @escaping @Sendable (BackgroundAgentTaskID, BackgroundAgentTaskExecutionUpdate) async throws
      -> Void
  ) {
    self.taskID = taskID
    self.update = update
  }

  /// Marks that execution paused for caller-owned approval.
  public func markAwaitingApproval() async throws {
    try await update(taskID, .transition(.awaitingApproval))
  }

  /// Marks that generation resumed after approval.
  public func markGenerating() async throws {
    try await update(taskID, .transition(.generating))
  }

  /// Records a read-only tool call and consumes one tool-call budget unit.
  public func markExecutingTool(named name: String) async throws {
    try await update(taskID, .executeTool(name: name))
  }

  /// Records the intent to cross a mutation boundary before the external call starts.
  ///
  /// A replayable mutation must use the same key declared by
  /// `BackgroundAgentTaskRecoveryPolicy.idempotentMutation`.
  public func markExecutingMutation(
    named name: String,
    idempotencyKey: String? = nil
  ) async throws {
    try await update(
      taskID,
      .executeMutation(name: name, idempotencyKey: idempotencyKey)
    )
  }

  /// Returns to generation after a tool has produced its native output.
  public func markToolFinished() async throws {
    try await update(taskID, .transition(.generating))
  }

  /// Adds actual run usage. Pass input plus output tokens for `tokens`.
  public func recordUsage(
    turns: Int = 0,
    toolCalls: Int = 0,
    tokens: Int = 0
  ) async throws {
    try await update(
      taskID,
      .consume(BackgroundAgentTaskUsage(turns: turns, toolCalls: toolCalls, tokens: tokens))
    )
  }

  public func checkCancellation() throws {
    try Task.checkCancellation()
  }
}

enum BackgroundAgentTaskExecutionUpdate: Sendable {
  case transition(BackgroundAgentTaskState)
  case executeTool(name: String)
  case executeMutation(name: String, idempotencyKey: String?)
  case consume(BackgroundAgentTaskUsage)
}
