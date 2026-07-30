import Foundation
import FoundationModelsAgent
import Synchronization
import Testing

@testable import FoundationModelsAgentBackgroundTasks

@Suite("Durable background task coordinator")
struct FoundationModelsAgentBackgroundTaskTests {
  @Test("Restarts work that stopped while preparing")
  func restartBeforeExecution() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = makeRecord(
      state: .preparing,
      recoveryPolicy: .readOnly,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(30))
    )
    let store = InMemoryBackgroundAgentTaskStore(
      snapshot: snapshot(records: [record])
    )
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      now: { now },
      executionFactory: { task, _ in
        await calls.append(task.prompt)
        return try successfulOutcome(for: task)
      }
    )

    try await coordinator.start()
    let settled = try await coordinator.waitForSettlement(of: record.id)

    #expect(settled.state == .completed)
    #expect(settled.attemptCount == 2)
    #expect(await calls.values == [record.prompt])
  }

  @Test("Restarts generation but does not replay an ambiguous mutation")
  func crashRecoveryClassification() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let generating = makeRecord(
      id: BackgroundAgentTaskID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
      prompt: "resume generation",
      sequence: 0,
      submittedAt: now.addingTimeInterval(-5),
      state: .generating,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    let ambiguous = makeRecord(
      id: BackgroundAgentTaskID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
      prompt: "do not replay charge",
      sequence: 1,
      submittedAt: now.addingTimeInterval(-5),
      state: .executingTool,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1)),
      hasBegunMutation: true,
      currentToolExecution: BackgroundAgentTaskToolExecution(
        name: "charge",
        isMutation: true,
        idempotencyKey: nil,
        beganAt: now.addingTimeInterval(-2)
      )
    )
    let idempotent = makeRecord(
      id: BackgroundAgentTaskID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
      prompt: "replay idempotent charge",
      sequence: 2,
      submittedAt: now.addingTimeInterval(-5),
      state: .settling,
      recoveryPolicy: .idempotentMutation(idempotencyKey: "charge-3"),
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    let afterMutation = makeRecord(
      id: BackgroundAgentTaskID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
      prompt: "do not replay after charge",
      sequence: 3,
      submittedAt: now.addingTimeInterval(-5),
      state: .generating,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1)),
      hasBegunMutation: true
    )
    let store = InMemoryBackgroundAgentTaskStore(
      snapshot: snapshot(records: [generating, ambiguous, idempotent, afterMutation])
    )
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      now: { now },
      executionFactory: { task, _ in
        await calls.append(task.prompt)
        return try successfulOutcome(for: task)
      }
    )

    try await coordinator.start()
    let generatedResult = try await coordinator.waitForSettlement(of: generating.id)
    let ambiguousResult = try await coordinator.waitForSettlement(of: ambiguous.id)
    let idempotentResult = try await coordinator.waitForSettlement(of: idempotent.id)
    let afterMutationResult = try await coordinator.waitForSettlement(of: afterMutation.id)

    #expect(generatedResult.state == .completed)
    #expect(idempotentResult.state == .completed)
    #expect(ambiguousResult.state == .ambiguousAfterCrash)
    #expect(ambiguousResult.terminalReason?.code == .ambiguousAfterCrash)
    #expect(afterMutationResult.state == .ambiguousAfterCrash)
    #expect(!(await calls.values).contains(ambiguous.prompt))
    #expect(!(await calls.values).contains(afterMutation.prompt))
  }

  @Test("An expired lease is reclaimed and receives a new attempt")
  func expiredLease() async throws {
    let now = Date(timeIntervalSince1970: 3_000)
    let record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .preparing,
      recoveryPolicy: .readOnly,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record])),
      now: { now },
      executionFactory: { task, _ in try successfulOutcome(for: task) }
    )

    try await coordinator.start()
    let settled = try await coordinator.waitForSettlement(of: record.id)

    #expect(settled.state == .completed)
    #expect(settled.attemptCount == 2)
  }

  @Test("Simultaneous resume and cancel prevents duplicate settlement from late success")
  func simultaneousResumeAndCancel() async throws {
    let gate = ExecutionGate()
    let store = InMemoryBackgroundAgentTaskStore()
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "hold",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)

    async let resumed: Void = coordinator.resume()
    async let cancelled: Void = coordinator.cancel(id, reason: "user")
    _ = try await (resumed, cancelled)
    await gate.releaseAll()
    let settled = try await coordinator.waitForSettlement(of: id)
    for _ in 0..<4 { await Task.yield() }

    #expect(settled.state == .cancelled)
    #expect(settled.terminalReason?.detail == "user")
    let snapshots = await store.snapshots()
    let terminalStates = snapshots.compactMap { snapshot in
      snapshot.records.first(where: { $0.id == id }).flatMap {
        $0.state.isTerminal ? $0.state : nil
      }
    }
    #expect(!terminalStates.isEmpty)
    #expect(terminalStates.allSatisfy { $0 == .cancelled })
  }

  @Test("Cancelling a scheduled task releases its slot to queued work")
  func cancelledScheduledTaskReschedulesQueue() async throws {
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(),
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      if task.prompt == "first" {
        await gate.run(task)
      }
      return try successfulOutcome(for: task)
    }
    let first = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "first",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    let second = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "second",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )

    try await coordinator.cancel(first)
    await gate.releaseAll()
    for _ in 0..<1_000 {
      if await coordinator.record(for: second)?.state.isTerminal == true {
        break
      }
      await Task.yield()
    }

    #expect(await coordinator.record(for: first)?.state == .cancelled)
    #expect(await coordinator.record(for: second)?.state == .completed)
  }

  @Test("Bounds global concurrency, per-parent concurrency, fan-out, and depth")
  func hierarchyAndConcurrencyBounds() async throws {
    let gate = ExecutionGate()
    let configuration = BackgroundAgentTaskCoordinatorConfiguration(
      maximumConcurrentTasks: 2,
      maximumConcurrentTasksPerParent: 1,
      maximumDepth: 1,
      maximumFanOutPerParent: 2,
      starvationInterval: 30
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(),
      configuration: configuration
    ) { task, _ in
      if task.parentTaskID != nil {
        await gate.run(task)
      }
      return try successfulOutcome(for: task)
    }
    let root1 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root-1",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    let root2 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root-2",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    _ = try await coordinator.waitForSettlement(of: root1)
    _ = try await coordinator.waitForSettlement(of: root2)
    let root1Lineage = try #require(await coordinator.record(for: root1)?.taskResult?.lineage)
    let root2Lineage = try #require(await coordinator.record(for: root2)?.taskResult?.lineage)

    let child1 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-1",
        ownerID: "owner",
        parentLineage: root1Lineage,
        parentTaskID: root1,
        recoveryPolicy: .readOnly
      )
    )
    let child2 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-2",
        ownerID: "owner",
        parentLineage: root1Lineage,
        parentTaskID: root1,
        recoveryPolicy: .readOnly
      )
    )
    let child3 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-3",
        ownerID: "owner",
        parentLineage: root2Lineage,
        parentTaskID: root2,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(2)
    let child1Lineage = try #require(
      await coordinator.record(for: child1)?.currentAttemptLineage
    )

    #expect(await gate.maximumConcurrent == 2)
    #expect(await gate.maximumConcurrentForOneParent == 1)
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "fan-out-overflow",
          ownerID: "owner",
          parentLineage: root1Lineage,
          parentTaskID: root1,
          recoveryPolicy: .readOnly
        )
      )
    }
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "too-deep",
          ownerID: "owner",
          parentLineage: child1Lineage,
          parentTaskID: child1,
          recoveryPolicy: .readOnly
        )
      )
    }

    await gate.releaseAll()
    await gate.waitForStartedCount(3)
    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: child1)
    _ = try await coordinator.waitForSettlement(of: child2)
    _ = try await coordinator.waitForSettlement(of: child3)
  }

  @Test("Durable lease commit reserves the global execution slot")
  func durableLeaseReservesGlobalSlot() async throws {
    let store = SuspendingSaveBackgroundAgentTaskStore(suspendingSaveNumbers: [2])
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }

    let firstSubmission = Task {
      try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "first",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: .readOnly
        )
      )
    }
    await store.waitForSaveCount(2)
    let secondSubmission = Task {
      try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "second",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: .readOnly
        )
      )
    }

    await store.release(saveNumber: 2)
    let first = try await firstSubmission.value
    let second = try await secondSubmission.value
    await gate.waitForStartedCount(1)
    for _ in 0..<100 { await Task.yield() }

    #expect(await gate.maximumConcurrent == 1)
    #expect(await gate.totalStarted == 1)

    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: first)
    await gate.waitForStartedCount(2)
    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: second)
    #expect(await gate.maximumConcurrent == 1)
  }

  @Test("Durable lease commit reserves the per-parent execution slot")
  func durableLeaseReservesParentSlot() async throws {
    let store = SuspendingSaveBackgroundAgentTaskStore(suspendingSaveNumbers: [4])
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      configuration: .init(
        maximumConcurrentTasks: 3,
        maximumConcurrentTasksPerParent: 1
      )
    ) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let parent = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "parent",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)
    let parentLineage = try #require(await coordinator.record(for: parent)?.currentAttemptLineage)

    let firstChildSubmission = Task {
      try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "first child",
          ownerID: "owner",
          parentLineage: parentLineage,
          parentTaskID: parent,
          recoveryPolicy: .readOnly
        )
      )
    }
    await store.waitForSaveCount(4)
    let secondChildSubmission = Task {
      try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "second child",
          ownerID: "owner",
          parentLineage: parentLineage,
          parentTaskID: parent,
          recoveryPolicy: .readOnly
        )
      )
    }

    await store.release(saveNumber: 4)
    let firstChild = try await firstChildSubmission.value
    let secondChild = try await secondChildSubmission.value
    await gate.waitForStartedCount(2)
    for _ in 0..<100 { await Task.yield() }

    #expect(await gate.maximumConcurrentForOneParent == 1)

    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: parent)
    _ = try await coordinator.waitForSettlement(of: firstChild)
    await gate.waitForStartedCount(3)
    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: secondChild)
    #expect(await gate.maximumConcurrentForOneParent == 1)
  }

  @Test("Aged work prevents starvation while FIFO keeps distinct prompts")
  func starvationPreventionAndFIFO() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let oldLow = makeRecord(
      prompt: "old low",
      sequence: 0,
      submittedAt: now.addingTimeInterval(-100),
      state: .queued,
      recoveryPolicy: .readOnly
    )
    let firstHigh = makeRecord(
      prompt: "first high",
      sequence: 1,
      submittedAt: now,
      state: .queued,
      recoveryPolicy: .readOnly,
      priority: .high
    )
    let secondHigh = makeRecord(
      prompt: "second high",
      sequence: 2,
      submittedAt: now,
      state: .queued,
      recoveryPolicy: .readOnly,
      priority: .high
    )
    let capture = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(
        snapshot: snapshot(records: [oldLow, firstHigh, secondHigh])
      ),
      configuration: .init(
        maximumConcurrentTasks: 1,
        starvationInterval: 30
      ),
      now: { now },
      executionFactory: { task, _ in
        await capture.append(task.prompt)
        return try successfulOutcome(for: task)
      }
    )

    try await coordinator.start()
    _ = try await coordinator.waitForSettlement(of: oldLow.id)
    _ = try await coordinator.waitForSettlement(of: firstHigh.id)
    _ = try await coordinator.waitForSettlement(of: secondHigh.id)

    #expect(await capture.values == ["old low", "first high", "second high"])
    #expect((await coordinator.allRecords()).count == 3)
  }

  @Test("Matching prompt text is never coalesced")
  func matchingPromptsRemainDistinct() async throws {
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(),
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      await calls.append(task.prompt)
      return try successfulOutcome(for: task)
    }
    let first = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "same prompt",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    let second = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "same prompt",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )

    _ = try await coordinator.waitForSettlement(of: first)
    _ = try await coordinator.waitForSettlement(of: second)

    #expect(first != second)
    #expect(await calls.values == ["same prompt", "same prompt"])
  }

  @Test("Usage budgets fail a task deterministically")
  func usageBudget() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, context in
      try await context.recordUsage(turns: 2, tokens: 11)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "bounded",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly,
        budget: BackgroundAgentTaskBudget(
          maximumTurns: 1,
          maximumToolCalls: 0,
          maximumTokens: 10
        )
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .failed)
    #expect(settled.terminalReason?.code == .budgetExceeded)
  }

  @Test("Wall-clock budget cancels cooperative execution")
  func wallClockBudget() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, _ in
      try await Task.sleep(for: .seconds(1))
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "slow",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly,
        budget: BackgroundAgentTaskBudget(maximumWallClock: 0.02)
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .failed)
    #expect(settled.terminalReason?.code == .budgetExceeded)
  }

  @Test("A replayable mutation must present its declared idempotency key")
  func mutationRecoveryDeclaration() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, context in
      try await context.markExecutingMutation(named: "charge", idempotencyKey: "wrong")
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "charge",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .idempotentMutation(idempotencyKey: "stable-key")
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .failed)
    #expect(settled.terminalReason?.detail?.contains("idempotency") == true)
  }

  @Test("Hierarchical cancellation settles queued descendants")
  func hierarchicalCancellation() async throws {
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(),
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let root = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)
    let rootLineage = try #require(await coordinator.record(for: root)?.currentAttemptLineage)
    let child = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child",
        ownerID: "owner",
        parentLineage: rootLineage,
        parentTaskID: root,
        recoveryPolicy: .readOnly
      )
    )

    try await coordinator.cancel(root)
    await gate.releaseAll()

    #expect(try await coordinator.waitForSettlement(of: root).state == .cancelled)
    #expect(try await coordinator.waitForSettlement(of: child).state == .cancelled)
  }

  @Test("File store round-trips versioned records and rejects corruption")
  func fileStoreAndCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "background-tasks.json")
    let store = try FileBackgroundAgentTaskStore(fileURL: fileURL)
    let record = makeRecord(state: .queued, recoveryPolicy: .readOnly)
    let saved = snapshot(records: [record])

    try await store.saveSnapshot(saved)
    let loaded = try #require(try await store.loadSnapshot())

    #expect(loaded.records == [record])
    #expect(loaded.formatVersion == BackgroundAgentTaskStoreSnapshot.currentFormatVersion)

    try Data("{broken".utf8).write(to: fileURL, options: .atomic)
    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      _ = try await store.loadSnapshot()
    }
  }

  @Test(
    "Successful execution stays nonterminal when settlement persistence fails",
    arguments: [4, 5]
  )
  func successfulExecutionPersistenceFailure(failingSave: Int) async throws {
    let store = FailingSaveBackgroundAgentTaskStore(failingSaveNumbers: [failingSave])
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "complete once",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )

    await store.waitForSaveCount(failingSave)
    for _ in 0..<100 { await Task.yield() }
    let record = try #require(await coordinator.record(for: id))
    let durable = try #require(await store.loadSnapshot())

    let expectedState: BackgroundAgentTaskState = failingSave == 4 ? .generating : .settling
    #expect(record.state == expectedState)
    #expect(!record.state.isTerminal)
    #expect(record.terminalReason == nil)
    #expect(durable.records.first?.state != .completed)

    try await coordinator.resume()
    let recovered = try await coordinator.waitForSettlement(of: id)
    #expect(recovered.state == .completed)
    #expect(recovered.attempts.count == 2)
  }

  @Test("Persistence lane prevents concurrent state from overwriting newer snapshots")
  func persistenceLaneSerializesConcurrentStateChanges() async throws {
    let executionGate = ExecutionGate()
    let store = SuspendingSaveBackgroundAgentTaskStore(suspendingSaveNumbers: [3])
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      if task.prompt == "first" {
        await executionGate.run(task)
      }
      return try successfulOutcome(for: task)
    }
    let firstRequest = BackgroundAgentTaskRequest(
      prompt: "first",
      ownerID: "owner",
      parentLineage: testParentLineage,
      recoveryPolicy: .readOnly
    )
    let first = try await coordinator.submit(firstRequest)
    await store.waitForSaveCount(3)

    let secondSubmission = Task {
      try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "second",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: .readOnly
        )
      )
    }
    let cancellation = Task {
      try await coordinator.cancel(first, reason: "cancel while update is persisting")
    }
    for _ in 0..<10 { await Task.yield() }
    await store.release(saveNumber: 3)

    let second = try await secondSubmission.value
    try await cancellation.value
    await executionGate.releaseAll()
    let firstResult = try await coordinator.waitForSettlement(of: first)
    let secondResult = try await coordinator.waitForSettlement(of: second)

    #expect(firstResult.state == .cancelled)
    #expect(secondResult.state == .completed)
    let snapshots = await store.snapshots()
    let firstTerminalStates = snapshots.compactMap { snapshot in
      snapshot.records.first(where: { $0.id == first }).flatMap {
        $0.state.isTerminal ? $0.state : nil
      }
    }
    #expect(!firstTerminalStates.isEmpty)
    #expect(firstTerminalStates.allSatisfy { $0 == .cancelled })
  }

  @Test("Settlement waiters resume only after cancellation is durable")
  func settlementWaiterRequiresDurableCancellation() async throws {
    let executionGate = ExecutionGate()
    let store = SuspendingSaveBackgroundAgentTaskStore(suspendingSaveNumbers: [4])
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      await executionGate.run(task)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "cancel durably",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await executionGate.waitForStartedCount(1)

    let cancellation = Task {
      try await coordinator.cancel(id)
    }
    await store.waitForSaveCount(4)
    let observer = SettlementObserver()
    let waiter = Task {
      let record = try await coordinator.waitForSettlement(of: id)
      await observer.recordSettlement()
      return record
    }
    for _ in 0..<100 { await Task.yield() }

    #expect(!(await observer.hasSettled))
    await store.release(saveNumber: 4)
    try await cancellation.value
    let settled = try await waiter.value
    await executionGate.releaseAll()

    #expect(settled.state == .cancelled)
    #expect(await observer.hasSettled)
  }

  @Test("A failed settlement write throws to an existing waiter")
  func failedSettlementWriteNotifiesWaiter() async throws {
    let executionGate = ExecutionGate()
    let store = FailingSaveBackgroundAgentTaskStore(failingSaveNumbers: [5])
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      await executionGate.run(task)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "fail settlement",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await executionGate.waitForStartedCount(1)
    let waiter = Task {
      try await coordinator.waitForSettlement(of: id)
    }

    await executionGate.releaseAll()
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await waiter.value
    }
    #expect(await coordinator.record(for: id)?.state == .settling)
  }

  @Test("A failed preparing write leaves accepted work queued for resume")
  func preparingPersistenceFailureRestoresQueue() async throws {
    let store = FailingSaveBackgroundAgentTaskStore(failingSaveNumbers: [2])
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      try successfulOutcome(for: task)
    }
    let request = BackgroundAgentTaskRequest(
      prompt: "retry preparing",
      ownerID: "owner",
      parentLineage: testParentLineage,
      recoveryPolicy: .readOnly
    )

    let acceptedID = try await coordinator.submit(request)
    #expect(acceptedID == request.id)
    #expect(await coordinator.record(for: request.id)?.state == .queued)
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.waitForSettlement(of: request.id)
    }

    try await coordinator.resume()
    let settled = try await coordinator.waitForSettlement(of: request.id)
    #expect(settled.state == .completed)
    #expect(settled.attemptCount == 1)
  }

  @Test("A scheduling write failure reaches the next task's settlement waiter")
  func schedulingFailureAfterExecutionNotifiesNextTask() async throws {
    let executionGate = ExecutionGate()
    let store = FailingSaveBackgroundAgentTaskStore(failingSaveNumbers: [7])
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      if task.prompt == "first" {
        await executionGate.run(task)
      }
      return try successfulOutcome(for: task)
    }
    let first = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "first",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await executionGate.waitForStartedCount(1)
    let second = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "second",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )

    await executionGate.releaseAll()
    #expect(try await coordinator.waitForSettlement(of: first).state == .completed)
    await store.waitForSaveCount(7)
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.waitForSettlement(of: second)
    }
    #expect(await coordinator.record(for: second)?.state == .queued)

    try await coordinator.resume()
    #expect(try await coordinator.waitForSettlement(of: second).state == .completed)
  }

  @Test("Start can be retried after recovery persistence fails")
  func retryStartAfterPersistenceFailure() async throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .preparing,
      recoveryPolicy: .readOnly,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    let store = FailingSaveBackgroundAgentTaskStore(
      snapshot: snapshot(records: [record]),
      failingSaveNumbers: [1]
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      now: { now },
      executionFactory: { task, _ in try successfulOutcome(for: task) }
    )

    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      try await coordinator.start()
    }
    try await coordinator.start()
    let settled = try await coordinator.waitForSettlement(of: record.id)

    #expect(settled.state == .completed)
    #expect(settled.attemptCount == 2)
  }

  @Test("An expired local lease never starts a second execution")
  func expiredLocalLeaseDoesNotDuplicateRunningWork() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 30_000))
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(),
      configuration: .init(maximumConcurrentTasks: 2, leaseDuration: 1),
      now: { clock.withLock { $0 } },
      executionFactory: { task, _ in
        await gate.run(task)
        return try successfulOutcome(for: task)
      }
    )
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "one execution",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)
    clock.withLock { $0 = $0.addingTimeInterval(2) }

    try await coordinator.resume()
    for _ in 0..<100 { await Task.yield() }

    #expect(await gate.totalStarted == 1)
    try await coordinator.cancel(id)
    await gate.releaseAll()
    #expect(try await coordinator.waitForSettlement(of: id).state == .cancelled)
  }

  @Test("Cancelling after a non-idempotent boundary remains ambiguous")
  func cancellationAfterMutationIsAmbiguous() async throws {
    let gate = ExecutionGate()
    let store = InMemoryBackgroundAgentTaskStore()
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, context in
      try await context.markExecutingMutation(named: "send_payment")
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "send once",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .nonReplayableMutation
      )
    )
    await gate.waitForStartedCount(1)

    try await coordinator.cancel(id)
    let settled = try await coordinator.waitForSettlement(of: id)
    await gate.releaseAll()

    #expect(settled.state == .ambiguousAfterCrash)
    #expect(settled.terminalReason?.code == .ambiguousAfterCrash)
    #expect(settled.attempts.last?.terminalCode == .ambiguousAfterCrash)
    #expect((await store.loadSnapshot())?.records.first?.state == .ambiguousAfterCrash)
  }

  @Test("An idempotent mutation replays with the same key on a new attempt")
  func idempotentMutationReplaysAcrossAttempts() async throws {
    let now = Date(timeIntervalSince1970: 31_000)
    let record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .executingTool,
      recoveryPolicy: .idempotentMutation(idempotencyKey: "payment:42"),
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1)),
      hasBegunMutation: true,
      currentToolExecution: BackgroundAgentTaskToolExecution(
        name: "send_payment",
        isMutation: true,
        idempotencyKey: "payment:42",
        beganAt: now.addingTimeInterval(-2)
      )
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record])),
      now: { now },
      executionFactory: { task, context in
        try await context.markExecutingMutation(
          named: "send_payment",
          idempotencyKey: "payment:42"
        )
        try await context.markToolFinished()
        return try successfulOutcome(for: task)
      }
    )

    try await coordinator.start()
    let settled = try await coordinator.waitForSettlement(of: record.id)

    #expect(settled.state == .completed)
    #expect(settled.attempts.count == 2)
    #expect(settled.attempts.allSatisfy { $0.mutationIdempotencyKey == "payment:42" })
    #expect(Set(settled.attempts.map(\.lineage.runID)).count == 2)
  }

  @Test("Timeout after a non-idempotent boundary is ambiguous")
  func timeoutAfterMutationIsAmbiguous() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, context in
      try await context.markExecutingMutation(named: "send_payment")
      try await Task.sleep(for: .seconds(1))
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "timeout after payment",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .nonReplayableMutation,
        budget: BackgroundAgentTaskBudget(maximumWallClock: 0.02)
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .ambiguousAfterCrash)
    #expect(settled.terminalReason?.code == .ambiguousAfterCrash)
  }

  @Test("A cancelled settlement waiter does not wait for persistence")
  func cancelledWaiterReturnsWhileStoreIsBlocked() async throws {
    let store = SuspendingSaveBackgroundAgentTaskStore(suspendingSaveNumbers: [3])
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "blocked persistence",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await store.waitForSaveCount(3)
    let waiter = Task {
      try await coordinator.waitForSettlement(of: id)
    }
    waiter.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await waiter.value
    }
    await store.release(saveNumber: 3)
    try await coordinator.cancel(id)
    await gate.releaseAll()
  }

  @Test("Usage overflow is persisted truthfully and fails without trapping")
  func usageOverflowIsSaturated() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, context in
      try await context.recordUsage(tokens: Int.max)
      try await context.recordUsage(tokens: 1)
      return try successfulOutcome(for: task)
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "overflow",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly,
        budget: BackgroundAgentTaskBudget(maximumTokens: Int.max)
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .failed)
    #expect(settled.usage.tokens == Int.max)
    #expect(settled.terminalReason?.detail?.contains("overflow") == true)
  }

  @Test("Malformed snapshots fail before scheduling")
  func malformedSnapshotsFailClosed() async throws {
    let first = makeRecord(
      sequence: 0,
      state: .queued,
      recoveryPolicy: .readOnly
    )
    let second = makeRecord(
      sequence: 0,
      state: .queued,
      recoveryPolicy: .readOnly
    )
    let store = InMemoryBackgroundAgentTaskStore(
      snapshot: BackgroundAgentTaskStoreSnapshot(
        nextSequence: 2,
        records: [first, second]
      )
    )
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
  }

  @Test("Open attempt mutation evidence cannot be hidden from recovery")
  func hiddenMutationEvidenceFailsClosed() async throws {
    let now = Date(timeIntervalSince1970: 10_000)
    var record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .generating,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    record.attempts[0].mutationName = "charge"
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record])),
      now: { now },
      executionFactory: { task, _ in
        await calls.append(task.prompt)
        return try successfulOutcome(for: task)
      }
    )

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
    #expect(await calls.values.isEmpty)
  }

  @Test("Historical mutation evidence must match the durable recovery policy")
  func historicalMutationEvidenceFailsClosed() async throws {
    var record = makeRecord(
      state: .queued,
      recoveryPolicy: .readOnly,
      attemptCount: 1
    )
    record.attempts[0].endedAt = record.submittedAt
    record.attempts[0].terminalCode = .executionFailed
    record.attempts[0].mutationName = "unexpected-write"
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    ) { task, _ in
      try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
  }

  @Test("Queued non-replayable mutation evidence cannot run again")
  func queuedNonReplayableMutationFailsClosed() async throws {
    var record = makeRecord(
      state: .queued,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1
    )
    record.attempts[0].endedAt = record.submittedAt
    record.attempts[0].terminalCode = .executionFailed
    record.attempts[0].mutationName = "charge"
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    ) { task, _ in
      await calls.append(task.prompt)
      return try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
    #expect(await calls.values.isEmpty)
  }

  @Test("Persisted attempts cannot erase cumulative wall-clock time")
  func missingFirstStartedAtFailsClosed() async throws {
    let now = Date(timeIntervalSince1970: 12_000)
    var record = makeRecord(
      submittedAt: now.addingTimeInterval(-60),
      state: .preparing,
      recoveryPolicy: .readOnly,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(-1))
    )
    record.firstStartedAt = nil
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record])),
      now: { now },
      executionFactory: { task, _ in
        await calls.append(task.prompt)
        return try successfulOutcome(for: task)
      }
    )

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
    #expect(await calls.values.isEmpty)
  }

  @Test("Queued recovery budget settlement preserves prior attempt evidence across restart")
  func queuedRecoveryBudgetSettlementRestarts() async throws {
    let now = Date(timeIntervalSince1970: 13_000)
    var record = makeRecord(
      submittedAt: now.addingTimeInterval(-60),
      state: .queued,
      recoveryPolicy: .idempotentMutation(idempotencyKey: "budget-retry"),
      attemptCount: 1,
      budget: BackgroundAgentTaskBudget(maximumWallClock: 1)
    )
    record.attempts[0].endedAt = now.addingTimeInterval(-59)
    record.attempts[0].terminalCode = .executionFailed
    record.attempts[0].terminalDetail = "interrupted"
    record.attempts[0].mutationName = "write"
    record.attempts[0].mutationIdempotencyKey = "budget-retry"
    let store = InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      now: { now },
      executionFactory: { task, _ in
        try successfulOutcome(for: task)
      }
    )

    try await coordinator.start()
    let settled = try await coordinator.waitForSettlement(of: record.id)
    #expect(settled.state == .failed)
    #expect(settled.terminalReason?.code == .budgetExceeded)
    #expect(settled.attempts[0].terminalCode == .executionFailed)
    #expect(settled.attempts[0].terminalDetail == "interrupted")

    let restarted = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      try successfulOutcome(for: task)
    }
    try await restarted.start()
    #expect(await restarted.record(for: record.id)?.state == .failed)
  }

  @Test("Cancelling queued recovered work preserves prior attempt evidence across restart")
  func queuedRecoveryCancellationRestarts() async throws {
    let blocker = makeRecord(
      id: BackgroundAgentTaskID(),
      prompt: "blocker",
      sequence: 0,
      state: .queued,
      recoveryPolicy: .readOnly
    )
    var recovered = makeRecord(
      id: BackgroundAgentTaskID(),
      prompt: "cancel recovered",
      sequence: 1,
      state: .queued,
      recoveryPolicy: .idempotentMutation(idempotencyKey: "cancel-retry"),
      attemptCount: 1
    )
    recovered.attempts[0].endedAt = recovered.submittedAt
    recovered.attempts[0].terminalCode = .executionFailed
    recovered.attempts[0].terminalDetail = "interrupted"
    recovered.attempts[0].mutationName = "write"
    recovered.attempts[0].mutationIdempotencyKey = "cancel-retry"
    let store = InMemoryBackgroundAgentTaskStore(
      snapshot: snapshot(records: [blocker, recovered])
    )
    let gate = ExecutionGate()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: store,
      configuration: .init(maximumConcurrentTasks: 1)
    ) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }

    try await coordinator.start()
    await gate.waitForStartedCount(1)
    try await coordinator.cancel(recovered.id, reason: "user")
    let cancelled = try await coordinator.waitForSettlement(of: recovered.id)
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.attempts[0].terminalCode == .executionFailed)
    #expect(cancelled.attempts[0].terminalDetail == "interrupted")
    await gate.releaseAll()
    _ = try await coordinator.waitForSettlement(of: blocker.id)

    let restarted = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
      try successfulOutcome(for: task)
    }
    try await restarted.start()
    #expect(await restarted.record(for: recovered.id)?.state == .cancelled)
  }

  @Test("A historical canonical success cannot be replayed as queued work")
  func historicalCanonicalResultFailsClosed() async throws {
    var record = makeRecord(
      state: .queued,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 2
    )
    record.attempts[0].endedAt = record.submittedAt
    record.attempts[0].terminalCode = .completed
    record.attempts[0].mutationName = "charge"
    record.attempts[0].taskResult = try AgentTaskResult(
      lineage: record.attempts[0].lineage,
      status: .succeeded,
      timing: AgentTaskTiming(
        queuedAt: record.submittedAt,
        startedAt: record.submittedAt,
        endedAt: record.submittedAt
      )
    )
    record.attempts[1].endedAt = record.submittedAt
    record.attempts[1].terminalCode = .executionFailed
    let calls = ExecutionCapture()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    ) { task, _ in
      await calls.append(task.prompt)
      return try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
    #expect(await calls.values.isEmpty)
  }

  @Test("Successfully settled mutations remain loadable after restart")
  func settledMutationsRestart() async throws {
    let cases: [(BackgroundAgentTaskRecoveryPolicy, String?)] = [
      (.nonReplayableMutation, nil),
      (.idempotentMutation(idempotencyKey: "charge:restart"), "charge:restart"),
    ]

    for (policy, idempotencyKey) in cases {
      let store = InMemoryBackgroundAgentTaskStore()
      let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, context in
        try await context.markExecutingMutation(
          named: "charge",
          idempotencyKey: idempotencyKey
        )
        return try successfulOutcome(for: task)
      }
      let id = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "charge once",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: policy
        )
      )
      let settled = try await coordinator.waitForSettlement(of: id)
      #expect(settled.state == .completed)
      #expect(settled.hasBegunMutation)

      let restarted = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
        try successfulOutcome(for: task)
      }
      try await restarted.start()
      #expect(await restarted.record(for: id)?.state == .completed)
    }
  }

  @Test("Empty tool names fail before persistence and remain restartable")
  func emptyToolNamesFailBeforePersistence() async throws {
    let cases: [(BackgroundAgentTaskRecoveryPolicy, Bool)] = [
      (.readOnly, false),
      (.nonReplayableMutation, true),
      (.idempotentMutation(idempotencyKey: "empty-name"), true),
    ]

    for (policy, isMutation) in cases {
      let store = InMemoryBackgroundAgentTaskStore()
      let coordinator = try BackgroundAgentTaskCoordinator(store: store) { task, context in
        if isMutation {
          let key: String? =
            if case .idempotentMutation(let idempotencyKey) = task.recoveryPolicy {
              idempotencyKey
            } else {
              nil
            }
          try await context.markExecutingMutation(named: " \n", idempotencyKey: key)
        } else {
          try await context.markExecutingTool(named: " \n")
        }
        return try successfulOutcome(for: task)
      }
      let id = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "reject an empty tool name",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: policy
        )
      )
      let settled = try await coordinator.waitForSettlement(of: id)
      #expect(settled.state == .failed)
      #expect(!settled.hasBegunMutation)

      let restarted = try BackgroundAgentTaskCoordinator(store: store) { task, _ in
        try successfulOutcome(for: task)
      }
      try await restarted.start()
      #expect(await restarted.record(for: id)?.state == .failed)
    }
  }

  @Test("Finite wall-clock budgets outside Duration range are rejected")
  func unrepresentableFiniteWallClockFailsClosed() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, _ in
      try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "too long",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: .readOnly,
          budget: BackgroundAgentTaskBudget(maximumWallClock: .greatestFiniteMagnitude)
        )
      )
    }
  }

  @Test("Terminal snapshots cannot retain an open attempt")
  func terminalSnapshotRequiresSettledAttempt() async throws {
    let now = Date(timeIntervalSince1970: 11_000)
    var record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .preparing,
      recoveryPolicy: .readOnly,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(30))
    )
    record.state = .failed
    record.updatedAt = now
    record.settledAt = now
    record.lease = nil
    record.terminalReason = BackgroundAgentTaskTerminalReason(
      code: .executionFailed,
      detail: "failed"
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    ) { task, _ in
      try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
  }

  @Test("Cancellation cannot hide uncertain non-replayable attempt evidence")
  func cancelledMutationSnapshotFailsClosed() async throws {
    let now = Date(timeIntervalSince1970: 14_000)
    var record = makeRecord(
      submittedAt: now.addingTimeInterval(-5),
      state: .preparing,
      recoveryPolicy: .nonReplayableMutation,
      attemptCount: 1,
      lease: lease(expiresAt: now.addingTimeInterval(30))
    )
    record.attempts[0].endedAt = now.addingTimeInterval(-1)
    record.attempts[0].terminalCode = .ambiguousAfterCrash
    record.attempts[0].mutationName = "charge"
    record.state = .cancelled
    record.updatedAt = now
    record.settledAt = now
    record.lease = nil
    record.terminalReason = BackgroundAgentTaskTerminalReason(
      code: .cancelled,
      detail: "hidden uncertainty"
    )
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore(snapshot: snapshot(records: [record]))
    ) { task, _ in
      try successfulOutcome(for: task)
    }

    await #expect(throws: BackgroundAgentTaskStoreError.self) {
      try await coordinator.start()
    }
  }

  @Test("A second file store cannot own the same durable queue")
  func fileStoreOwnershipIsExclusive() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "background-tasks.json")
    let first = try FileBackgroundAgentTaskStore(fileURL: fileURL)

    _ = withExtendedLifetime(first) {
      #expect(throws: BackgroundAgentTaskStoreError.self) {
        _ = try FileBackgroundAgentTaskStore(fileURL: fileURL)
      }
    }
  }

  @Test("Infinite budgets and terminal parents fail before durable acceptance")
  func invalidRequestBoundaries() async throws {
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, _ in
      try successfulOutcome(for: task)
    }
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "infinite",
          ownerID: "owner",
          parentLineage: testParentLineage,
          recoveryPolicy: .readOnly,
          budget: BackgroundAgentTaskBudget(maximumWallClock: .infinity)
        )
      )
    }

    let gate = ExecutionGate()
    let parentCoordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { task, _ in
      await gate.run(task)
      return try successfulOutcome(for: task)
    }
    let parent = try await parentCoordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "cancel parent",
        ownerID: "owner",
        parentLineage: testParentLineage,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)
    let parentLineage = try #require(
      await parentCoordinator.record(for: parent)?.currentAttemptLineage
    )
    try await parentCoordinator.cancel(parent)
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await parentCoordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "late child",
          ownerID: "owner",
          parentLineage: parentLineage,
          parentTaskID: parent,
          recoveryPolicy: .readOnly
        )
      )
    }
    await gate.releaseAll()
  }
}

