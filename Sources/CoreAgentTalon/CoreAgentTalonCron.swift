import Foundation

public struct CoreAgentTalonCronSchedule: Codable, Equatable, Sendable {
  public let intervalSeconds: TimeInterval

  public init(intervalSeconds: TimeInterval) {
    precondition(intervalSeconds > 0, "Cron intervals must be greater than zero.")
    self.intervalSeconds = intervalSeconds
  }

  public static func every(seconds: TimeInterval) -> CoreAgentTalonCronSchedule {
    CoreAgentTalonCronSchedule(intervalSeconds: seconds)
  }

  public func nextRun(after date: Date) -> Date {
    date.addingTimeInterval(intervalSeconds)
  }
}

public struct CoreAgentTalonCronJob: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: CoreAgentTalonConversationID
  public let prompt: String
  public let schedule: CoreAgentTalonCronSchedule
  public var nextRunAt: Date
  public var lastRunAt: Date?
  public var isEnabled: Bool

  public init(
    id: String,
    conversationID: CoreAgentTalonConversationID,
    prompt: String,
    schedule: CoreAgentTalonCronSchedule,
    nextRunAt: Date,
    lastRunAt: Date? = nil,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.conversationID = conversationID
    self.prompt = prompt
    self.schedule = schedule
    self.nextRunAt = nextRunAt
    self.lastRunAt = lastRunAt
    self.isEnabled = isEnabled
  }
}

public enum CoreAgentTalonCronJobOutcome: Codable, Equatable, Sendable {
  case completed(content: String)
  case failed(errorType: String)
}

public struct CoreAgentTalonCronFireRecord: Codable, Equatable, Sendable {
  public let jobID: String
  public let conversationID: CoreAgentTalonConversationID
  public let firedAt: Date
  public let previousNextRunAt: Date
  public let nextRunAt: Date
  public let outcome: CoreAgentTalonCronJobOutcome

  public init(
    jobID: String,
    conversationID: CoreAgentTalonConversationID,
    firedAt: Date,
    previousNextRunAt: Date,
    nextRunAt: Date,
    outcome: CoreAgentTalonCronJobOutcome
  ) {
    self.jobID = jobID
    self.conversationID = conversationID
    self.firedAt = firedAt
    self.previousNextRunAt = previousNextRunAt
    self.nextRunAt = nextRunAt
    self.outcome = outcome
  }
}

public protocol CoreAgentTalonCronJobStore: Sendable {
  func loadJobs() async throws -> [CoreAgentTalonCronJob]
  func saveJobs(_ jobs: [CoreAgentTalonCronJob]) async throws
}

public actor CoreAgentTalonCronScheduler {
  private let store: any CoreAgentTalonCronJobStore
  private let clock: CoreAgentTalonClock
  private let eventLog: CoreAgentTalonEventLog?
  private let fireJob: @Sendable (CoreAgentTalonCronJob) async -> CoreAgentTalonCronJobOutcome
  /// Serializes store read-modify-write sequences. The scheduler is an actor, so each
  /// method's `await` points (store I/O, `fireJob`) suspend it and let another call
  /// interleave. Without this lock a concurrent `createJob`/`removeJob` running during
  /// `fireDueJobs`'s `await fireJob(...)` would be clobbered when `fireDueJobs` saves its
  /// stale local `jobs` snapshot. The lock makes each load→mutate→save atomic.
  private let lock = CoreAgentTalonAsyncLock()

  public init(
    store: any CoreAgentTalonCronJobStore,
    clock: CoreAgentTalonClock = .system,
    eventLog: CoreAgentTalonEventLog? = nil,
    fire: @escaping @Sendable (CoreAgentTalonCronJob) async -> CoreAgentTalonCronJobOutcome
  ) {
    self.store = store
    self.clock = clock
    self.eventLog = eventLog
    self.fireJob = fire
  }

  public func createJob(_ job: CoreAgentTalonCronJob) async throws {
    try await lock.withLock {
      var jobs = try await self.store.loadJobs()
      jobs.removeAll { $0.id == job.id }
      jobs.append(job)
      try await self.store.saveJobs(Self.sorted(jobs))
      await self.eventLog?.record(
        source: .cron,
        conversationID: job.conversationID,
        payload: .cron(
          CoreAgentTalonCronEvent(
            transition: .jobCreated,
            jobID: job.id,
            nextRunAt: job.nextRunAt
          )
        )
      )
    }
  }

  public func listJobs() async throws -> [CoreAgentTalonCronJob] {
    try await lock.withLock {
      try await Self.sorted(self.store.loadJobs())
    }
  }

  public func removeJob(id: String) async throws {
    try await lock.withLock {
      var jobs = try await self.store.loadJobs()
      let removed = jobs.filter { $0.id == id }
      jobs.removeAll { $0.id == id }
      try await self.store.saveJobs(Self.sorted(jobs))
      for job in removed {
        await self.eventLog?.record(
          source: .cron,
          conversationID: job.conversationID,
          payload: .cron(CoreAgentTalonCronEvent(transition: .jobRemoved, jobID: job.id))
        )
      }
    }
  }

  public func fireDueJobs() async throws -> [CoreAgentTalonCronFireRecord] {
    try await lock.withLock {
      let now = self.clock.now()
      var jobs = try await self.store.loadJobs()
      let dueIndexes = jobs.indices.filter { jobs[$0].isEnabled && jobs[$0].nextRunAt <= now }
        .sorted { lhs, rhs in
          let left = jobs[lhs]
          let right = jobs[rhs]
          if left.nextRunAt == right.nextRunAt {
            return left.id < right.id
          }
          return left.nextRunAt < right.nextRunAt
        }

      var records: [CoreAgentTalonCronFireRecord] = []
      for index in dueIndexes {
        try Task.checkCancellation()
        let job = jobs[index]
        let outcome = await self.fireJob(job)
        let nextRunAt = job.schedule.nextRun(after: now)
        jobs[index].lastRunAt = now
        jobs[index].nextRunAt = nextRunAt
        let record = CoreAgentTalonCronFireRecord(
          jobID: job.id,
          conversationID: job.conversationID,
          firedAt: now,
          previousNextRunAt: job.nextRunAt,
          nextRunAt: nextRunAt,
          outcome: outcome
        )
        records.append(record)
        await self.eventLog?.record(
          source: .cron,
          conversationID: job.conversationID,
          payload: .cron(
            CoreAgentTalonCronEvent(
              transition: .jobFired,
              jobID: job.id,
              nextRunAt: nextRunAt,
              outcome: outcome
            )
          )
        )
      }
      if !records.isEmpty {
        try await self.store.saveJobs(Self.sorted(jobs))
      }
      return records
    }
  }

  private static func sorted(_ jobs: [CoreAgentTalonCronJob]) -> [CoreAgentTalonCronJob] {
    jobs.sorted {
      if $0.nextRunAt == $1.nextRunAt {
        return $0.id < $1.id
      }
      return $0.nextRunAt < $1.nextRunAt
    }
  }
}
