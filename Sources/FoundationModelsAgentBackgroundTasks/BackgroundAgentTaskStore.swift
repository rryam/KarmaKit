import Darwin
import Foundation

public struct BackgroundAgentTaskStoreSnapshot: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let savedAt: Date
  public let nextSequence: UInt64
  public let records: [BackgroundAgentTaskRecord]

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    savedAt: Date = Date(),
    nextSequence: UInt64,
    records: [BackgroundAgentTaskRecord]
  ) {
    self.formatVersion = formatVersion
    self.savedAt = savedAt
    self.nextSequence = nextSequence
    self.records = records
  }
}

public protocol BackgroundAgentTaskStore: Sendable {
  func loadSnapshot() async throws -> BackgroundAgentTaskStoreSnapshot?
  func saveSnapshot(_ snapshot: BackgroundAgentTaskStoreSnapshot) async throws
}

public enum BackgroundAgentTaskStoreError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedFormatVersion(Int)
  case corruptedStore(String)
  case storeAlreadyInUse(String)
  case fileLockFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormatVersion(let version):
      "Task store format version \(version) is unsupported."
    case .corruptedStore(let detail):
      "The task store is corrupted: \(detail)"
    case .storeAlreadyInUse(let path):
      "Another coordinator already owns the task store at \(path)."
    case .fileLockFailed(let detail):
      "The task store lock could not be created: \(detail)"
    }
  }
}

public actor InMemoryBackgroundAgentTaskStore: BackgroundAgentTaskStore {
  private var snapshot: BackgroundAgentTaskStoreSnapshot?
  private var savedSnapshots: [BackgroundAgentTaskStoreSnapshot]

  public init(snapshot: BackgroundAgentTaskStoreSnapshot? = nil) {
    self.snapshot = snapshot
    self.savedSnapshots = snapshot.map { [$0] } ?? []
  }

  public func loadSnapshot() -> BackgroundAgentTaskStoreSnapshot? {
    snapshot
  }

  public func saveSnapshot(_ snapshot: BackgroundAgentTaskStoreSnapshot) {
    self.snapshot = snapshot
    savedSnapshots.append(snapshot)
  }

  public func snapshots() -> [BackgroundAgentTaskStoreSnapshot] {
    savedSnapshots
  }
}

/// An exclusively owned file store for app-managed durable tasks.
///
/// Each save encodes the complete versioned snapshot and atomically replaces the file.
/// The initializer takes an advisory lock so another process or store instance fails cleanly.
/// The JSON remains plaintext; encryption and file protection belong to the application.
public actor FileBackgroundAgentTaskStore: BackgroundAgentTaskStore {
  private let fileURL: URL
  private let lockFileDescriptor: Int32
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL, fileManager: FileManager = .default) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = fileURL.appendingPathExtension("lock")
    let descriptor = open(
      lockURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw BackgroundAgentTaskStoreError.fileLockFailed(
        String(cString: strerror(errno))
      )
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw BackgroundAgentTaskStoreError.storeAlreadyInUse(fileURL.path)
    }

    self.fileURL = fileURL
    self.lockFileDescriptor = descriptor
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  deinit {
    flock(lockFileDescriptor, LOCK_UN)
    close(lockFileDescriptor)
  }

  public func loadSnapshot() throws -> BackgroundAgentTaskStoreSnapshot? {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }

    do {
      let snapshot = try decoder.decode(
        BackgroundAgentTaskStoreSnapshot.self,
        from: Data(contentsOf: fileURL)
      )
      guard snapshot.formatVersion == BackgroundAgentTaskStoreSnapshot.currentFormatVersion else {
        throw BackgroundAgentTaskStoreError.unsupportedFormatVersion(snapshot.formatVersion)
      }
      return snapshot
    } catch let error as BackgroundAgentTaskStoreError {
      throw error
    } catch {
      throw BackgroundAgentTaskStoreError.corruptedStore(String(describing: error))
    }
  }

  public func saveSnapshot(_ snapshot: BackgroundAgentTaskStoreSnapshot) throws {
    guard snapshot.formatVersion == BackgroundAgentTaskStoreSnapshot.currentFormatVersion else {
      throw BackgroundAgentTaskStoreError.unsupportedFormatVersion(snapshot.formatVersion)
    }
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: .atomic)
  }
}
