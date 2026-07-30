import Foundation

public actor InMemoryFoundationModelsAgentMemoryStore: FoundationModelsAgentMemoryStore {
  private var storedRecords: [UUID: FoundationModelsAgentMemoryRecord]
  private var storedCandidates: [UUID: FoundationModelsAgentMemoryCandidate]
  private var storedJobs: [UUID: FoundationModelsAgentMemoryConsolidationJob]
  private var claimedJobIDs: Set<UUID>
  private var storedTombstones: [UUID: FoundationModelsAgentMemoryTombstone]
  private var storedExportDirectories: [FoundationModelsAgentMemoryScope: Set<String>]

  public init(
    records: [FoundationModelsAgentMemoryRecord] = [],
    candidates: [FoundationModelsAgentMemoryCandidate] = [],
    jobs: [FoundationModelsAgentMemoryConsolidationJob] = [],
    tombstones: [FoundationModelsAgentMemoryTombstone] = []
  ) {
    self.storedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    self.storedCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    self.storedJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    self.claimedJobIDs = []
    self.storedTombstones = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.id, $0) })
    self.storedExportDirectories = [:]
  }

  public func save(_ record: FoundationModelsAgentMemoryRecord) throws {
    try ensureScope(storedRecords[record.id]?.scope, equals: record.scope)
    try ensureLinkedRecordScopes(record)
    storedRecords[record.id] = record
  }

  public func saveEpisode(
    _ episode: FoundationModelsAgentMemoryRecord,
    enqueueing job: FoundationModelsAgentMemoryConsolidationJob?
  ) throws {
    try ensureScope(storedRecords[episode.id]?.scope, equals: episode.scope)
    try ensureLinkedRecordScopes(episode)
    if let job {
      try ensureScope(storedJobs[job.id]?.scope, equals: job.scope)
      guard job.scope == episode.scope else { throw FoundationModelsAgentMemoryError.scopeMismatch }
    }
    storedRecords[episode.id] = episode
    if let job { storedJobs[job.id] = job }
  }

  public func applyCorrection(
    _ correction: FoundationModelsAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) throws {
    try ensureScope(storedRecords[correction.id]?.scope, equals: correction.scope)
    var existingRecords: [FoundationModelsAgentMemoryRecord] = []
    for id in recordIDs {
      guard let existing = storedRecords[id], existing.scope == correction.scope else {
        throw FoundationModelsAgentMemoryError.recordNotFound(id)
      }
      existingRecords.append(existing)
    }
    try ensureLinkedRecordScopes(correction)
    storedRecords[correction.id] = correction
    for var existing in existingRecords {
      existing.status = .superseded
      existing.supersededBy = correction.id
      existing.updatedAt = Date()
      storedRecords[existing.id] = existing
    }
  }

  public func record(id: UUID, in scope: FoundationModelsAgentMemoryScope)
    -> FoundationModelsAgentMemoryRecord?
  {
    storedRecords[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func records(ids: [UUID], in scope: FoundationModelsAgentMemoryScope)
    -> [FoundationModelsAgentMemoryRecord]
  {
    ids.compactMap { id in storedRecords[id].flatMap { $0.scope == scope ? $0 : nil } }
  }

  public func records(in scope: FoundationModelsAgentMemoryScope)
    -> [FoundationModelsAgentMemoryRecord]
  {
    storedRecords.values
      .filter { $0.scope == scope }
      .sorted(by: Self.recordsBefore)
  }

  public func lexicalSearch(
    query: String,
    in scope: FoundationModelsAgentMemoryScope,
    limit: Int
  ) -> [FoundationModelsAgentMemorySearchCandidate] {
    let terms = Self.terms(in: query)
    return storedRecords.values
      .filter { $0.scope == scope }
      .compactMap { record -> FoundationModelsAgentMemorySearchCandidate? in
        let haystack = record.content.lowercased()
        let matches = terms.reduce(into: 0) { count, term in
          if haystack.contains(term) { count += 1 }
        }
        guard terms.isEmpty || matches > 0 else { return nil }
        let relevance = terms.isEmpty ? 0 : Double(matches) / Double(terms.count)
        return FoundationModelsAgentMemorySearchCandidate(id: record.id, score: relevance)
      }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.id.uuidString < $1.id.uuidString
      }
      .prefix(max(0, limit))
      .map { $0 }
  }

  public func updateIndexState(
    _ state: FoundationModelsAgentMemoryIndexState,
    for id: UUID,
    in scope: FoundationModelsAgentMemoryScope
  ) throws {
    guard var record = storedRecords[id], record.scope == scope else {
      throw FoundationModelsAgentMemoryError.recordNotFound(id)
    }
    record.indexState = state
    record.updatedAt = Date()
    storedRecords[id] = record
  }

  public func tombstone(
    id: UUID,
    in scope: FoundationModelsAgentMemoryScope,
    reason: String?
  ) throws -> FoundationModelsAgentMemoryTombstone {
    guard var record = storedRecords[id], record.scope == scope else {
      throw FoundationModelsAgentMemoryError.recordNotFound(id)
    }
    let tombstone = FoundationModelsAgentMemoryTombstone(recordID: id, scope: scope, reason: reason)
    record.status = .tombstoned
    record.updatedAt = tombstone.deletedAt
    storedRecords[id] = record
    storedTombstones[id] = tombstone
    for (candidateID, var candidate) in storedCandidates
    where candidate.scope == scope
      && candidate.sourceRecordID == id
      && candidate.status == .pending
    {
      candidate.status = .rejected
      candidate.decidedAt = tombstone.deletedAt
      candidate.decisionReason = "source_tombstoned"
      storedCandidates[candidateID] = candidate
    }
    for (jobID, var job) in storedJobs
    where job.scope == scope && job.episodeID == id && job.status != .completed {
      job.status = .cancelled
      job.lastError = "The source episode was tombstoned."
      job.updatedAt = tombstone.deletedAt
      storedJobs[jobID] = job
      claimedJobIDs.remove(jobID)
    }
    return tombstone
  }

  public func tombstone(id: UUID, in scope: FoundationModelsAgentMemoryScope)
    -> FoundationModelsAgentMemoryTombstone?
  {
    storedTombstones[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func purge(id: UUID, in scope: FoundationModelsAgentMemoryScope) {
    guard storedRecords[id]?.scope == scope || storedTombstones[id]?.scope == scope else { return }
    for (linkedID, var linked) in Array(storedRecords) where linked.scope == scope {
      let previousCount = linked.supersedes.count
      linked.supersedes.removeAll { $0 == id }
      if linked.supersededBy == id { linked.supersededBy = nil }
      if linked.supersedes.count != previousCount || storedRecords[linkedID]?.supersededBy == id {
        linked.updatedAt = Date()
        storedRecords[linkedID] = linked
      }
    }
    storedRecords.removeValue(forKey: id)
    storedTombstones.removeValue(forKey: id)
    storedCandidates = storedCandidates.filter {
      $0.value.scope != scope || $0.value.sourceRecordID != id
    }
    let removedJobIDs = storedJobs.values
      .filter { $0.scope == scope && $0.episodeID == id }
      .map(\.id)
    storedJobs = storedJobs.filter { $0.value.scope != scope || $0.value.episodeID != id }
    claimedJobIDs.subtract(removedJobIDs)
  }

  public func purge(scope: FoundationModelsAgentMemoryScope) {
    claimedJobIDs.subtract(storedJobs.values.filter { $0.scope == scope }.map(\.id))
    storedRecords = storedRecords.filter { $0.value.scope != scope }
    storedCandidates = storedCandidates.filter { $0.value.scope != scope }
    storedJobs = storedJobs.filter { $0.value.scope != scope }
    storedTombstones = storedTombstones.filter { $0.value.scope != scope }
    storedExportDirectories.removeValue(forKey: scope)
  }

  public func save(_ candidate: FoundationModelsAgentMemoryCandidate) throws {
    try ensureScope(storedCandidates[candidate.id]?.scope, equals: candidate.scope)
    guard let source = storedRecords[candidate.sourceRecordID], source.scope == candidate.scope
    else {
      throw FoundationModelsAgentMemoryError.scopeMismatch
    }
    guard source.isActive || candidate.status == .rejected else {
      throw FoundationModelsAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
    }
    storedCandidates[candidate.id] = candidate
  }

  public func candidate(id: UUID, in scope: FoundationModelsAgentMemoryScope)
    -> FoundationModelsAgentMemoryCandidate?
  {
    storedCandidates[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func candidates(
    in scope: FoundationModelsAgentMemoryScope,
    status: FoundationModelsAgentMemoryCandidateStatus?
  ) -> [FoundationModelsAgentMemoryCandidate] {
    storedCandidates.values
      .filter { $0.scope == scope && (status == nil || $0.status == status) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public func approveCandidate(
    id: UUID,
    as record: FoundationModelsAgentMemoryRecord,
    in scope: FoundationModelsAgentMemoryScope
  ) throws {
    guard record.scope == scope else { throw FoundationModelsAgentMemoryError.scopeMismatch }
    try ensureScope(storedRecords[record.id]?.scope, equals: record.scope)
    try ensureLinkedRecordScopes(record)
    guard var candidate = storedCandidates[id], candidate.scope == scope else {
      throw FoundationModelsAgentMemoryError.candidateNotFound(id)
    }
    guard candidate.status == .pending else {
      throw FoundationModelsAgentMemoryError.invalidCandidateDecision
    }
    guard let source = storedRecords[candidate.sourceRecordID], source.isActive else {
      throw FoundationModelsAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
    }
    candidate.status = .approved
    candidate.decidedAt = Date()
    storedCandidates[id] = candidate
    storedRecords[record.id] = record
  }

  public func rejectCandidate(
    id: UUID,
    in scope: FoundationModelsAgentMemoryScope,
    reason: String?
  ) throws {
    guard var candidate = storedCandidates[id], candidate.scope == scope else {
      throw FoundationModelsAgentMemoryError.candidateNotFound(id)
    }
    guard candidate.status == .pending else {
      throw FoundationModelsAgentMemoryError.invalidCandidateDecision
    }
    candidate.status = .rejected
    candidate.decidedAt = Date()
    candidate.decisionReason = reason
    storedCandidates[id] = candidate
  }

  public func save(_ job: FoundationModelsAgentMemoryConsolidationJob) throws {
    try ensureScope(storedJobs[job.id]?.scope, equals: job.scope)
    guard let source = storedRecords[job.episodeID], source.scope == job.scope else {
      throw FoundationModelsAgentMemoryError.scopeMismatch
    }
    guard source.isActive || job.status == .cancelled else {
      throw FoundationModelsAgentMemoryError.sourceRecordInactive(job.episodeID)
    }
    storedJobs[job.id] = job
    if job.status != .processing {
      claimedJobIDs.remove(job.id)
    }
  }

  public func consolidationJob(
    id: UUID,
    in scope: FoundationModelsAgentMemoryScope
  ) -> FoundationModelsAgentMemoryConsolidationJob? {
    storedJobs[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func consolidationJobs(
    in scope: FoundationModelsAgentMemoryScope,
    statuses: Set<FoundationModelsAgentMemoryConsolidationJobStatus>
  ) -> [FoundationModelsAgentMemoryConsolidationJob] {
    storedJobs.values
      .filter { $0.scope == scope && statuses.contains($0.status) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public func claimNextConsolidationJob(
    in scope: FoundationModelsAgentMemoryScope
  ) -> FoundationModelsAgentMemoryConsolidationJob? {
    let jobs = storedJobs.values
      .filter {
        $0.scope == scope
          && ($0.status == .queued || $0.status == .processing)
          && !claimedJobIDs.contains($0.id)
      }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }

    for var job in jobs {
      guard storedRecords[job.episodeID]?.isActive == true else {
        job.status = .cancelled
        job.lastError = "The source episode is not active."
        job.updatedAt = Date()
        storedJobs[job.id] = job
        continue
      }
      job.status = .processing
      job.attemptCount += 1
      job.updatedAt = Date()
      storedJobs[job.id] = job
      claimedJobIDs.insert(job.id)
      return job
    }
    return nil
  }

  public func releaseConsolidationJobClaim(id: UUID, in scope: FoundationModelsAgentMemoryScope) {
    guard storedJobs[id]?.scope == scope else { return }
    claimedJobIDs.remove(id)
  }

  public func registerExportDirectory(_ path: String, in scope: FoundationModelsAgentMemoryScope) {
    storedExportDirectories[scope, default: []].insert(path)
  }

  public func exportDirectories(in scope: FoundationModelsAgentMemoryScope) -> [String] {
    storedExportDirectories[scope, default: []].sorted()
  }

  private static func terms(in query: String) -> [String] {
    query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  private static func recordsBefore(
    _ lhs: FoundationModelsAgentMemoryRecord,
    _ rhs: FoundationModelsAgentMemoryRecord
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func ensureScope(
    _ existing: FoundationModelsAgentMemoryScope?,
    equals proposed: FoundationModelsAgentMemoryScope
  ) throws {
    guard existing == nil || existing == proposed else {
      throw FoundationModelsAgentMemoryError.scopeMismatch
    }
  }

  private func ensureLinkedRecordScopes(_ record: FoundationModelsAgentMemoryRecord) throws {
    for id in record.supersedes {
      guard storedRecords[id]?.scope == record.scope else {
        throw FoundationModelsAgentMemoryError.scopeMismatch
      }
    }
    if let id = record.supersededBy,
      storedRecords[id]?.scope != record.scope
    {
      throw FoundationModelsAgentMemoryError.scopeMismatch
    }
  }
}
