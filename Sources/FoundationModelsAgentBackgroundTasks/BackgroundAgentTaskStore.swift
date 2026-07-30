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

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormatVersion(let version):
      "Task store format version \(version) is unsupported."
    case .corruptedStore(let detail):
      "The task store is corrupted: \(detail)"
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

/// A single-process file store for app-owned durable tasks.
///
/// Each save encodes the complete versioned snapshot and atomically replaces the file.
/// Coordinate access through one `BackgroundAgentTaskCoordinator`; this is not a distributed queue.
public actor FileBackgroundAgentTaskStore: BackgroundAgentTaskStore {
  private let fileURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
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
