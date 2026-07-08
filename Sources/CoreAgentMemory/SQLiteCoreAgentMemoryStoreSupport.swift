import Foundation
import SQLite3

extension CoreAgentMemoryFileProtection {
  // Module-internal (not fileprivate): the only caller lives in
  // SQLiteCoreAgentMemoryStoreSQL.swift, inside an `#if os(iOS)||os(tvOS)||os(watchOS)
  // ||os(visionOS)` block. Under `fileprivate` that cross-file access compiles on macOS
  // only because the call site is excluded there, but fails the iOS/visionOS xcodebuild
  // with "'foundationValue' is inaccessible due to 'fileprivate' protection level".
  var foundationValue: FileProtectionType? {
    switch self {
    case .complete: .complete
    case .completeUnlessOpen: .completeUnlessOpen
    case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
    case .none: nil
    }
  }
}

final class SQLiteCoreAgentMemoryConnection: @unchecked Sendable {
  private var database: OpaquePointer?

  init(url: URL) throws {
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close_v2(database)
      throw CoreAgentMemoryError.sqlite(message)
    }
    sqlite3_busy_timeout(database, 5_000)
  }

  deinit {
    sqlite3_close_v2(database)
  }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? lastError
      sqlite3_free(errorMessage)
      throw CoreAgentMemoryError.sqlite(message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteCoreAgentMemoryStatement {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw CoreAgentMemoryError.sqlite(lastError)
    }
    return SQLiteCoreAgentMemoryStatement(statement: statement, connection: self)
  }

  func int32(for sql: String) throws -> Int32 {
    let statement = try prepare(sql)
    guard try statement.step() else { return 0 }
    return statement.int32(at: 0)
  }

  var lastError: String {
    database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
  }
}

final class SQLiteCoreAgentMemoryStatement {
  private let statement: OpaquePointer
  private let connection: SQLiteCoreAgentMemoryConnection

  init(statement: OpaquePointer, connection: SQLiteCoreAgentMemoryConnection) {
    self.statement = statement
    self.connection = connection
  }

  deinit {
    sqlite3_finalize(statement)
  }

  func bind(_ value: String?, at index: Int32) throws {
    let result: Int32
    if let value {
      result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    } else {
      result = sqlite3_bind_null(statement, index)
    }
    try check(result)
  }

  func bind(_ value: UUID, at index: Int32) throws {
    try bind(value.uuidString.lowercased(), at: index)
  }

  func bind(_ value: Int64, at index: Int32) throws {
    try check(sqlite3_bind_int64(statement, index, value))
  }

  func bind(_ value: Double, at index: Int32) throws {
    try check(sqlite3_bind_double(statement, index, value))
  }

  func bind(_ value: Date?, at index: Int32) throws {
    if let value {
      try bind(value.timeIntervalSince1970, at: index)
    } else {
      try check(sqlite3_bind_null(statement, index))
    }
  }

  func bind(_ value: Data, at index: Int32) throws {
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
    }
    try check(result)
  }

  func step() throws -> Bool {
    switch sqlite3_step(statement) {
    case SQLITE_ROW: true
    case SQLITE_DONE: false
    default: throw CoreAgentMemoryError.sqlite(connection.lastError)
    }
  }

  func run() throws {
    guard try !step() else {
      throw CoreAgentMemoryError.sqlite("A write statement unexpectedly returned a row.")
    }
  }

  func text(at index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
  }

  func double(at index: Int32) -> Double {
    sqlite3_column_double(statement, index)
  }

  func int32(at index: Int32) -> Int32 {
    sqlite3_column_int(statement, index)
  }

  func data(at index: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else {
      throw CoreAgentMemoryError.sqlite(connection.lastError)
    }
  }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension JSONEncoder {
  static var coreAgentMemory: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var coreAgentMemory: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return decoder
  }
}
