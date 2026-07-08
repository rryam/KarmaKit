import Foundation
import SQLite3

extension SQLiteCoreAgentMemoryStore {
  func fetchRecord(
    id: UUID,
    scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryRecord? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_records
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryRecord.self, from: statement.data(at: 0))
  }

  func fetchCandidate(
    id: UUID,
    scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryCandidate? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_candidates
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryCandidate.self, from: statement.data(at: 0))
  }

  func saveRecord(_ record: CoreAgentMemoryRecord) throws {
    try ensureScope(for: record.id, table: "memory_records", equals: record.scope)
    for linkedID in record.supersedes {
      guard try fetchRecord(id: linkedID, scope: record.scope) != nil else {
        throw CoreAgentMemoryError.scopeMismatch
      }
    }
    if let linkedID = record.supersededBy,
      try fetchRecord(id: linkedID, scope: record.scope) == nil
    {
      throw CoreAgentMemoryError.scopeMismatch
    }
    let statement = try prepare(
      """
      INSERT INTO memory_records (
        id, application_id, user_id, agent_id, kind, status, sensitivity, authority,
        observed_at, valid_from, valid_until, created_at, updated_at, content,
        content_hash, index_state, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        application_id = excluded.application_id,
        user_id = excluded.user_id,
        agent_id = excluded.agent_id,
        kind = excluded.kind,
        status = excluded.status,
        sensitivity = excluded.sensitivity,
        authority = excluded.authority,
        observed_at = excluded.observed_at,
        valid_from = excluded.valid_from,
        valid_until = excluded.valid_until,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        content = excluded.content,
        content_hash = excluded.content_hash,
        index_state = excluded.index_state,
        payload = excluded.payload
      """
    )
    try statement.bind(record.id, at: 1)
    try bind(record.scope, to: statement, startingAt: 2)
    try statement.bind(record.kind.rawValue, at: 5)
    try statement.bind(record.status.rawValue, at: 6)
    try statement.bind(record.sensitivity.rawValue, at: 7)
    try statement.bind(record.authority.rawValue, at: 8)
    try statement.bind(record.observedAt, at: 9)
    try statement.bind(record.validFrom, at: 10)
    try statement.bind(record.validUntil, at: 11)
    try statement.bind(record.createdAt, at: 12)
    try statement.bind(record.updatedAt, at: 13)
    try statement.bind(record.content, at: 14)
    try statement.bind(record.contentHash, at: 15)
    try statement.bind(record.indexState.rawValue, at: 16)
    try statement.bind(encoder.encode(record), at: 17)
    try statement.run()

    let deleteFTS = try prepare("DELETE FROM memory_fts WHERE record_id = ?")
    try deleteFTS.bind(record.id, at: 1)
    try deleteFTS.run()
    if record.status != .tombstoned {
      let insertFTS = try prepare("INSERT INTO memory_fts(record_id, content) VALUES (?, ?)")
      try insertFTS.bind(record.id, at: 1)
      try insertFTS.bind(record.content, at: 2)
      try insertFTS.run()
    }

    let deleteProvenance = try prepare("DELETE FROM memory_provenance WHERE record_id = ?")
    try deleteProvenance.bind(record.id, at: 1)
    try deleteProvenance.run()
    try saveProvenance(for: record)

    let deleteSupersessions = try prepare(
      "DELETE FROM memory_supersessions WHERE newer_record_id = ?"
    )
    try deleteSupersessions.bind(record.id, at: 1)
    try deleteSupersessions.run()
    for previousID in record.supersedes {
      let supersession = try prepare(
        """
        INSERT OR REPLACE INTO memory_supersessions (
          older_record_id, newer_record_id, created_at
        ) VALUES (?, ?, ?)
        """
      )
      try supersession.bind(previousID, at: 1)
      try supersession.bind(record.id, at: 2)
      try supersession.bind(record.updatedAt, at: 3)
      try supersession.run()
    }
  }

  func saveProvenance(for record: CoreAgentMemoryRecord) throws {
    let transcriptIDs =
      record.source.transcriptEntryIDs.isEmpty
      ? [String?](arrayLiteral: nil)
      : record.source.transcriptEntryIDs.map(Optional.some)
    let assetReferences =
      record.source.assetReferences.isEmpty
      ? [String?](arrayLiteral: nil)
      : record.source.assetReferences.map(Optional.some)
    let rows: [(String?, String?)]
    if transcriptIDs == [nil], assetReferences == [nil] {
      rows = [(nil, nil)]
    } else {
      rows =
        transcriptIDs.filter { $0 != nil }.map { ($0, nil) }
        + assetReferences.filter { $0 != nil }.map { (nil, $0) }
    }
    let metadata = try encoder.encode(record.source.metadata)
    for (transcriptID, assetReference) in rows {
      let statement = try prepare(
        """
        INSERT INTO memory_provenance (
          record_id, source_kind, run_id, transcript_entry_id, tool_name,
          asset_reference, metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
      )
      try statement.bind(record.id, at: 1)
      try statement.bind(record.source.kind.rawValue, at: 2)
      try statement.bind(record.source.runID?.uuidString.lowercased(), at: 3)
      try statement.bind(transcriptID, at: 4)
      try statement.bind(record.source.toolName, at: 5)
      try statement.bind(assetReference, at: 6)
      try statement.bind(metadata, at: 7)
      try statement.run()
    }
  }

  func saveCandidate(_ candidate: CoreAgentMemoryCandidate) throws {
    try ensureScope(for: candidate.id, table: "memory_candidates", equals: candidate.scope)
    guard let source = try fetchRecord(id: candidate.sourceRecordID, scope: candidate.scope) else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || candidate.status == .rejected else {
      throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
    }
    let statement = try prepare(
      """
      INSERT INTO memory_candidates (
        id, application_id, user_id, agent_id, source_record_id, status, created_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        payload = excluded.payload
      """
    )
    try statement.bind(candidate.id, at: 1)
    try bind(candidate.scope, to: statement, startingAt: 2)
    try statement.bind(candidate.sourceRecordID, at: 5)
    try statement.bind(candidate.status.rawValue, at: 6)
    try statement.bind(candidate.createdAt, at: 7)
    try statement.bind(encoder.encode(candidate), at: 8)
    try statement.run()
  }

  func saveJob(_ job: CoreAgentMemoryConsolidationJob) throws {
    try ensureScope(for: job.id, table: "memory_jobs", equals: job.scope)
    guard let source = try fetchRecord(id: job.episodeID, scope: job.scope) else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || job.status == .cancelled else {
      throw CoreAgentMemoryError.sourceRecordInactive(job.episodeID)
    }
    let statement = try prepare(
      """
      INSERT INTO memory_jobs (
        id, application_id, user_id, agent_id, episode_id, status,
        attempt_count, created_at, updated_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        attempt_count = excluded.attempt_count,
        updated_at = excluded.updated_at,
        payload = excluded.payload
      """
    )
    try statement.bind(job.id, at: 1)
    try bind(job.scope, to: statement, startingAt: 2)
    try statement.bind(job.episodeID, at: 5)
    try statement.bind(job.status.rawValue, at: 6)
    try statement.bind(Int64(job.attemptCount), at: 7)
    try statement.bind(job.createdAt, at: 8)
    try statement.bind(job.updatedAt, at: 9)
    try statement.bind(encoder.encode(job), at: 10)
    try statement.run()
  }

  func saveTombstone(_ tombstone: CoreAgentMemoryTombstone) throws {
    let statement = try prepare(
      """
      INSERT INTO memory_tombstones (
        record_id, application_id, user_id, agent_id, deleted_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(record_id) DO UPDATE SET
        deleted_at = excluded.deleted_at,
        payload = excluded.payload
      """
    )
    try statement.bind(tombstone.recordID, at: 1)
    try bind(tombstone.scope, to: statement, startingAt: 2)
    try statement.bind(tombstone.deletedAt, at: 5)
    try statement.bind(encoder.encode(tombstone), at: 6)
    try statement.run()
  }

}
