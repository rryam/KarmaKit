import Foundation
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
        return BackgroundAgentTaskOutcome()
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
        return BackgroundAgentTaskOutcome()
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
      executionFactory: { _, _ in BackgroundAgentTaskOutcome() }
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
      return BackgroundAgentTaskOutcome(terminalDetail: "late success")
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "hold",
        ownerID: "owner",
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
      return BackgroundAgentTaskOutcome()
    }
    let first = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "first",
        ownerID: "owner",
        recoveryPolicy: .readOnly
      )
    )
    let second = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "second",
        ownerID: "owner",
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
      return BackgroundAgentTaskOutcome()
    }
    let root1 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root-1",
        ownerID: "owner",
        recoveryPolicy: .readOnly
      )
    )
    let root2 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root-2",
        ownerID: "owner",
        recoveryPolicy: .readOnly
      )
    )
    _ = try await coordinator.waitForSettlement(of: root1)
    _ = try await coordinator.waitForSettlement(of: root2)

    let child1 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-1",
        ownerID: "owner",
        parentTaskID: root1,
        recoveryPolicy: .readOnly
      )
    )
    let child2 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-2",
        ownerID: "owner",
        parentTaskID: root1,
        recoveryPolicy: .readOnly
      )
    )
    let child3 = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child-3",
        ownerID: "owner",
        parentTaskID: root2,
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(2)

    #expect(await gate.maximumConcurrent == 2)
    #expect(await gate.maximumConcurrentForOneParent == 1)
    await #expect(throws: BackgroundAgentTaskCoordinatorError.self) {
      _ = try await coordinator.submit(
        BackgroundAgentTaskRequest(
          prompt: "fan-out-overflow",
          ownerID: "owner",
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
        return BackgroundAgentTaskOutcome()
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
      return BackgroundAgentTaskOutcome()
    }
    let first = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "same prompt",
        ownerID: "owner",
        recoveryPolicy: .readOnly
      )
    )
    let second = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "same prompt",
        ownerID: "owner",
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
    ) { _, context in
      try await context.recordUsage(turns: 2, tokens: 11)
      return BackgroundAgentTaskOutcome()
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "bounded",
        ownerID: "owner",
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
    ) { _, _ in
      try await Task.sleep(for: .seconds(1))
      return BackgroundAgentTaskOutcome()
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "slow",
        ownerID: "owner",
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
    ) { _, context in
      try await context.markExecutingMutation(named: "charge", idempotencyKey: "wrong")
      return BackgroundAgentTaskOutcome()
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "charge",
        ownerID: "owner",
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
      return BackgroundAgentTaskOutcome()
    }
    let root = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "root",
        ownerID: "owner",
        recoveryPolicy: .readOnly
      )
    )
    await gate.waitForStartedCount(1)
    let child = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "child",
        ownerID: "owner",
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
    let store = FileBackgroundAgentTaskStore(fileURL: fileURL)
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
  priority: BackgroundAgentTaskPriority = .normal
) -> BackgroundAgentTaskRecord {
  BackgroundAgentTaskRecord(
    id: id,
    prompt: prompt,
    ownerID: "owner",
    rootTaskID: id,
    parentTaskID: nil,
    metadata: [:],
    depth: 0,
    priority: priority,
    sequence: sequence,
    recoveryPolicy: recoveryPolicy,
    budget: .default,
    submittedAt: submittedAt,
    updatedAt: submittedAt,
    firstStartedAt: state == .queued ? nil : submittedAt,
    state: state,
    attemptCount: attemptCount,
    lease: lease,
    hasBegunMutation: hasBegunMutation,
    currentToolExecution: currentToolExecution
  )
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

private actor ExecutionGate {
  private var startedCount = 0
  private var activeCount = 0
  private var activeByParent: [BackgroundAgentTaskID: Int] = [:]
  private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var maximumConcurrent = 0
  private(set) var maximumConcurrentForOneParent = 0

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