private let testParentLineage = AgentRunLineage.root()

private func successfulOutcome(
  for record: BackgroundAgentTaskRecord
) throws -> BackgroundAgentTaskOutcome {
  let lineage = try #require(record.currentAttemptLineage)
  let startedAt = record.firstStartedAt ?? record.submittedAt
  let result = try AgentTaskResult(
    lineage: lineage,
    status: .succeeded,
    timing: AgentTaskTiming(
      queuedAt: record.submittedAt,
      startedAt: startedAt,
      endedAt: startedAt
    )
  )
  return BackgroundAgentTaskOutcome(taskResult: result)
}

private func makeRecord(
  id: BackgroundAgentTaskID = BackgroundAgentTaskID(),
  prompt: String = "work",
  sequence: UInt64 = 0,
  submittedAt: Date = Date(timeIntervalSince1970: 900),
  state: BackgroundAgentTaskState,
  recoveryPolicy: BackgroundAgentTaskRecoveryPolicy,
  attemptCount: Int = 0,
  lease: BackgroundAgentTaskLease? = nil,
  hasBegunMutation: Bool = false,
  currentToolExecution: BackgroundAgentTaskToolExecution? = nil,
  priority: BackgroundAgentTaskPriority = .normal,
  budget: BackgroundAgentTaskBudget = .default
) -> BackgroundAgentTaskRecord {
  var attempts = (0..<attemptCount).map { _ in
    BackgroundAgentTaskAttempt(
      lineage: testAttemptLineage(for: id),
      startedAt: submittedAt
    )
  }
  if hasBegunMutation, !attempts.isEmpty {
    let index = attempts.index(before: attempts.endIndex)
    attempts[index].mutationName = currentToolExecution?.name ?? "mutation"
    attempts[index].mutationIdempotencyKey = currentToolExecution?.idempotencyKey
  }
  return BackgroundAgentTaskRecord(
    id: id,
    prompt: prompt,
    ownerID: "owner",
    parentLineage: testParentLineage,
    rootTaskID: id,
    parentTaskID: nil,
    metadata: [:],
    depth: 0,
    priority: priority,
    sequence: sequence,
    recoveryPolicy: recoveryPolicy,
    budget: budget,
    submittedAt: submittedAt,
    updatedAt: submittedAt,
    firstStartedAt: attemptCount == 0 ? nil : submittedAt,
    state: state,
    attemptCount: attemptCount,
    lease: lease,
    hasBegunMutation: hasBegunMutation,
    currentToolExecution: currentToolExecution,
    attempts: attempts
  )
}

