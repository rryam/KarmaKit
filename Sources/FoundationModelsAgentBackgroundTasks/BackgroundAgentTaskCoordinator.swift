import Foundation

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
  private var settlementWaiters:
    [BackgroundAgentTaskID: [CheckedContinuation<BackgroundAgentTaskRecord, any Error>]] = [:]
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
    var updatedRecords = records
    updatedRecords[record.id] = record
    holdsPersistenceAccess = false
    try await commit(records: updatedRecords, nextSequence: nextSequence + 1)
    try await scheduleEligibleTasks()
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
    await acquirePersistenceAccess()
    releasePersistenceAccess()
    guard let record = records[id] else {
      throw BackgroundAgentTaskCoordinatorError.taskNotFound(id)
    }
    if let failure = settlementFailures[id] {
      throw failure
    }
    if record.state.isTerminal {
      return record
    }
    return try await withCheckedThrowingContinuation { continuation in
      settlementWaiters[id, default: []].append(continuation)
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
      record.state = .cancelled
      record.updatedAt = timestamp
      record.settledAt = timestamp
      record.lease = nil
      record.currentToolExecution = nil
      record.terminalReason = BackgroundAgentTaskTerminalReason(
        code: .cancelled,
        detail: reason
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
    try await scheduleEligibleTasks()
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
      record.state = .cancelled
      record.updatedAt = timestamp
      record.settledAt = timestamp
      record.lease = nil
      record.currentToolExecution = nil
      record.terminalReason = BackgroundAgentTaskTerminalReason(code: .cancelled, detail: reason)
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
      record.attemptCount += 1
      record.lease = BackgroundAgentTaskLease(
        executorID: executorID,
        acquiredAt: timestamp,
        expiresAt: timestamp.addingTimeInterval(configuration.leaseDuration)
      )
      var updatedRecords = records
      updatedRecords[id] = record
      do {
        try await commit(records: updatedRecords, nextSequence: nextSequence)
      } catch {
        notifySettlementFailure(for: id, error: error)
        throw error
      }
      settlementFailures[id] = nil
      running[id] = Task { [weak self] in
        await self?.execute(id)
      }
    }
  }

  private func nextEligibleTaskID() -> BackgroundAgentTaskID? {
    let timestamp = now()
    let candidates = records.values.filter { record in
      guard record.state == .queued else { return false }
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
    let promotions = Int(waited / configuration.starvationInterval)
    return min(BackgroundAgentTaskPriority.critical.rawValue, record.priority.rawValue + promotions)
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
      let result = try await executeWithinWallClockBudget(current, context: context)
      try Task.checkCancellation()
      try await apply(.transition(.settling), to: id)
      let timestamp = now()
      try await persistSettlement(
        id,
        state: .completed,
        reason: BackgroundAgentTaskTerminalReason(
          code: .completed,
          detail: result.terminalDetail
        ),
        at: timestamp
      )
    } catch is CancellationError {
      if let current = records[id], !current.state.isTerminal {
        let timestamp = now()
        do {
          try await persistSettlement(
            id,
            state: .cancelled,
            reason: BackgroundAgentTaskTerminalReason(code: .cancelled),
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
        let code: BackgroundAgentTaskTerminalCode
        if case .budgetExceeded = error {
          code = .budgetExceeded
        } else {
          code = .executionFailed
        }
        do {
          try await persistSettlement(
            id,
            state: .failed,
            reason: BackgroundAgentTaskTerminalReason(
              code: code,
              detail: error.localizedDescription
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
        do {
          try await persistSettlement(
            id,
            state: .failed,
            reason: BackgroundAgentTaskTerminalReason(
              code: .executionFailed,
              detail: String(describing: error)
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
    let nanoseconds = UInt64(min(remaining * 1_000_000_000, Double(UInt64.max)))
    return try await withThrowingTaskGroup(
      of: BackgroundAgentTaskExecutionRace.self,
      returning: BackgroundAgentTaskOutcome.self
    ) { group in
      group.addTask {
        .finished(try await factory(record, context))
      }
      group.addTask {
        try await Task.sleep(nanoseconds: nanoseconds)
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
      guard Self.allowsTransition(from: record.state, to: .executingTool) else {
        throw BackgroundAgentTaskCoordinatorError.invalidStateTransition(
          from: record.state,
          to: .executingTool
        )
      }
      try consume(BackgroundAgentTaskUsage(toolCalls: 1), from: &record)
      record.state = .executingTool
      record.currentToolExecution = BackgroundAgentTaskToolExecution(
        name: name,
        isMutation: false,
        idempotencyKey: nil,
        beganAt: timestamp
      )
    case .executeMutation(let name, let idempotencyKey):
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
      try consume(BackgroundAgentTaskUsage(toolCalls: 1), from: &record)
      record.state = .executingTool
      record.hasBegunMutation = true
      record.currentToolExecution = BackgroundAgentTaskToolExecution(
        name: name,
        isMutation: true,
        idempotencyKey: idempotencyKey,
        beganAt: timestamp
      )
    case .consume(let usage):
      try consume(usage, from: &record)
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
  }

  private func consume(
    _ usage: BackgroundAgentTaskUsage, from record: inout BackgroundAgentTaskRecord
  ) throws {
    guard usage.turns >= 0, usage.toolCalls >= 0, usage.tokens >= 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidRequest(
        "Usage increments must not be negative.")
    }
    let newUsage = BackgroundAgentTaskUsage(
      turns: record.usage.turns + usage.turns,
      toolCalls: record.usage.toolCalls + usage.toolCalls,
      tokens: record.usage.tokens + usage.tokens
    )
    guard newUsage.turns <= record.budget.maximumTurns else {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(
        "turns \(newUsage.turns)/\(record.budget.maximumTurns)"
      )
    }
    guard newUsage.toolCalls <= record.budget.maximumToolCalls else {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(
        "tool calls \(newUsage.toolCalls)/\(record.budget.maximumToolCalls)"
      )
    }
    guard newUsage.tokens <= record.budget.maximumTokens else {
      throw BackgroundAgentTaskCoordinatorError.budgetExceeded(
        "tokens \(newUsage.tokens)/\(record.budget.maximumTokens)"
      )
    }
    record.usage = newUsage
  }

  private func persistSettlement(
    _ id: BackgroundAgentTaskID,
    state: BackgroundAgentTaskState,
    reason: BackgroundAgentTaskTerminalReason,
    at timestamp: Date
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
      waiter.resume(returning: record)
    }
  }

  private func notifySettlementFailure(for id: BackgroundAgentTaskID, error: any Error) {
    let failure = persistenceError(from: error)
    settlementFailures[id] = failure
    let waiters = settlementWaiters.removeValue(forKey: id) ?? []
    for waiter in waiters {
      waiter.resume(throwing: failure)
    }
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
      let hasUncertainNonReplayableMutation =
        record.recoveryPolicy == .nonReplayableMutation && record.hasBegunMutation
      if record.state == .queued, !hasUncertainNonReplayableMutation {
        continue
      }
      if !force, let lease = record.lease, !lease.isExpired(at: timestamp) {
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
    nextSequence updatedNextSequence: UInt64
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
      releasePersistenceAccess()
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
    let budget = request.budget
    guard budget.maximumWallClock > 0, budget.maximumAttempts > 0,
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
    guard configuration.leaseDuration > 0, configuration.starvationInterval > 0 else {
      throw BackgroundAgentTaskCoordinatorError.invalidConfiguration(
        "lease and starvation intervals must be positive."
      )
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
}

private enum BackgroundAgentTaskExecutionRace: Sendable {
  case finished(BackgroundAgentTaskOutcome)
  case wallClockExpired
}
