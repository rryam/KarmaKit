import Foundation

public enum CoreAgentDeepFilesystemOperation: String, Codable, Equatable, Sendable {
  case read
  case write
  case list
  case edit
  case glob
  case grep
  case delete
}

public enum CoreAgentDeepFilesystemPermissionMode: String, Codable, Equatable, Sendable {
  case allow
  case deny
}

public struct CoreAgentDeepFilesystemPermissionRule: Codable, Equatable, Sendable {
  public let operations: Set<CoreAgentDeepFilesystemOperation>
  public let paths: [String]
  public let mode: CoreAgentDeepFilesystemPermissionMode

  public init(
    operations: Set<CoreAgentDeepFilesystemOperation>,
    paths: [String],
    mode: CoreAgentDeepFilesystemPermissionMode
  ) {
    self.operations = operations
    self.paths = paths
    self.mode = mode
  }

  public static func allow(
    operations: Set<CoreAgentDeepFilesystemOperation>,
    paths: [String]
  ) -> Self {
    CoreAgentDeepFilesystemPermissionRule(operations: operations, paths: paths, mode: .allow)
  }

  public static func deny(
    operations: Set<CoreAgentDeepFilesystemOperation>,
    paths: [String]
  ) -> Self {
    CoreAgentDeepFilesystemPermissionRule(operations: operations, paths: paths, mode: .deny)
  }
}

public enum CoreAgentDeepFilesystemError: Error, Equatable, Sendable {
  case denied(operation: CoreAgentDeepFilesystemOperation, path: String)
  case escapedRoot(path: String)
  case notFound(path: String)
  case notDirectory(path: String)
  case invalidTextEncoding(path: String)
  case editReplacementUnchanged(path: String)
  case editTargetNotFound(path: String)
  case editTargetNotUnique(path: String, occurrences: Int)
  case invalidGrepOutputMode(String)
}

public enum CoreAgentDeepFilesystemAuditDecision: String, Codable, Equatable, Sendable {
  case allowed
  case denied
}

public struct CoreAgentDeepFilesystemAuditEvent: Codable, Equatable, Sendable {
  public let operation: CoreAgentDeepFilesystemOperation
  public let path: String
  public let decision: CoreAgentDeepFilesystemAuditDecision
  public let ruleIndex: Int?

  public init(
    operation: CoreAgentDeepFilesystemOperation,
    path: String,
    decision: CoreAgentDeepFilesystemAuditDecision,
    ruleIndex: Int? = nil
  ) {
    self.operation = operation
    self.path = path
    self.decision = decision
    self.ruleIndex = ruleIndex
  }
}

public struct CoreAgentDeepFileInfo: Codable, Equatable, Sendable {
  public let path: String
  public let isDirectory: Bool
  public let byteCount: Int?
  public let modifiedAt: Date?

  public init(path: String, isDirectory: Bool, byteCount: Int?, modifiedAt: Date?) {
    self.path = path
    self.isDirectory = isDirectory
    self.byteCount = byteCount
    self.modifiedAt = modifiedAt
  }
}

public struct CoreAgentDeepEditResult: Codable, Equatable, Sendable {
  public let path: String
  public let occurrences: Int

  public init(path: String, occurrences: Int) {
    self.path = path
    self.occurrences = occurrences
  }
}

public enum CoreAgentDeepGrepOutputMode: String, Codable, Equatable, Sendable {
  case filesWithMatches = "files_with_matches"
  case content
  case count
}

public struct CoreAgentDeepGrepMatch: Codable, Equatable, Sendable {
  public let path: String
  public let lineNumber: Int
  public let line: String

  public init(path: String, lineNumber: Int, line: String) {
    self.path = path
    self.lineNumber = lineNumber
    self.line = line
  }
}

public protocol CoreAgentDeepFilesystemBackend: Sendable {
  func writeFile(_ contents: String, at path: String) async throws
  func fileExists(at path: String) async throws -> Bool
  func readFile(at path: String) async throws -> String
  func listDirectory(at path: String) async throws -> [CoreAgentDeepFileInfo]
  func editFile(
    at path: String,
    replacing oldString: String,
    with newString: String,
    replaceAll: Bool
  ) async throws -> CoreAgentDeepEditResult
  func glob(pattern: String, path: String?) async throws -> [String]
  func grep(pattern: String, path: String?, glob: String?) async throws -> [CoreAgentDeepGrepMatch]
  func deleteFile(at path: String) async throws
  func auditEvents() async -> [CoreAgentDeepFilesystemAuditEvent]
}