private func testAttemptLineage(for id: BackgroundAgentTaskID) -> AgentRunLineage {
  do {
    return try testParentLineage.descendant(
      taskID: id.agentTaskID,
      relationship: .background
    )
  } catch {
    preconditionFailure("The fixed test parent lineage must accept a background descendant.")
  }
}

private func snapshot(
  records: [BackgroundAgentTaskRecord]
) -> BackgroundAgentTaskStoreSnapshot {
  BackgroundAgentTaskStoreSnapshot(
    nextSequence: UInt64(records.count),
    records: records
  )
}

private func lease(expiresAt: Date) -> BackgroundAgentTaskLease {
  BackgroundAgentTaskLease(
    executorID: UUID(),
    acquiredAt: expiresAt.addingTimeInterval(-30),
    expiresAt: expiresAt
  )
}

private actor ExecutionCapture {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor SettlementObserver {
  private(set) var hasSettled = false

  func recordSettlement() {
    hasSettled = true
  }
}

private actor ExecutionGate {
  private var startedCount = 0
  private var activeCount = 0
  private var activeByParent: [BackgroundAgentTaskID: Int] = [:]
  private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var maximumConcurrent = 0
  private(set) var maximumConcurrentForOneParent = 0
  var totalStarted: Int { startedCount }

  func run(_ task: BackgroundAgentTaskRecord) async {
    startedCount += 1
    activeCount += 1
    maximumConcurrent = max(maximumConcurrent, activeCount)
    if let parent = task.parentTaskID {
      activeByParent[parent, default: 0] += 1
      maximumConcurrentForOneParent = max(
        maximumConcurrentForOneParent,
        activeByParent[parent, default: 0]
      )
    }
    let ready = startWaiters.filter { startedCount >= $0.count }
    startWaiters.removeAll { startedCount >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }

    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }

    activeCount -= 1
    if let parent = task.parentTaskID {
      activeByParent[parent, default: 1] -= 1
    }
  }

  func waitForStartedCount(_ count: Int) async {
    if startedCount >= count {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func releaseAll() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor SuspendingSaveBackgroundAgentTaskStore: BackgroundAgentTaskStore {
  private var snapshot: BackgroundAgentTaskStoreSnapshot?
  private var savedSnapshots: [BackgroundAgentTaskStoreSnapshot] = []
  private var suspendingSaveNumbers: Set<Int>
  private var saveCount = 0
  private var saveWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

  init(suspendingSaveNumbers: Set<Int>) {
    self.suspendingSaveNumbers = suspendingSaveNumbers
  }

  func loadSnapshot() -> BackgroundAgentTaskStoreSnapshot? {
    snapshot
  }

  func saveSnapshot(_ snapshot: BackgroundAgentTaskStoreSnapshot) async {
    saveCount += 1
    let currentSave = saveCount
    let ready = saveWaiters.filter { currentSave >= $0.count }
    saveWaiters.removeAll { currentSave >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
    if suspendingSaveNumbers.remove(currentSave) != nil {
      await withCheckedContinuation { continuation in
        releaseWaiters[currentSave] = continuation
      }
    }
    self.snapshot = snapshot
    savedSnapshots.append(snapshot)
  }

  func waitForSaveCount(_ count: Int) async {
    if saveCount >= count {
      return
    }
    await withCheckedContinuation { continuation in
      saveWaiters.append((count, continuation))
    }
  }

  func release(saveNumber: Int) {
    releaseWaiters.removeValue(forKey: saveNumber)?.resume()
  }

  func snapshots() -> [BackgroundAgentTaskStoreSnapshot] {
    savedSnapshots
  }
}

private actor FailingSaveBackgroundAgentTaskStore: BackgroundAgentTaskStore {
  private var snapshot: BackgroundAgentTaskStoreSnapshot?
  private let failingSaveNumbers: Set<Int>
  private var saveCount = 0
  private var saveWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(
    snapshot: BackgroundAgentTaskStoreSnapshot? = nil,
    failingSaveNumbers: Set<Int>
  ) {
    self.snapshot = snapshot
    self.failingSaveNumbers = failingSaveNumbers
  }

  func loadSnapshot() -> BackgroundAgentTaskStoreSnapshot? {
    snapshot
  }

  func saveSnapshot(_ snapshot: BackgroundAgentTaskStoreSnapshot) throws {
    saveCount += 1
    let ready = saveWaiters.filter { saveCount >= $0.count }
    saveWaiters.removeAll { saveCount >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
    if failingSaveNumbers.contains(saveCount) {
      throw TestStoreFailure()
    }
    self.snapshot = snapshot
  }

  func waitForSaveCount(_ count: Int) async {
    if saveCount >= count {
      return
    }
    await withCheckedContinuation { continuation in
      saveWaiters.append((count, continuation))
    }
  }
}

private struct TestStoreFailure: Error {}
