import Foundation
import SQLite3

public enum CoreAgentMemoryFileProtection: Sendable {
  case complete
  case completeUnlessOpen
  case completeUntilFirstUserAuthentication
  case none
}

public struct SQLiteCoreAgentMemoryStoreConfiguration: Sendable {
  public var fileProtection: CoreAgentMemoryFileProtection
  public var excludesFromBackup: Bool

  public init(
    fileProtection: CoreAgentMemoryFileProtection = .completeUntilFirstUserAuthentication,
    excludesFromBackup: Bool = true
  ) {
    self.fileProtection = fileProtection
    self.excludesFromBackup = excludesFromBackup
  }

  public static let `default` = SQLiteCoreAgentMemoryStoreConfiguration()
}

public actor SQLiteCoreAgentMemoryStore: CoreAgentMemoryStore {
  public static let schemaVersion: Int32 = 1

  public let databaseURL: URL

  let connection: SQLiteCoreAgentMemoryConnection
  let encoder: JSONEncoder
  let decoder: JSONDecoder
  let configuration: SQLiteCoreAgentMemoryStoreConfiguration
  var claimedJobIDs: Set<UUID> = []

  public init(
    databaseURL: URL,
    configuration: SQLiteCoreAgentMemoryStoreConfiguration = .default
  ) throws {
    self.databaseURL = databaseURL.standardizedFileURL
    self.configuration = configuration

    try FileManager.default.createDirectory(
      at: self.databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    self.connection = try SQLiteCoreAgentMemoryConnection(url: self.databaseURL)
    self.encoder = JSONEncoder.coreAgentMemory
    self.decoder = JSONDecoder.coreAgentMemory

    try Self.configure(connection)
    try Self.applyFilePolicies(
      databaseURL: self.databaseURL,
      configuration: configuration
    )
  }

  public func save(_ record: CoreAgentMemoryRecord) throws {
    try transaction { try saveRecord(record) }
    try refreshFilePolicies()
  }

  public func saveEpisode(
    _ episode: CoreAgentMemoryRecord,
    enqueueing job: CoreAgentMemoryConsolidationJob?
  ) throws {
    try transaction {
      try saveRecord(episode)
      if let job { try saveJob(job) }
    }
    try refreshFilePolicies()
  }

  public func applyCorrection(
    _ correction: CoreAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) throws {
    try transaction {
      var existingRecords: [CoreAgentMemoryRecord] = []
      for id in recordIDs {
        guard let existing = try fetchRecord(id: id, scope: correction.scope) else {
          throw CoreAgentMemoryError.recordNotFound(id)
        }
        existingRecords.append(existing)
      }
      try saveRecord(correction)
      for var existing in existingRecords {
        existing.status = .superseded
        existing.supersededBy = correction.id
        existing.updatedAt = Date()
        try saveRecord(existing)
      }
    }
    try refreshFilePolicies()
  }

  public func record(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryRecord? {
    try fetchRecord(id: id, scope: scope)
  }

  public func records(
    ids: [UUID],
    in scope: CoreAgentMemoryScope
  ) throws -> [CoreAgentMemoryRecord] {
    try ids.compactMap { try fetchRecord(id: $0, scope: scope) }
  }

  public func records(in scope: CoreAgentMemoryScope) throws -> [CoreAgentMemoryRecord] {
    let statement = try prepare(
      """
      SELECT payload FROM memory_records
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    return try decodeRows(statement, as: CoreAgentMemoryRecord.self)
  }

  public func lexicalSearch(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) throws -> [CoreAgentMemorySearchCandidate] {
    guard limit > 0 else { return [] }
    let matchQuery = Self.ftsQuery(query)
    if matchQuery.isEmpty {
      let statement = try prepare(
        """
        SELECT id FROM memory_records
        WHERE application_id = ? AND user_id = ? AND agent_id = ?
        ORDER BY observed_at DESC, id ASC
        LIMIT ?
        """
      )
      try bind(scope, to: statement)
      try statement.bind(Int64(limit), at: 4)
      var results: [CoreAgentMemorySearchCandidate] = []
      while try statement.step() {
        guard let id = UUID(uuidString: statement.text(at: 0)) else { continue }
        results.append(CoreAgentMemorySearchCandidate(id: id, score: 0))
      }
      return results
    }

    let statement = try prepare(
      """
      SELECT memory_fts.record_id, -bm25(memory_fts) AS relevance
      FROM memory_fts
      JOIN memory_records ON memory_records.id = memory_fts.record_id
      WHERE memory_fts MATCH ?
        AND memory_records.application_id = ?
        AND memory_records.user_id = ?
        AND memory_records.agent_id = ?
      ORDER BY relevance DESC, memory_fts.record_id ASC
      LIMIT ?
      """
    )
    try statement.bind(matchQuery, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    try statement.bind(Int64(limit), at: 5)

    var results: [CoreAgentMemorySearchCandidate] = []
    while try statement.step() {
      guard let id = UUID(uuidString: statement.text(at: 0)) else { continue }
      results.append(
        CoreAgentMemorySearchCandidate(id: id, score: statement.double(at: 1))
      )
    }
    return results
  }

  public func updateIndexState(
    _ state: CoreAgentMemoryIndexState,
    for id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard var record = try fetchRecord(id: id, scope: scope) else {
      throw CoreAgentMemoryError.recordNotFound(id)
    }
    record.indexState = state
    record.updatedAt = Date()
    try save(record)
  }

  public func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws -> CoreAgentMemoryTombstone {
    let tombstone = CoreAgentMemoryTombstone(recordID: id, scope: scope, reason: reason)
    var cancelledJobIDs: Set<UUID> = []
    try transaction {
      guard var record = try fetchRecord(id: id, scope: scope) else {
        throw CoreAgentMemoryError.recordNotFound(id)
      }
      record.status = .tombstoned
      record.updatedAt = tombstone.deletedAt
      try saveRecord(record)
      try saveTombstone(tombstone)
      for var candidate in try candidates(in: scope, status: .pending)
      where candidate.sourceRecordID == id {
        candidate.status = .rejected
        candidate.decidedAt = tombstone.deletedAt
        candidate.decisionReason = "source_tombstoned"
        try saveCandidate(candidate)
      }
      for var job in try consolidationJobs(
        in: scope,
        statuses: [.queued, .processing, .failed]
      ) where job.episodeID == id {
        job.status = .cancelled
        job.lastError = "The source episode was tombstoned."
        job.updatedAt = tombstone.deletedAt
        try saveJob(job)
        cancelledJobIDs.insert(job.id)
      }
    }
    claimedJobIDs.subtract(cancelledJobIDs)
    try refreshFilePolicies()
    return tombstone
  }

  public func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryTombstone? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_tombstones
      WHERE record_id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryTombstone.self, from: statement.data(at: 0))
  }

  public func purge(id: UUID, in scope: CoreAgentMemoryScope) throws {
    let removedJobIDs = try consolidationJobs(
      in: scope,
      statuses: Set(CoreAgentMemoryConsolidationJobStatus.allCases)
    ).filter { $0.episodeID == id }.map(\.id)
    try transaction {
      guard try fetchRecord(id: id, scope: scope) != nil else { return }
      for var linked in try records(in: scope) where linked.id != id {
        let previousSupersedes = linked.supersedes
        let previousSupersededBy = linked.supersededBy
        linked.supersedes.removeAll { $0 == id }
        if linked.supersededBy == id { linked.supersededBy = nil }
        if linked.supersedes != previousSupersedes
          || linked.supersededBy != previousSupersededBy
        {
          linked.updatedAt = Date()
          try saveRecord(linked)
        }
      }
      let fts = try prepare(
        """
        DELETE FROM memory_fts WHERE record_id IN (
          SELECT id FROM memory_records
          WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
        )
        """
      )
      try fts.bind(id, at: 1)
      try bind(scope, to: fts, startingAt: 2)
      try fts.run()

      let statement = try prepare(
        """
        DELETE FROM memory_records
        WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
        """
      )
      try statement.bind(id, at: 1)
      try bind(scope, to: statement, startingAt: 2)
      try statement.run()
    }
    claimedJobIDs.subtract(removedJobIDs)
    try refreshFilePolicies()
  }

  public func purge(scope: CoreAgentMemoryScope) throws {
    let removedJobIDs = try consolidationJobs(
      in: scope,
      statuses: Set(CoreAgentMemoryConsolidationJobStatus.allCases)
    ).map(\.id)
    try transaction {
      let fts = try prepare(
        """
        DELETE FROM memory_fts WHERE record_id IN (
          SELECT id FROM memory_records
          WHERE application_id = ? AND user_id = ? AND agent_id = ?
        )
        """
      )
      try bind(scope, to: fts)
      try fts.run()

      for table in [
        "memory_candidates", "memory_jobs", "memory_tombstones", "memory_exports",
        "memory_records",
      ] {
        let statement = try prepare(
          "DELETE FROM \(table) WHERE application_id = ? AND user_id = ? AND agent_id = ?"
        )
        try bind(scope, to: statement)
        try statement.run()
      }
    }
    claimedJobIDs.subtract(removedJobIDs)
    try refreshFilePolicies()
  }

  public func save(_ candidate: CoreAgentMemoryCandidate) throws {
    try transaction { try saveCandidate(candidate) }
    try refreshFilePolicies()
  }

  public func candidate(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryCandidate? {
    try fetchCandidate(id: id, scope: scope)
  }

  public func candidates(
    in scope: CoreAgentMemoryScope,
    status: CoreAgentMemoryCandidateStatus?
  ) throws -> [CoreAgentMemoryCandidate] {
    let statusClause = status == nil ? "" : " AND status = ?"
    let statement = try prepare(
      """
      SELECT payload FROM memory_candidates
      WHERE application_id = ? AND user_id = ? AND agent_id = ?\(statusClause)
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    if let status { try statement.bind(status.rawValue, at: 4) }
    return try decodeRows(statement, as: CoreAgentMemoryCandidate.self)
  }

  public func approveCandidate(
    id: UUID,
    as record: CoreAgentMemoryRecord,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard record.scope == scope else { throw CoreAgentMemoryError.scopeMismatch }
    try transaction {
      guard var candidate = try fetchCandidate(id: id, scope: scope) else {
        throw CoreAgentMemoryError.candidateNotFound(id)
      }
      guard candidate.status == .pending else {
        throw CoreAgentMemoryError.invalidCandidateDecision
      }
      guard let source = try fetchRecord(id: candidate.sourceRecordID, scope: scope),
        source.isActive
      else {
        throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
      }
      candidate.status = .approved
      candidate.decidedAt = Date()
      try saveCandidate(candidate)
      try saveRecord(record)
    }
    try refreshFilePolicies()
  }

  public func rejectCandidate(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws {
    try transaction {
      guard var candidate = try fetchCandidate(id: id, scope: scope) else {
        throw CoreAgentMemoryError.candidateNotFound(id)
      }
      guard candidate.status == .pending else {
        throw CoreAgentMemoryError.invalidCandidateDecision
      }
      candidate.status = .rejected
      candidate.decidedAt = Date()
      candidate.decisionReason = reason
      try saveCandidate(candidate)
    }
    try refreshFilePolicies()
  }

  public func save(_ job: CoreAgentMemoryConsolidationJob) throws {
    try transaction { try saveJob(job) }
    if job.status != .processing {
      claimedJobIDs.remove(job.id)
    }
    try refreshFilePolicies()
  }

  public func consolidationJob(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryConsolidationJob? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_jobs
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(
      CoreAgentMemoryConsolidationJob.self,
      from: statement.data(at: 0)
    )
  }

  public func consolidationJobs(
    in scope: CoreAgentMemoryScope,
    statuses: Set<CoreAgentMemoryConsolidationJobStatus>
  ) throws -> [CoreAgentMemoryConsolidationJob] {
    guard !statuses.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
    let statement = try prepare(
      """
      SELECT payload FROM memory_jobs
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
        AND status IN (\(placeholders))
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    for (offset, status) in statuses.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
      try statement.bind(status.rawValue, at: Int32(offset + 4))
    }
    return try decodeRows(statement, as: CoreAgentMemoryConsolidationJob.self)
  }

  public func claimNextConsolidationJob(
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryConsolidationJob? {
    var claimed: CoreAgentMemoryConsolidationJob?
    try transaction {
      let jobs = try consolidationJobs(in: scope, statuses: [.queued, .processing])
      for var job in jobs where !claimedJobIDs.contains(job.id) {
        guard let source = try fetchRecord(id: job.episodeID, scope: scope), source.isActive
        else {
          job.status = .cancelled
          job.lastError = "The source episode is not active."
          job.updatedAt = Date()
          try saveJob(job)
          continue
        }
        job.status = .processing
        job.attemptCount += 1
        job.updatedAt = Date()
        try saveJob(job)
        claimed = job
        break
      }
    }
    if let claimed {
      claimedJobIDs.insert(claimed.id)
    }
    try refreshFilePolicies()
    return claimed
  }

  public func releaseConsolidationJobClaim(id: UUID, in scope: CoreAgentMemoryScope) {
    guard (try? consolidationJob(id: id, in: scope)) != nil else { return }
    claimedJobIDs.remove(id)
  }

  public func registerExportDirectory(
    _ path: String,
    in scope: CoreAgentMemoryScope
  ) throws {
    let statement = try prepare(
      """
      INSERT OR REPLACE INTO memory_exports (
        application_id, user_id, agent_id, path, registered_at
      ) VALUES (?, ?, ?, ?, ?)
      """
    )
    try bind(scope, to: statement)
    try statement.bind(path, at: 4)
    try statement.bind(Date(), at: 5)
    try statement.run()
  }

  public func exportDirectories(in scope: CoreAgentMemoryScope) throws -> [String] {
    let statement = try prepare(
      """
      SELECT path FROM memory_exports
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
      ORDER BY path ASC
      """
    )
    try bind(scope, to: statement)
    var paths: [String] = []
    while try statement.step() {
      paths.append(statement.text(at: 0))
    }
    return paths
  }

}
