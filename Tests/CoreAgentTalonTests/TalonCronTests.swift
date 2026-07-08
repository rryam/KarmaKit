import CoreAgentTalon
import Foundation
import Testing

private actor TalonCronFireRecorder {
  private(set) var jobIDs: [String] = []

  func fire(_ job: CoreAgentTalonCronJob) -> CoreAgentTalonCronJobOutcome {
    jobIDs.append(job.id)
    return .completed(content: "fired \(job.id)")
  }
}

/// Coordinates a deterministic interleave: the fire handler signals it has started and
/// then blocks until the test releases it, giving the test a window to mutate the store
/// concurrently while `fireDueJobs` is suspended at its `await fireJob(...)` point.
private actor TalonCronFireGate {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func waitForRelease() async {
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

@Suite("CoreAgentTalon cron policy")
struct TalonCronTests {
  @Test("Fires due jobs on an injected clock and persists next run times")
  func firesDueJobsOnInjectedClock() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let dueEarly = CoreAgentTalonCronJob(
      id: "due-a",
      conversationID: CoreAgentTalonConversationID("cron-a"),
      prompt: "first",
      schedule: .every(seconds: 60),
      nextRunAt: now.addingTimeInterval(-10)
    )
    let dueOnTime = CoreAgentTalonCronJob(
      id: "due-b",
      conversationID: CoreAgentTalonConversationID("cron-b"),
      prompt: "second",
      schedule: .every(seconds: 120),
      nextRunAt: now
    )
    let future = CoreAgentTalonCronJob(
      id: "future",
      conversationID: CoreAgentTalonConversationID("cron-c"),
      prompt: "later",
      schedule: .every(seconds: 30),
      nextRunAt: now.addingTimeInterval(1)
    )
    let store = InMemoryCoreAgentTalonCronJobStore(jobs: [future, dueOnTime, dueEarly])
    let recorder = TalonCronFireRecorder()
    let scheduler = CoreAgentTalonCronScheduler(
      store: store,
      clock: CoreAgentTalonClock { now },
      fire: { job in await recorder.fire(job) }
    )

    let records = try await scheduler.fireDueJobs()

    #expect(records.map(\.jobID) == ["due-a", "due-b"])
    #expect(await recorder.jobIDs == ["due-a", "due-b"])
    let persisted = try await store.loadJobs().sorted { $0.id < $1.id }
    #expect(persisted.map(\.id) == ["due-a", "due-b", "future"])
    #expect(persisted[0].lastRunAt == now)
    #expect(persisted[0].nextRunAt == now.addingTimeInterval(60))
    #expect(persisted[1].lastRunAt == now)
    #expect(persisted[1].nextRunAt == now.addingTimeInterval(120))
    #expect(persisted[2].lastRunAt == nil)
    #expect(persisted[2].nextRunAt == now.addingTimeInterval(1))
  }

  @Test("Concurrent createJob during a fire is not clobbered by the fire's save")
  func concurrentCreateDuringFireIsNotLost() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let due = CoreAgentTalonCronJob(
      id: "due",
      conversationID: CoreAgentTalonConversationID("cron-due"),
      prompt: "fire me",
      schedule: .every(seconds: 60),
      nextRunAt: now.addingTimeInterval(-1)
    )
    let store = InMemoryCoreAgentTalonCronJobStore(jobs: [due])
    let gate = TalonCronFireGate()
    let scheduler = CoreAgentTalonCronScheduler(
      store: store,
      clock: CoreAgentTalonClock { now },
      fire: { _ in
        await gate.markStarted()
        await gate.waitForRelease()
        return .completed(content: "fired")
      }
    )

    // Start a fire; it will block inside the handler with the actor suspended.
    let firing = Task { try await scheduler.fireDueJobs() }
    await gate.waitUntilStarted()

    // While the fire is suspended, add a brand-new job. Under the old (unlocked) code
    // this write would be overwritten when fireDueJobs saved its stale snapshot; the
    // serializing lock forces this createJob to run only after the fire completes.
    let added = CoreAgentTalonCronJob(
      id: "added-during-fire",
      conversationID: CoreAgentTalonConversationID("cron-added"),
      prompt: "added",
      schedule: .every(seconds: 30),
      nextRunAt: now.addingTimeInterval(300)
    )
    let adding = Task { try await scheduler.createJob(added) }

    // Let the fire finish, then both operations settle.
    await gate.release()
    _ = try await firing.value
    try await adding.value

    let persisted = try await store.loadJobs().sorted { $0.id < $1.id }
    // Both the fired job (with an advanced next-run time) and the concurrently-added job
    // must survive; nothing is lost to a stale-snapshot overwrite.
    #expect(persisted.map(\.id) == ["added-during-fire", "due"])
    let firedJob = try #require(persisted.first { $0.id == "due" })
    #expect(firedJob.nextRunAt == now.addingTimeInterval(60))
    #expect(firedJob.lastRunAt == now)
  }
}
