import Foundation
import FoundationModelsAgent

public actor BackgroundAgentTaskCoordinator {
  public typealias ExecutionFactory =
    @Sendable (BackgroundAgentTaskRecord, BackgroundAgentTaskExecutionContext) async throws ->
    BackgroundAgentTaskOutcome

  private let store: any BackgroundAgentTaskStore
  private let configuration: BackgroundAgentTaskCoordinatorConfiguration
  private let executorID: UUID
  private let now: @Sendable () -> Date
  private let executionFactory: ExecutionFactory

  private var records: [BackgroundAgentTaskID: BackgroundAgentTaskRecord] = [:]
  private var nextSequence: UInt64 = 0
  private var running: [BackgroundAgentTaskID: Task<Void, Never>] = [:]
  private var settlementWaiters: [BackgroundAgentTaskID: [BackgroundAgentTaskSettlementWaiter]] =
    [:]
  private var settlementFailures: [BackgroundAgentTaskID: BackgroundAgentTaskCoordinatorError] = [:]
  private var isPersisting = false
  private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []
  private var hasStarted = false

  public init(
    store: any BackgroundAgentTaskStore,
    configuration: BackgroundAgentTaskCoordinatorConfiguration = .default,
    executorID: UUID = UUID(),
    now: @escaping @Sendable () -> Date = Date.init,
    executionFactory: @escaping ExecutionFactory
  ) throws {
    try Self.validate(configuration: configuration)
    self.store = store
    self.configuration = configuration
    self.executorID = executorID
    self.now = now
    self.executionFactory = executionFactory
  }

  /// Loads durable state, classifies interrupted work, and starts eligible tasks.
  public func start() async throws {
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    guard !hasStarted else {
      releasePersistenceAccess()
      holdsPersistenceAccess = false
      try await resume()
      return
    }

    var loadedRecords: [BackgroundAgentTaskID: BackgroundAgentTaskRecord] = [:]
    var loadedNextSequence: UInt64 = 0
    if let snapshot = try await store.loadSnapshot() {
      guard snapshot.formatVersion == BackgroundAgentTaskStoreSnapshot.currentFormatVersion else {
        throw BackgroundAgentTaskStoreError.unsupportedFormatVersion(snapshot.formatVersion)
      }
      for record in snapshot.records {
        guard record.recordVersion == BackgroundAgentTaskRecord.currentRecordVersion else {
          throw BackgroundAgentTaskCoordinatorError.unsupportedRecordVersion(record.recordVersion)
        }
        guard loadedRecords.updateValue(record, forKey: record.id) == nil else {
          throw BackgroundAgentTaskCoordinatorError.duplicateTaskID(record.id)
        }
      }
      loadedNextSequence = snapshot.nextSequence
      try Self.validateLoadedSnapshot(
        records: loadedRecords,
        nextSequence: loadedNextSequence
      )
      let recovery = recoverInterruptedTasks(force: true, in: loadedRecords)
      loadedRecords = recovery.records
      if recovery.changed {
        holdsPersistenceAccess = false
        try await commit(records: loadedRecords, nextSequence: loadedNextSequence)
      } else {
        records = loadedRecords
        nextSequence = loadedNextSequence
      }
      recovery.settled.forEach(notifySettlement)
    } else {
      records = [:]
      nextSequence = 0
    }

    hasStarted = true
    if holdsPersistenceAccess {
      releasePersistenceAccess()
      holdsPersistenceAccess = false
    }
    try await scheduleEligibleTasks()
  }

  /// Reclaims expired leases and schedules queued work.
  public func resume() async throws {
    guard hasStarted else {
      try await start()
      return
    }
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    let recovery = recoverInterruptedTasks(force: false, in: records)
    if recovery.changed {
      holdsPersistenceAccess = false
      try await commit(records: recovery.records, nextSequence: nextSequence)
      recovery.settled.forEach(notifySettlement)
      for record in recovery.records.values where !record.state.isTerminal {
        settlementFailures[record.id] = nil
      }
    }
    if holdsPersistenceAccess {
      releasePersistenceAccess()
      holdsPersistenceAccess = false
    }
    try await scheduleEligibleTasks()
  }

  @discardableResult
  public func submit(_ request: BackgroundAgentTaskRequest) async throws -> BackgroundAgentTaskID {
    try await ensureStarted()
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    try validate(request: request)
    guard records[request.id] == nil else {
      throw BackgroundAgentTaskCoordinatorError.duplicateTaskID(request.id)
    }

    let timestamp = now()
    let parent = try request.parentTaskID.map { parentID -> BackgroundAgentTaskRecord in
      guard let parent = records[parentID] else {
        throw BackgroundAgentTaskCoordinatorError.parentNotFound(parentID)
      }
      guard parent.ownerID == request.ownerID else {
        throw BackgroundAgentTaskCoordinatorError.ownerMismatch
      }
      guard parent.state != .cancelled, parent.state != .failed,
        parent.state != .ambiguousAfterCrash, parent.state != .queued
      else {
        throw BackgroundAgentTaskCoordinatorError.parentNotAcceptingChildren(parentID)
      }
      let canonicalParent = parent.taskResult?.lineage ?? parent.currentAttemptLineage
      guard canonicalParent == request.parentLineage else {
        throw BackgroundAgentTaskCoordinatorError.parentLineageMismatch
      }
      return parent
    }
    let depth = (parent?.depth ?? -1) + 1
    guard depth <= configuration.maximumDepth else {
      throw BackgroundAgentTaskCoordinatorError.depthLimitExceeded(
        maximum: configuration.maximumDepth
      )
    }
    if let parentID = request.parentTaskID {
      let childCount = records.values.lazy.filter { $0.parentTaskID == parentID }.count
      guard childCount < configuration.maximumFanOutPerParent else {
        throw BackgroundAgentTaskCoordinatorError.fanOutLimitExceeded(
          parent: parentID,
          maximum: configuration.maximumFanOutPerParent
        )
      }
    }

    let record = BackgroundAgentTaskRecord(
      id: request.id,
      prompt: request.prompt,
      ownerID: request.ownerID,
      parentLineage: request.parentLineage,
      rootTaskID: parent?.rootTaskID ?? request.id,
      parentTaskID: request.parentTaskID,
      metadata: request.metadata,
      depth: depth,
      priority: request.priority,
      sequence: nextSequence,
      recoveryPolicy: request.recoveryPolicy,
      budget: request.budget,
      submittedAt: timestamp,
      updatedAt: timestamp
    )
    guard nextSequence < UInt64.max else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest(
        "The durable FIFO sequence is exhausted."
      )
    }
    var updatedRecords = records
    updatedRecords[record.id] = record
    holdsPersistenceAccess = false
    try await commit(records: updatedRecords, nextSequence: nextSequence + 1)
    do {
      try await scheduleEligibleTasks()
    } catch {
      // Submission is already durable. The affected task carries a persistence failure
      // through `waitForSettlement`, and `resume()` can retry scheduling explicitly.
    }
    return record.id
  }

  public func record(for id: BackgroundAgentTaskID) -> BackgroundAgentTaskRecord? {
    records[id]
  }

  public func allRecords() -> [BackgroundAgentTaskRecord] {
    records.values.sorted { $0.sequence < $1.sequence }
  }

  public func waitForSettlement(of id: BackgroundAgentTaskID) async throws
    -> BackgroundAgentTaskRecord
  {
    guard let record = records[id] else {
      throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
    }
    if let failure = settlementFailures[id] {
      throw failure
    }
    if record.state.isTerminal {
      return record
    }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          settlementWaiters[id, default: []].append(
            BackgroundAgentTaskSettlementWaiter(id: waiterID, continuation: continuation)
          )
        }
      }
    } onCancel: {
      Task {
        await self.cancelSettlementWaiter(waiterID, taskID: id)
      }
    }
  }

  /// Cancels a task and, by default, every unsettled descendant.
  public func cancel(
    _ id: BackgroundAgentTaskID,
    includingDescendants: Bool = true,
    reason: String? = nil
  ) async throws {
    try await ensureStarted()
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    guard records[id] != nil else {
      throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
    }

    let targets: Set<BackgroundAgentTaskID>
    if includingDescendants {
      targets = descendantIDs(of: id).union([id])
    } else {
      targets = [id]
    }
    let timestamp = now()
    var updatedRecords = records
    var settled: [BackgroundAgentTaskRecord] = []
    for target in targets {
      guard var record = updatedRecords[target], !record.state.isTerminal else {
        continue
      }
      let mutationIsAmbiguous =
        record.recoveryPolicy == .nonReplayableMutation && record.hasBegunMutation
      record.state = mutationIsAmbiguous ? .ambiguousAfterCrash : .cancelled
      record.updatedAt = timestamp
      record.settledAt = timestamp
      record.lease = nil
      record.currentToolExecution = nil
      if mutationIsAmbiguous {
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .ambiguousAfterCrash,
          detail:
            "Cancellation arrived after a non-idempotent mutation began. The external effect may still complete."
        )
      } else {
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .cancelled,
          detail: reason
        )
      }
      Self.settleCurrentAttempt(
        in: &record,
        at: timestamp,
        code: record.terminalReason?.code ?? .cancelled,
        detail: record.terminalReason?.detail
      )
      updatedRecords[target] = record
      settled.append(record)
      running[target]?.cancel()
    }
    do {
      holdsPersistenceAccess = false
      try await commit(records: updatedRecords, nextSequence: nextSequence)
    } catch {
      for record in settled {
        notifySettlementFailure(for: record.id, error: error)
      }
      throw error
    }
    settled.forEach(notifySettlement)
    do {
      try await scheduleEligibleTasks()
    } catch {
      // Cancellation is already durable; scheduling failure belongs to the queued task.
    }
  }

  /// Cooperatively cancels and settles every open task.
  public func shutdown(reason: String? = "Coordinator shut down.") async throws {
    try await ensureStarted()
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    let openIDs = records.values.filter { !$0.state.isTerminal }.map(\.id)
    let timestamp = now()
    var updatedRecords = records
    var settled: [BackgroundAgentTaskRecord] = []
    for id in openIDs {
      guard var record = updatedRecords[id] else { continue }
      let mutationIsAmbiguous =
        record.recoveryPolicy == .nonReplayableMutation && record.hasBegunMutation
      record.state = mutationIsAmbiguous ? .ambiguousAfterCrash : .cancelled
      record.updatedAt = timestamp
      record.settledAt = timestamp
      record.lease = nil
      record.currentToolExecution = nil
      if mutationIsAmbiguous {
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .ambiguousAfterCrash,
          detail:
            "Shutdown arrived after a non-idempotent mutation began. The external effect may still complete."
        )
      } else {
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .cancelled,
          detail: reason
        )
      }
      Self.settleCurrentAttempt(
        in: &record,
        at: timestamp,
        code: record.terminalReason?.code ?? .cancelled,
        detail: record.terminalReason?.detail
      )
      updatedRecords[id] = record
      settled.append(record)
      running[id]?.cancel()
    }
    do {
      holdsPersistenceAccess = false
      try await commit(records: updatedRecords, nextSequence: nextSequence)
    } catch {
      for record in settled {
        notifySettlementFailure(for: record.id, error: error)
      }
      throw error
    }
    settled.forEach(notifySettlement)
  }

  private func ensureStarted() async throws {
    if !hasStarted {
      try await start()
    }
  }

  private func scheduleEligibleTasks() async throws {
    while true {
      await acquirePersistenceAccess()
      guard running.count < configuration.maximumConcurrentTasks,
        let id = nextEligibleTaskID(),
        var record = records[id]
      else {
        releasePersistenceAccess()
        return
      }
      let timestamp = now()
      if let reason = budgetViolation(for: record, at: timestamp) {
        record.state = .failed
        record.updatedAt = timestamp
        record.settledAt = timestamp
        record.lease = nil
        record.currentToolExecution = nil
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .budgetExceeded,
          detail: reason
        )
        var updatedRecords = records
        updatedRecords[id] = record
        do {
          try await commit(records: updatedRecords, nextSequence: nextSequence)
        } catch {
          notifySettlementFailure(for: id, error: error)
          throw error
        }
        notifySettlement(record)
        continue
      }

      record.state = .preparing
      record.updatedAt = timestamp
      record.firstStartedAt = record.firstStartedAt ?? timestamp
      guard record.attemptCount < Int.max else {
        releasePersistenceAccess()
        let error = BackgroundAgentTaskCoordinatorError.budgetExceeded(
          "attempt counter overflow"
        )
        notifySettlementFailure(for: id, error: error)
        throw error
      }
      record.attemptCount += 1
      do {
        record.attempts.append(
          BackgroundAgentTaskAttempt(
            lineage: try record.parentLineage.descendant(
              taskID: record.id.agentTaskID,
              relationship: .background
            ),
            startedAt: timestamp
          )
        )
      } catch {
        releasePersistenceAccess()
        let error = BackgroundAgentTaskCoordinatorError.invalidRequest(
          "The canonical parent lineage cannot create another descendant."
        )
        notifySettlementFailure(for: id, error: error)
        throw error
      }
      record.lease = BackgroundAgentTaskLease(
        executorID: executorID,
        acquiredAt: timestamp,
        expiresAt: timestamp.addingTimeInterval(configuration.leaseDuration)
      )
      var updatedRecords = records
      updatedRecords[id] = record
      do {
        try await commit(
          records: updatedRecords,
          nextSequence: nextSequence,
          releaseAccessAfterCommit: false
        )
      } catch {
        notifySettlementFailure(for: id, error: error)
        throw error
      }
      settlementFailures[id] = nil
      running[id] = Task { [weak self] in
        await self?.execute(id)
      }
      releasePersistenceAccess()
    }
  }

  private func nextEligibleTaskID() -> BackgroundAgentTaskID? {
    let timestamp = now()
    let candidates = records.values.filter { record in
      guard record.state == .queued else { return false }
      guard running[record.id] == nil else { return false }
      guard running.count < configuration.maximumConcurrentTasks else { return false }
      guard let parentID = record.parentTaskID else { return true }
      let runningForParent = running.keys.lazy.compactMap { self.records[$0] }
        .filter { $0.parentTaskID == parentID }.count
      return runningForParent < configuration.maximumConcurrentTasksPerParent
    }

    return candidates.min { lhs, rhs in
      let leftPriority = effectivePriority(of: lhs, at: timestamp)
      let rightPriority = effectivePriority(of: rhs, at: timestamp)
      if leftPriority != rightPriority {
        return leftPriority > rightPriority
      }
      return lhs.sequence < rhs.sequence
    }?.id
  }

  private func effectivePriority(of record: BackgroundAgentTaskRecord, at timestamp: Date) -> Int {
    let waited = max(0, timestamp.timeIntervalSince(record.submittedAt))
    let rawPromotions = waited / configuration.starvationInterval
    let promotions =
      rawPromotions >= Double(Int.max)
      ? Int.max
      : Int(rawPromotions)
    let availablePromotions =
      BackgroundAgentTaskPriority.critical.rawValue - record.priority.rawValue
    return promotions >= availablePromotions
      ? BackgroundAgentTaskPriority.critical.rawValue
      : record.priority.rawValue + promotions
  }

  private func execute(_ id: BackgroundAgentTaskID) async {
    guard let record = records[id], !record.state.isTerminal else {
      running[id] = nil
      try? await scheduleEligibleTasks()
      return
    }
    let context = BackgroundAgentTaskExecutionContext(taskID: id) { [weak self] id, update in
      guard let self else { throw CancellationError() }
      try await self.apply(update, to: id)
    }

    do {
      try await apply(.transition(.generating), to: id)
      guard let current = records[id] else {
        throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
      }
      let outcome = try await executeWithinWallClockBudget(current, context: context)
      try Task.checkCancellation()
      guard let completedRecord = records[id] else {
        throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
      }
      let settlement = try Self.settlement(
        for: outcome.taskResult,
        record: completedRecord
      )
      try await apply(.transition(.settling), to: id)
      let timestamp = now()
      try await persistSettlement(
        id,
        state: settlement.state,
        reason: BackgroundAgentTaskTerminalReason(
          code: settlement.code,
          detail: settlement.detail
        ),
        at: timestamp,
        taskResult: outcome.taskResult
      )
    } catch is CancellationError {
      if let current = records[id], !current.state.isTerminal {
        let timestamp = now()
        let uncertainMutation = Self.hasUncertainMutation(current)
        do {
          try await persistSettlement(
            id,
            state: uncertainMutation ? .ambiguousAfterCrash : .cancelled,
            reason: BackgroundAgentTaskTerminalReason(
              code: uncertainMutation ? .ambiguousAfterCrash : .cancelled,
              detail:
                uncertainMutation
                ? "Execution was cancelled after a non-idempotent mutation began; the external effect is uncertain."
                : nil
            ),
            at: timestamp
          )
        } catch {
          notifySettlementFailure(for: id, error: error)
        }
      }
    } catch let error as BackgroundAgentTaskCoordinatorError {
      if case .persistenceFailed = error {
        notifySettlementFailure(for: id, error: error)
      } else if let current = records[id], !current.state.isTerminal {
        let timestamp = now()
        let uncertainMutation = Self.hasUncertainMutation(current)
        let code: BackgroundAgentTaskTerminalCode
        if uncertainMutation {
          code = .ambiguousAfterCrash
        } else if case .budgetExceeded = error {
          code = .budgetExceeded
        } else {
          code = .executionFailed
        }
        do {
          try await persistSettlement(
            id,
            state: uncertainMutation ? .ambiguousAfterCrash : .failed,
            reason: BackgroundAgentTaskTerminalReason(
              code: code,
              detail:
                uncertainMutation
                ? "Execution stopped after a non-idempotent mutation began; the external effect is uncertain."
                : error.localizedDescription
            ),
            at: timestamp
          )
        } catch {
          notifySettlementFailure(for: id, error: error)
        }
      }
    } catch {
      if let current = records[id], !current.state.isTerminal {
        let timestamp = now()
        let uncertainMutation = Self.hasUncertainMutation(current)
        do {
          try await persistSettlement(
            id,
            state: uncertainMutation ? .ambiguousAfterCrash : .failed,
            reason: BackgroundAgentTaskTerminalReason(
              code: uncertainMutation ? .ambiguousAfterCrash : .executionFailed,
              detail:
                uncertainMutation
                ? "Execution failed after a non-idempotent mutation began; the external effect is uncertain."
                : String(describing: error)
            ),
            at: timestamp
          )
        } catch {
          notifySettlementFailure(for: id, error: error)
        }
      }
    }

    running[id] = nil
    try? await scheduleEligibleTasks()
  }

  private func executeWithinWallClockBudget(
    _ record: BackgroundAgentTaskRecord,
    context: BackgroundAgentTaskExecutionContext
  ) async throws -> BackgroundAgentTaskOutcome {
    let startedAt = record.firstStartedAt ?? now()
    let elapsed = max(0, now().timeIntervalSince(startedAt))
    let remaining = record.budget.maximumWallClock - elapsed
    guard remaining > 0 else {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(
        "wall clock \(record.budget.maximumWallClock) seconds"
      )
    }

    let factory = executionFactory
    return try await withThrowingTaskGroup(
      of: BackgroundAgentTaskExecutionRace.self,
      returning: BackgroundAgentTaskOutcome.self
    ) { group in
      group.addTask {
        .finished(try await factory(record, context))
      }
      group.addTask {
        try await Task.sleep(for: .seconds(remaining))
        return .wallClockExpired
      }
      defer { group.cancelAll() }

      guard let first = try await group.next() else {
        throw CancellationError()
      }
      switch first {
      case .finished(let outcome):
        return outcome
      case .wallClockExpired:
        throw BackgroundAgentTaskCoordinatorError.budgetExceeded(
          "wall clock \(record.budget.maximumWallClock) seconds"
        )
      }
    }
  }

  private func apply(_ update: BackgroundAgentTaskExecutionUpdate, to id: BackgroundAgentTaskID)
    async throws
  {
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    guard var record = records[id] else {
      throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
    }
    try Task.checkCancellation()
    guard !record.state.isTerminal else {
      throw CancellationError()
    }
    let timestamp = now()
    if let reason = budgetViolation(for: record, at: timestamp) {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(reason)
    }

    var observedBudgetViolation: String?
    switch update {
    case .transition(let state):
      guard Self.allowsTransition(from: record.state, to: state) else {
        throw BackgroundAgentTaskCoordinatorError.invalidStateTransition(
          from: record.state,
          to: state
        )
      }
      record.state = state
      if state != .executingTool {
        record.currentToolExecution = nil
      }
    case .executeTool(let name):
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackgroundAgentTaskCoordinatorError.invalidRequest(
          "Tool names must not be empty."
        )
      }
      guard Self.allowsTransition(from: record.state, to: .executingTool) else {
        throw BackgroundAgentTaskCoordinatorError.invalidStateTransition(
          from: record.state,
          to: .executingTool
        )
      }
      observedBudgetViolation = try consume(
        BackgroundAgentTaskUsage(toolCalls: 1),
        from: &record
      )
      if observedBudgetViolation == nil {
        record.state = .executingTool
        record.currentToolExecution = BackgroundAgentTaskToolExecution(
          name: name,
          isMutation: false,
          idempotencyKey: nil,
          beganAt: timestamp
        )
      }
    case .executeMutation(let name, let idempotencyKey):
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackgroundAgentTaskCoordinatorError.invalidRequest(
          "Mutation tool names must not be empty."
        )
      }
      guard Self.allowsTransition(from: record.state, to: .executingTool) else {
        throw BackgroundAgentTaskCoordinatorError.invalidStateTransition(
          from: record.state,
          to: .executingTool
        )
      }
      switch record.recoveryPolicy {
      case .readOnly:
        throw BackgroundAgentTaskCoordinatorError.mutationDeclarationRequired
      case .nonReplayableMutation:
        guard idempotencyKey == nil else {
          throw BackgroundAgentTaskCoordinatorError.idempotencyKeyMismatch
        }
      case .idempotentMutation(let declared):
        guard !declared.isEmpty, idempotencyKey == declared else {
          throw BackgroundAgentTaskCoordinatorError.idempotencyKeyMismatch
        }
      }
      guard !record.hasBegunMutation else {
        throw BackgroundAgentTaskCoordinatorError.multipleMutationsUnsupported
      }
      observedBudgetViolation = try consume(
        BackgroundAgentTaskUsage(toolCalls: 1),
        from: &record
      )
      if observedBudgetViolation == nil {
        record.state = .executingTool
        record.hasBegunMutation = true
        let attemptIndex = record.attempts.index(before: record.attempts.endIndex)
        record.attempts[attemptIndex].mutationName = name
        record.attempts[attemptIndex].mutationIdempotencyKey = idempotencyKey
        record.currentToolExecution = BackgroundAgentTaskToolExecution(
          name: name,
          isMutation: true,
          idempotencyKey: idempotencyKey,
          beganAt: timestamp
        )
      }
    case .consume(let usage):
      observedBudgetViolation = try consume(usage, from: &record)
    }

    record.updatedAt = timestamp
    record.lease = BackgroundAgentTaskLease(
      executorID: executorID,
      acquiredAt: record.lease?.acquiredAt ?? timestamp,
      expiresAt: timestamp.addingTimeInterval(configuration.leaseDuration)
    )
    var updatedRecords = records
    updatedRecords[id] = record
    holdsPersistenceAccess = false
    try await commit(records: updatedRecords, nextSequence: nextSequence)
    settlementFailures[id] = nil
    if let observedBudgetViolation {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(observedBudgetViolation)
    }
  }

  private func consume(
    _ usage: BackgroundAgentTaskUsage, from record: inout BackgroundAgentTaskRecord
  ) throws -> String? {
    guard usage.turns >= 0, usage.toolCalls >= 0, usage.tokens >= 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest(
        "Usage increments must not be negative.")
    }
    let turns = saturatedSum(record.usage.turns, usage.turns)
    let toolCalls = saturatedSum(record.usage.toolCalls, usage.toolCalls)
    let tokens = saturatedSum(record.usage.tokens, usage.tokens)
    let newUsage = BackgroundAgentTaskUsage(
      turns: turns.value,
      toolCalls: toolCalls.value,
      tokens: tokens.value
    )
    record.usage = newUsage
    record.usageOverflowed =
      record.usageOverflowed || turns.overflow || toolCalls.overflow || tokens.overflow
    if turns.overflow {
      return "turn counter overflow"
    }
    if toolCalls.overflow {
      return "tool-call counter overflow"
    }
    if tokens.overflow {
      return "token counter overflow"
    }
    if newUsage.turns > record.budget.maximumTurns {
      return "turns \(newUsage.turns)/\(record.budget.maximumTurns)"
    }
    if newUsage.toolCalls > record.budget.maximumToolCalls {
      return "tool calls \(newUsage.toolCalls)/\(record.budget.maximumToolCalls)"
    }
    if newUsage.tokens > record.budget.maximumTokens {
      return "tokens \(newUsage.tokens)/\(record.budget.maximumTokens)"
    }
    return nil
  }

  private func saturatedSum(_ lhs: Int, _ rhs: Int) -> (value: Int, overflow: Bool) {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return (overflow ? Int.max : sum, overflow)
  }

  private func persistSettlement(
    _ id: BackgroundAgentTaskID,
    state: BackgroundAgentTaskState,
    reason: BackgroundAgentTaskTerminalReason,
    at timestamp: Date,
    taskResult: AgentTaskResult? = nil
  ) async throws {
    await acquirePersistenceAccess()
    var holdsPersistenceAccess = true
    defer {
      if holdsPersistenceAccess {
        releasePersistenceAccess()
      }
    }
    guard var record = records[id], !record.state.isTerminal else {
      return
    }
    record.state = state
    record.updatedAt = timestamp
    record.settledAt = timestamp
    record.lease = nil
    record.currentToolExecution = nil
    record.terminalReason = reason
    Self.settleCurrentAttempt(
      in: &record,
      at: timestamp,
      code: reason.code,
      detail: reason.detail,
      taskResult: taskResult
    )
    var updatedRecords = records
    updatedRecords[id] = record
    do {
      holdsPersistenceAccess = false
      try await commit(records: updatedRecords, nextSequence: nextSequence)
    } catch {
      notifySettlementFailure(for: id, error: error)
      throw error
    }
    notifySettlement(record)
  }

  private func notifySettlement(_ record: BackgroundAgentTaskRecord) {
    settlementFailures[record.id] = nil
    let waiters = settlementWaiters.removeValue(forKey: record.id) ?? []
    for waiter in waiters {
      waiter.continuation.resume(returning: record)
    }
  }

  private func notifySettlementFailure(for id: BackgroundAgentTaskID, error: any Error) {
    let failure = persistenceError(from: error)
    settlementFailures[id] = failure
    let waiters = settlementWaiters.removeValue(forKey: id) ?? []
    for waiter in waiters {
      waiter.continuation.resume(throwing: failure)
    }
  }

  private func cancelSettlementWaiter(
    _ waiterID: UUID,
    taskID: BackgroundAgentTaskID
  ) {
    guard var waiters = settlementWaiters[taskID],
      let index = waiters.firstIndex(where: { $0.id == waiterID })
    else {
      return
    }
    let waiter = waiters.remove(at: index)
    settlementWaiters[taskID] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func recoverInterruptedTasks(
    force: Bool,
    in sourceRecords: [BackgroundAgentTaskID: BackgroundAgentTaskRecord]
  ) -> (
    records: [BackgroundAgentTaskID: BackgroundAgentTaskRecord],
    settled: [BackgroundAgentTaskRecord],
    changed: Bool
  ) {
    let timestamp = now()
    var recoveredRecords = sourceRecords
    var settled: [BackgroundAgentTaskRecord] = []
    var changed = false
    for id in recoveredRecords.keys {
      guard var record = recoveredRecords[id], !record.state.isTerminal else {
        continue
      }
      // A lease is a crash-recovery boundary, not permission to duplicate work that this
      // coordinator still owns. Context updates renew it, but a long native generation may not.
      guard running[id] == nil else {
        continue
      }
      let hasUncertainNonReplayableMutation =
        record.recoveryPolicy == .nonReplayableMutation && record.hasBegunMutation
      if record.state == .queued, !hasUncertainNonReplayableMutation {
        continue
      }
      let locallyStoppedAfterPersistenceFailure =
        settlementFailures[id] != nil && running[id] == nil
      if !force, !locallyStoppedAfterPersistenceFailure,
        let lease = record.lease, !lease.isExpired(at: timestamp)
      {
        continue
      }

      changed = true
      if hasUncertainNonReplayableMutation {
        record.state = .ambiguousAfterCrash
        record.settledAt = timestamp
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .ambiguousAfterCrash,
          detail:
            "The process stopped after a non-idempotent mutation may have started. Inspect the external system before deciding what to do."
        )
      } else if record.attemptCount >= record.budget.maximumAttempts {
        record.state = .failed
        record.settledAt = timestamp
        record.terminalReason = BackgroundAgentTaskTerminalReason(
          code: .budgetExceeded,
          detail: "attempts \(record.attemptCount)/\(record.budget.maximumAttempts)"
        )
      } else {
        record.state = .queued
        record.hasBegunMutation = false
      }
      if record.state.isTerminal {
        Self.settleCurrentAttempt(
          in: &record,
          at: timestamp,
          code: record.terminalReason?.code ?? .executionFailed,
          detail: record.terminalReason?.detail
        )
      } else {
        Self.settleCurrentAttempt(
          in: &record,
          at: timestamp,
          code: .executionFailed,
          detail: "Execution was interrupted before durable settlement."
        )
      }
      record.updatedAt = timestamp
      record.lease = nil
      record.currentToolExecution = nil
      recoveredRecords[id] = record
      if record.state.isTerminal {
        settled.append(record)
      }
    }
    return (recoveredRecords, settled, changed)
  }

  private func budgetViolation(for record: BackgroundAgentTaskRecord, at timestamp: Date) -> String?
  {
    if record.attemptCount >= record.budget.maximumAttempts {
      return "attempts \(record.attemptCount)/\(record.budget.maximumAttempts)"
    }
    if let started = record.firstStartedAt,
      timestamp.timeIntervalSince(started) >= record.budget.maximumWallClock
    {
      return "wall clock \(record.budget.maximumWallClock) seconds"
    }
    if record.usage.turns > record.budget.maximumTurns {
      return "turns \(record.usage.turns)/\(record.budget.maximumTurns)"
    }
    if record.usage.toolCalls > record.budget.maximumToolCalls {
      return "tool calls \(record.usage.toolCalls)/\(record.budget.maximumToolCalls)"
    }
    if record.usage.tokens > record.budget.maximumTokens {
      return "tokens \(record.usage.tokens)/\(record.budget.maximumTokens)"
    }
    if record.usageOverflowed {
      return "usage counter overflow"
    }
    return nil
  }

  private func descendantIDs(of ancestor: BackgroundAgentTaskID) -> Set<BackgroundAgentTaskID> {
    var result: Set<BackgroundAgentTaskID> = []
    var frontier = [ancestor]
    while let parent = frontier.popLast() {
      let children = records.values.filter { $0.parentTaskID == parent }.map(\.id)
      for child in children where result.insert(child).inserted {
        frontier.append(child)
      }
    }
    return result
  }

  private func acquirePersistenceAccess() async {
    guard isPersisting else {
      isPersisting = true
      return
    }
    await withCheckedContinuation { continuation in
      persistenceWaiters.append(continuation)
    }
  }

  private func commit(
    records updatedRecords: [BackgroundAgentTaskID: BackgroundAgentTaskRecord],
    nextSequence updatedNextSequence: UInt64,
    releaseAccessAfterCommit: Bool = true
  ) async throws {
    precondition(isPersisting)
    do {
      try await store.saveSnapshot(
        BackgroundAgentTaskStoreSnapshot(
          savedAt: now(),
          nextSequence: updatedNextSequence,
          records: updatedRecords.values.sorted { $0.sequence < $1.sequence }
        )
      )
      records = updatedRecords
      nextSequence = updatedNextSequence
      if releaseAccessAfterCommit {
        releasePersistenceAccess()
      }
    } catch {
      let failure = persistenceError(from: error)
      releasePersistenceAccess()
      throw failure
    }
  }

  private func releasePersistenceAccess() {
    if persistenceWaiters.isEmpty {
      isPersisting = false
    } else {
      persistenceWaiters.removeFirst().resume()
    }
  }

  private func persistenceError(from error: any Error) -> BackgroundAgentTaskCoordinatorError {
    if let error = error as? BackgroundAgentTaskCoordinatorError,
      case .persistenceFailed = error
    {
      return error
    }
    return .persistenceFailed(String(describing: error))
  }

  private func validate(request: BackgroundAgentTaskRequest) throws {
    guard !request.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest("ownerID must not be empty.")
    }
    if case .idempotentMutation(let key) = request.recoveryPolicy,
      key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest(
        "An idempotent mutation must declare a non-empty key."
      )
    }
    guard request.parentLineage.depth.rawValue < Int.max else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest(
        "The canonical parent lineage is already at the maximum representable depth."
      )
    }
    let budget = request.budget
    guard budget.maximumWallClock.isFinite, budget.maximumWallClock > 0,
      budget.maximumWallClock <= Self.maximumSupportedDurationSeconds,
      budget.maximumAttempts > 0,
      budget.maximumTurns >= 0, budget.maximumToolCalls >= 0,
      budget.maximumTokens >= 0
    else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest("Task budgets are invalid.")
    }
  }

  private static func validate(configuration: BackgroundAgentTaskCoordinatorConfiguration) throws {
    guard configuration.maximumConcurrentTasks > 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidConfiguration(
        "maximumConcurrentTasks must be at least one."
      )
    }
    guard configuration.maximumConcurrentTasksPerParent > 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidConfiguration(
        "maximumConcurrentTasksPerParent must be at least one."
      )
    }
    guard configuration.maximumDepth >= 0, configuration.maximumFanOutPerParent >= 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidConfiguration(
        "depth and fan-out limits must not be negative."
      )
    }
    guard configuration.leaseDuration.isFinite, configuration.starvationInterval.isFinite,
      configuration.leaseDuration > 0, configuration.starvationInterval > 0
    else {
      throw BackgroundAgentTaskCoordinatorError.invalidConfiguration(
        "lease and starvation intervals must be positive."
      )
    }
  }

  private static func validateLoadedSnapshot(
    records: [BackgroundAgentTaskID: BackgroundAgentTaskRecord],
    nextSequence: UInt64
  ) throws {
    let sequences = records.values.map(\.sequence)
    guard Set(sequences).count == sequences.count,
      sequences.allSatisfy({ $0 < nextSequence })
    else {
      throw BackgroundAgentTaskStoreError.corruptedStore(
        "FIFO sequences are duplicated or outside nextSequence."
      )
    }

    for record in records.values {
      guard record.updatedAt >= record.submittedAt,
        record.firstStartedAt.map({ $0 >= record.submittedAt }) ?? true,
        record.settledAt.map({ $0 >= (record.firstStartedAt ?? record.submittedAt) }) ?? true,
        record.usage.turns >= 0,
        record.usage.toolCalls >= 0,
        record.usage.tokens >= 0,
        record.budget.maximumWallClock.isFinite,
        record.budget.maximumWallClock > 0,
        record.budget.maximumWallClock <= maximumSupportedDurationSeconds,
        record.budget.maximumAttempts > 0,
        record.budget.maximumTurns >= 0,
        record.budget.maximumToolCalls >= 0,
        record.budget.maximumTokens >= 0,
        record.parentLineage.depth.rawValue < Int.max,
        record.attemptCount == record.attempts.count,
        (record.attempts.isEmpty && record.firstStartedAt == nil)
          || (!record.attempts.isEmpty
            && record.firstStartedAt == record.attempts.first?.startedAt)
      else {
        throw BackgroundAgentTaskStoreError.corruptedStore(
          "Task \(record.id) has invalid dates, usage, budgets, or attempt accounting."
        )
      }

      if let parentID = record.parentTaskID {
        guard let parent = records[parentID],
          parent.ownerID == record.ownerID,
          parent.rootTaskID == record.rootTaskID,
          parent.depth < Int.max,
          record.depth == parent.depth + 1,
          parent.attempts.contains(where: { $0.lineage == record.parentLineage })
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) has invalid scheduler ancestry."
          )
        }
      } else {
        guard record.rootTaskID == record.id, record.depth == 0 else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Root task \(record.id) has invalid scheduler ancestry."
          )
        }
      }

      var seenRunIDs: Set<AgentRunID> = []
      for (index, attempt) in record.attempts.enumerated() {
        let lineage = attempt.lineage
        guard lineage.taskID == record.id.agentTaskID,
          lineage.relationship == .background,
          lineage.parentRunID == record.parentLineage.runID,
          lineage.rootRunID == record.parentLineage.rootRunID,
          lineage.depth.rawValue == record.parentLineage.depth.rawValue + 1,
          seenRunIDs.insert(lineage.runID).inserted,
          attempt.endedAt.map({ $0 >= attempt.startedAt }) ?? true,
          (attempt.endedAt == nil) == (attempt.terminalCode == nil),
          attempt.taskResult.map({ $0.lineage == lineage }) ?? true,
          index == record.attempts.indices.last || attempt.taskResult == nil,
          index == record.attempts.indices.last || attempt.endedAt != nil,
          index == record.attempts.indices.last || attempt.terminalCode == .executionFailed,
          index == record.attempts.startIndex
            || (record.attempts[index - 1].endedAt.map {
              attempt.startedAt >= $0
            } ?? false)
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) has invalid or repeated canonical attempt lineage."
          )
        }

        switch (attempt.mutationName, attempt.mutationIdempotencyKey, record.recoveryPolicy) {
        case (nil, nil, _):
          break
        case (.some(let name), nil, .nonReplayableMutation)
        where !name.isEmpty && index == record.attempts.indices.last:
          break
        case (.some(let name), .some(let attemptKey), .idempotentMutation(let declaredKey))
        where !name.isEmpty && attemptKey == declaredKey:
          break
        default:
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) attempt contains mutation evidence that disagrees with its recovery policy."
          )
        }
      }

      let lastAttempt = record.attempts.last
      let terminalSchedulerDecision =
        record.state.isTerminal
        && lastAttempt?.endedAt != nil
        && lastAttempt?.endedAt.map({ end in
          record.settledAt.map({ end <= $0 }) ?? false
        }) == true
        && lastAttempt?.terminalCode == .executionFailed
        && lastAttempt?.taskResult == nil
        && !(record.recoveryPolicy == .nonReplayableMutation
          && lastAttempt?.mutationName != nil)
        && ((record.state == .cancelled && record.terminalReason?.code == .cancelled)
          || (record.state == .failed && record.terminalReason?.code == .budgetExceeded))

      if record.state.isTerminal {
        guard record.settledAt != nil, record.terminalReason != nil,
          record.lease == nil, record.currentToolExecution == nil,
          record.attempts.isEmpty
            || (record.attempts.last?.endedAt == record.settledAt
              && record.attempts.last?.terminalCode == record.terminalReason?.code
              && record.attempts.last?.terminalDetail == record.terminalReason?.detail)
            || terminalSchedulerDecision
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Terminal task \(record.id) has inconsistent settlement state."
          )
        }
      } else {
        guard record.settledAt == nil, record.terminalReason == nil,
          record.taskResult == nil
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Open task \(record.id) contains terminal evidence."
          )
        }
      }

      switch record.state {
      case .queued:
        guard record.lease == nil, record.currentToolExecution == nil,
          record.attempts.last?.endedAt != nil || record.attempts.isEmpty
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Queued task \(record.id) still has an execution lease."
          )
        }
      case .executingTool:
        guard record.lease != nil, record.currentToolExecution != nil,
          record.attempts.last?.endedAt == nil
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Executing task \(record.id) lacks its durable tool boundary."
          )
        }
      case .preparing, .generating, .awaitingApproval, .settling:
        guard record.lease != nil, record.attempts.last?.endedAt == nil else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Active task \(record.id) lacks an execution lease."
          )
        }
      case .completed, .failed, .cancelled, .ambiguousAfterCrash:
        break
      }

      let lastAttemptHasMutation = record.attempts.last?.mutationName != nil
      if record.state == .queued || terminalSchedulerDecision {
        guard !record.hasBegunMutation,
          record.state != .queued
            || record.recoveryPolicy != .nonReplayableMutation
            || record.attempts.allSatisfy({ $0.mutationName == nil })
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Queued task \(record.id) retains mutation evidence that cannot be replayed."
          )
        }
      } else {
        guard record.hasBegunMutation == lastAttemptHasMutation else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) mutation flag disagrees with its current attempt evidence."
          )
        }
      }

      if record.hasBegunMutation {
        guard let attempt = record.attempts.last,
          let mutationName = attempt.mutationName,
          !mutationName.isEmpty,
          record.recoveryPolicy != .readOnly
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) has an invalid mutation boundary."
          )
        }
        switch record.recoveryPolicy {
        case .readOnly:
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Read-only task \(record.id) contains a mutation boundary."
          )
        case .nonReplayableMutation:
          guard attempt.mutationIdempotencyKey == nil else {
            throw BackgroundAgentTaskStoreError.corruptedStore(
              "Non-replayable task \(record.id) contains an idempotency key."
            )
          }
        case .idempotentMutation(let key):
          guard attempt.mutationIdempotencyKey == key else {
            throw BackgroundAgentTaskStoreError.corruptedStore(
              "Task \(record.id) mutation key does not match its recovery policy."
            )
          }
        }
        if let tool = record.currentToolExecution, tool.isMutation {
          guard tool.name == attempt.mutationName,
            tool.idempotencyKey == attempt.mutationIdempotencyKey
          else {
            throw BackgroundAgentTaskStoreError.corruptedStore(
              "Task \(record.id) tool boundary disagrees with its attempt evidence."
            )
          }
        }
      } else if record.currentToolExecution?.isMutation == true {
        throw BackgroundAgentTaskStoreError.corruptedStore(
          "Task \(record.id) hides an active mutation boundary."
        )
      }

      if let result = record.taskResult {
        let projected = try settlement(for: result, record: record)
        guard projected.state == record.state,
          projected.code == record.terminalReason?.code,
          projected.detail == record.terminalReason?.detail,
          record.attempts.last?.terminalCode == projected.code,
          record.attempts.last?.terminalDetail == projected.detail,
          record.attempts.last?.taskResult == result,
          record.attempts.last?.endedAt == record.settledAt
        else {
          throw BackgroundAgentTaskStoreError.corruptedStore(
            "Task \(record.id) canonical result disagrees with scheduler settlement."
          )
        }
      }
      if record.state == .completed, record.taskResult == nil {
        throw BackgroundAgentTaskStoreError.corruptedStore(
          "Completed task \(record.id) lacks its canonical task result."
        )
      }
    }
  }

  private static func allowsTransition(
    from: BackgroundAgentTaskState,
    to: BackgroundAgentTaskState
  ) -> Bool {
    switch (from, to) {
    case (.preparing, .generating),
      (.generating, .awaitingApproval),
      (.awaitingApproval, .generating),
      (.generating, .executingTool),
      (.awaitingApproval, .executingTool),
      (.executingTool, .generating),
      (.generating, .settling),
      (.awaitingApproval, .settling),
      (.executingTool, .settling):
      true
    default:
      false
    }
  }

  // `Duration.seconds(Double)` must convert the value to its fixed-width internal
  // representation. Keep accepted persisted values within an Int64 nanosecond range so
  // an adversarial but finite budget cannot trap the process during Task.sleep.
  private static let maximumSupportedDurationSeconds = TimeInterval(
    Int64.max / 1_000_000_000
  )

  private static func settlement(
    for result: AgentTaskResult,
    record: BackgroundAgentTaskRecord
  ) throws -> (
    state: BackgroundAgentTaskState,
    code: BackgroundAgentTaskTerminalCode,
    detail: String?
  ) {
    guard result.lineage.taskID == record.id.agentTaskID,
      result.lineage == record.currentAttemptLineage
    else {
      throw BackgroundAgentTaskCoordinatorError.taskResultMismatch
    }

    if hasUncertainMutation(record),
      result.status != .succeeded,
      result.status != .ambiguousAfterCrash
    {
      throw BackgroundAgentTaskCoordinatorError.taskResultMismatch
    }

    switch result.status {
    case .succeeded:
      return (.completed, .completed, nil)
    case .denied:
      return (.failed, .denied, result.failureReason?.message)
    case .failed:
      return (.failed, .executionFailed, result.failureReason?.message)
    case .cancelled:
      return (.cancelled, .cancelled, result.cancellationReason?.message)
    case .timedOut:
      return (.failed, .timedOut, result.failureReason?.message)
    case .ambiguousAfterCrash:
      return (.ambiguousAfterCrash, .ambiguousAfterCrash, result.failureReason?.message)
    }
  }

  private static func hasUncertainMutation(_ record: BackgroundAgentTaskRecord) -> Bool {
    record.recoveryPolicy == .nonReplayableMutation && record.hasBegunMutation
  }

  private static func settleCurrentAttempt(
    in record: inout BackgroundAgentTaskRecord,
    at timestamp: Date,
    code: BackgroundAgentTaskTerminalCode,
    detail: String?,
    taskResult: AgentTaskResult? = nil
  ) {
    guard let current = record.attempts.last, current.endedAt == nil else {
      return
    }
    let index = record.attempts.index(before: record.attempts.endIndex)
    record.attempts[index].endedAt = timestamp
    record.attempts[index].terminalCode = code
    record.attempts[index].terminalDetail = detail
    record.attempts[index].taskResult = taskResult
  }
}

private enum BackgroundAgentTaskExecutionRace: Sendable {
  case finished(BackgroundAgentTaskOutcome)
  case wallClockExpired
}

private struct BackgroundAgentTaskSettlementWaiter {
  let id: UUID
  let continuation: CheckedContinuation<BackgroundAgentTaskRecord, any Error>
}
