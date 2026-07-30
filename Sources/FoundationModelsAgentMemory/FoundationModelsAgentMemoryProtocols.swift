import Foundation

public protocol FoundationModelsAgentMemoryStore: Sendable {
  func save(_ record: FoundationModelsAgentMemoryRecord) async throws
  func saveEpisode(
    _ episode: FoundationModelsAgentMemoryRecord,
    enqueueing job: FoundationModelsAgentMemoryConsolidationJob?
  ) async throws
  func applyCorrection(
    _ correction: FoundationModelsAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) async throws
  func record(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
    -> FoundationModelsAgentMemoryRecord?
  func records(ids: [UUID], in scope: FoundationModelsAgentMemoryScope) async throws
    -> [FoundationModelsAgentMemoryRecord]
  func records(in scope: FoundationModelsAgentMemoryScope) async throws
    -> [FoundationModelsAgentMemoryRecord]
  func lexicalSearch(
    query: String,
    in scope: FoundationModelsAgentMemoryScope,
    limit: Int
  ) async throws -> [FoundationModelsAgentMemorySearchCandidate]
  func updateIndexState(
    _ state: FoundationModelsAgentMemoryIndexState,
    for id: UUID,
    in scope: FoundationModelsAgentMemoryScope
  ) async throws
  func tombstone(
    id: UUID,
    in scope: FoundationModelsAgentMemoryScope,
    reason: String?
  ) async throws -> FoundationModelsAgentMemoryTombstone
  func tombstone(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
    -> FoundationModelsAgentMemoryTombstone?
  func purge(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
  func purge(scope: FoundationModelsAgentMemoryScope) async throws

  func save(_ candidate: FoundationModelsAgentMemoryCandidate) async throws
  func candidate(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
    -> FoundationModelsAgentMemoryCandidate?
  func candidates(
    in scope: FoundationModelsAgentMemoryScope,
    status: FoundationModelsAgentMemoryCandidateStatus?
  ) async throws -> [FoundationModelsAgentMemoryCandidate]
  func approveCandidate(
    id: UUID,
    as record: FoundationModelsAgentMemoryRecord,
    in scope: FoundationModelsAgentMemoryScope
  ) async throws
  func rejectCandidate(
    id: UUID,
    in scope: FoundationModelsAgentMemoryScope,
    reason: String?
  ) async throws

  func save(_ job: FoundationModelsAgentMemoryConsolidationJob) async throws
  func consolidationJob(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
    -> FoundationModelsAgentMemoryConsolidationJob?
  func consolidationJobs(
    in scope: FoundationModelsAgentMemoryScope,
    statuses: Set<FoundationModelsAgentMemoryConsolidationJobStatus>
  ) async throws -> [FoundationModelsAgentMemoryConsolidationJob]
  /// Atomically moves one eligible job to processing and returns it to exactly one caller.
  func claimNextConsolidationJob(in scope: FoundationModelsAgentMemoryScope) async throws
    -> FoundationModelsAgentMemoryConsolidationJob?
  /// Releases this store instance's in-process claim without changing durable job state.
  func releaseConsolidationJobClaim(id: UUID, in scope: FoundationModelsAgentMemoryScope) async
  func registerExportDirectory(_ path: String, in scope: FoundationModelsAgentMemoryScope)
    async throws
  func exportDirectories(in scope: FoundationModelsAgentMemoryScope) async throws -> [String]
}

public protocol FoundationModelsAgentMemoryIndex: Sendable {
  func upsert(_ record: FoundationModelsAgentMemoryRecord) async throws
  func search(
    query: String,
    in scope: FoundationModelsAgentMemoryScope,
    limit: Int
  ) async throws -> [FoundationModelsAgentMemorySearchCandidate]
  func remove(id: UUID, in scope: FoundationModelsAgentMemoryScope) async throws
  func removeAll(in scope: FoundationModelsAgentMemoryScope) async throws
}

public protocol FoundationModelsAgentMemoryConsolidator: Sendable {
  func consolidate(episode: FoundationModelsAgentMemoryRecord) async throws
    -> [FoundationModelsAgentMemoryCandidateDraft]
}

public enum FoundationModelsAgentMemoryApprovalDecision: Sendable {
  case approve
  case reject(reason: String?)
  case deferDecision
}

public protocol FoundationModelsAgentMemoryApprovalProvider: Sendable {
  func decision(for candidate: FoundationModelsAgentMemoryCandidate) async throws
    -> FoundationModelsAgentMemoryApprovalDecision
}

public struct DeferFoundationModelsAgentMemoryApprovalProvider:
  FoundationModelsAgentMemoryApprovalProvider
{
  public init() {}

  public func decision(for candidate: FoundationModelsAgentMemoryCandidate)
    -> FoundationModelsAgentMemoryApprovalDecision
  {
    .deferDecision
  }
}

public enum FoundationModelsAgentMemoryEventKind: String, Codable, Sendable {
  case retrievalStarted
  case retrievalFiltered
  case retrievalCompleted
  case contextInjected
  case episodePersisted
  case candidateProposed
  case candidateApproved
  case candidateRejected
  case recordSuperseded
  case indexingFailed
  case indexingRepaired
  case consolidationStarted
  case consolidationCompleted
  case consolidationFailed
  case consolidationCancelled
  case recordTombstoned
  case recordPurged
  case scopePurged
}

public struct FoundationModelsAgentMemoryEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let timestamp: Date
  public let kind: FoundationModelsAgentMemoryEventKind
  public let scope: FoundationModelsAgentMemoryScope
  public let recordID: UUID?
  public let candidateID: UUID?
  public let jobID: UUID?
  public let attributes: [String: String]

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: FoundationModelsAgentMemoryEventKind,
    scope: FoundationModelsAgentMemoryScope,
    recordID: UUID? = nil,
    candidateID: UUID? = nil,
    jobID: UUID? = nil,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.scope = scope
    self.recordID = recordID
    self.candidateID = candidateID
    self.jobID = jobID
    self.attributes = attributes
  }
}

public protocol FoundationModelsAgentMemoryObserver: Sendable {
  func memoryDidEmit(_ event: FoundationModelsAgentMemoryEvent) async
}

public struct ClosureFoundationModelsAgentMemoryObserver: FoundationModelsAgentMemoryObserver {
  private let closure: @Sendable (FoundationModelsAgentMemoryEvent) async -> Void

  public init(_ closure: @escaping @Sendable (FoundationModelsAgentMemoryEvent) async -> Void) {
    self.closure = closure
  }

  public func memoryDidEmit(_ event: FoundationModelsAgentMemoryEvent) async {
    await closure(event)
  }
}
