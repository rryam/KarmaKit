import Foundation
import SQLite3

extension SQLiteCoreAgentMemoryStore {
  func decodeRows<Value: Decodable>(
    _ statement: SQLiteCoreAgentMemoryStatement,
    as type: Value.Type
  ) throws -> [Value] {
    var values: [Value] = []
    while try statement.step() {
      values.append(try decoder.decode(type, from: statement.data(at: 0)))
    }
    return values
  }

  func bind(
    _ scope: CoreAgentMemoryScope,
    to statement: SQLiteCoreAgentMemoryStatement,
    startingAt index: Int32 = 1
  ) throws {
    try statement.bind(scope.applicationID, at: index)
    try statement.bind(scope.userID, at: index + 1)
    try statement.bind(scope.agentID, at: index + 2)
  }

  func prepare(_ sql: String) throws -> SQLiteCoreAgentMemoryStatement {
    try connection.prepare(sql)
  }

  func ensureScope(
    for id: UUID,
    table: String,
    equals scope: CoreAgentMemoryScope
  ) throws {
    let statement = try prepare(
      "SELECT application_id, user_id, agent_id FROM \(table) WHERE id = ?"
    )
    try statement.bind(id, at: 1)
    guard try statement.step() else { return }
    guard statement.text(at: 0) == scope.applicationID,
      statement.text(at: 1) == scope.userID,
      statement.text(at: 2) == scope.agentID
    else {
      throw CoreAgentMemoryError.scopeMismatch
    }
  }

  func transaction<Value>(_ operation: () throws -> Value) throws -> Value {
    try connection.execute("BEGIN IMMEDIATE")
    do {
      let value = try operation()
      try connection.execute("COMMIT")
      return value
    } catch {
      try? connection.execute("ROLLBACK")
      throw error
    }
  }

  func refreshFilePolicies() throws {
    try Self.applyFilePolicies(databaseURL: databaseURL, configuration: configuration)
  }

  static func configure(_ connection: SQLiteCoreAgentMemoryConnection) throws {
    try connection.execute("PRAGMA foreign_keys = ON")
    try connection.execute("PRAGMA journal_mode = WAL")
    try connection.execute("PRAGMA synchronous = NORMAL")
    let version = try connection.int32(for: "PRAGMA user_version")
    guard version <= schemaVersion else {
      throw CoreAgentMemoryError.unsupportedSchemaVersion(version)
    }
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_records (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        sensitivity TEXT NOT NULL,
        authority TEXT NOT NULL,
        observed_at REAL NOT NULL,
        valid_from REAL,
        valid_until REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        index_state TEXT NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_records_scope ON memory_records(application_id, user_id, agent_id)"
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_records_status ON memory_records(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(record_id UNINDEXED, content, tokenize = 'unicode61')"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_provenance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        source_kind TEXT NOT NULL,
        run_id TEXT,
        transcript_entry_id TEXT,
        tool_name TEXT,
        asset_reference TEXT,
        metadata BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_supersessions (
        older_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        newer_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        PRIMARY KEY (older_record_id, newer_record_id)
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_candidates (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        source_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_candidates_scope ON memory_candidates(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_jobs (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        episode_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_jobs_scope ON memory_jobs(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_tombstones (
        record_id TEXT PRIMARY KEY NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        deleted_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_exports (
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        path TEXT NOT NULL,
        registered_at REAL NOT NULL,
        PRIMARY KEY (application_id, user_id, agent_id, path)
      )
      """
    )
    try connection.execute("PRAGMA user_version = \(schemaVersion)")
  }

  static func ftsQuery(_ query: String) -> String {
    query.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " OR ")
  }

  static func applyFilePolicies(
    databaseURL: URL,
    configuration: SQLiteCoreAgentMemoryStoreConfiguration
  ) throws {
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if let protection = configuration.fileProtection.foundationValue {
          try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
          )
        }
      #endif
      if configuration.excludesFromBackup {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
      }
    }
  }
}
