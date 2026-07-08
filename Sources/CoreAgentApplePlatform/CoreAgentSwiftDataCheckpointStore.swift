import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public enum CoreAgentSwiftDataCheckpointAccessError: Error, Equatable, Sendable {
  case authorityBoundaryMismatch(expected: String, actual: String)
  case policyVersionMismatch(expected: Int, actual: Int)
  case digestMismatch(expected: String, actual: String)
  case formatVersionMismatch(expected: Int, actual: Int)
  case compatibilityRevisionMismatch(expected: String, actual: String)
  case savedAtMismatch(expected: Date, actual: Date)
}

public struct CoreAgentSwiftDataCheckpointSnapshot: Equatable, Sendable {
  public let checkpointID: UUID
  public let checkpointKey: String
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let checkpointFormatVersion: Int
  public let compatibilityRevision: String
  public let savedAt: Date
  public let storedAt: Date
  public let canonicalCheckpointData: Data
  public let checkpointDigest: String

  public init(
    checkpointID: UUID = UUID(),
    checkpointKey: String,
    checkpoint: CoreAgentCheckpoint,
    authorityBoundaryID: String,
    policyVersion: Int,
    storedAt: Date = Date()
  ) throws {
    let data = try Self.encoder().encode(checkpoint)
    self.init(
      checkpointID: checkpointID,
      checkpointKey: checkpointKey,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      checkpointFormatVersion: checkpoint.formatVersion,
      compatibilityRevision: checkpoint.compatibilityRevision,
      savedAt: checkpoint.savedAt,
      storedAt: storedAt,
      canonicalCheckpointData: data,
      checkpointDigest: Self.digest(
        checkpointID: checkpointID,
        checkpointKey: checkpointKey,
        authorityBoundaryID: authorityBoundaryID,
        policyVersion: policyVersion,
        checkpointFormatVersion: checkpoint.formatVersion,
        compatibilityRevision: checkpoint.compatibilityRevision,
        savedAt: checkpoint.savedAt,
        canonicalCheckpointData: data
      )
    )
  }

  public init(
    checkpointID: UUID = UUID(),
    checkpointKey: String,
    authorityBoundaryID: String,
    policyVersion: Int,
    checkpointFormatVersion: Int,
    compatibilityRevision: String,
    savedAt: Date,
    storedAt: Date,
    canonicalCheckpointData: Data,
    checkpointDigest: String
  ) {
    self.checkpointID = checkpointID
    self.checkpointKey = checkpointKey
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.checkpointFormatVersion = checkpointFormatVersion
    self.compatibilityRevision = compatibilityRevision
    self.savedAt = savedAt
    self.storedAt = storedAt
    self.canonicalCheckpointData = canonicalCheckpointData
    self.checkpointDigest = checkpointDigest
  }

  public func decodeCheckpoint(
    expectedAuthorityBoundaryID: String,
    expectedPolicyVersion: Int
  ) throws -> CoreAgentCheckpoint {
    guard authorityBoundaryID == expectedAuthorityBoundaryID else {
      throw CoreAgentSwiftDataCheckpointAccessError.authorityBoundaryMismatch(
        expected: expectedAuthorityBoundaryID,
        actual: authorityBoundaryID
      )
    }
    guard policyVersion == expectedPolicyVersion else {
      throw CoreAgentSwiftDataCheckpointAccessError.policyVersionMismatch(
        expected: expectedPolicyVersion,
        actual: policyVersion
      )
    }
    let actualDigest = Self.digest(
      checkpointID: checkpointID,
      checkpointKey: checkpointKey,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      checkpointFormatVersion: checkpointFormatVersion,
      compatibilityRevision: compatibilityRevision,
      savedAt: savedAt,
      canonicalCheckpointData: canonicalCheckpointData
    )
    guard actualDigest == checkpointDigest else {
      throw CoreAgentSwiftDataCheckpointAccessError.digestMismatch(
        expected: checkpointDigest,
        actual: actualDigest
      )
    }
    let checkpoint = try Self.decoder().decode(
      CoreAgentCheckpoint.self,
      from: canonicalCheckpointData
    )
    guard checkpoint.formatVersion == checkpointFormatVersion else {
      throw CoreAgentSwiftDataCheckpointAccessError.formatVersionMismatch(
        expected: checkpointFormatVersion,
        actual: checkpoint.formatVersion
      )
    }
    guard checkpoint.compatibilityRevision == compatibilityRevision else {
      throw CoreAgentSwiftDataCheckpointAccessError.compatibilityRevisionMismatch(
        expected: compatibilityRevision,
        actual: checkpoint.compatibilityRevision
      )
    }
    guard Self.timeToken(checkpoint.savedAt) == Self.timeToken(savedAt) else {
      throw CoreAgentSwiftDataCheckpointAccessError.savedAtMismatch(
        expected: savedAt,
        actual: checkpoint.savedAt
      )
    }
    return checkpoint
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return decoder
  }

  static func digest(
    checkpointID: UUID,
    checkpointKey: String,
    authorityBoundaryID: String,
    policyVersion: Int,
    checkpointFormatVersion: Int,
    compatibilityRevision: String,
    savedAt: Date,
    canonicalCheckpointData: Data
  ) -> String {
    let checkpointBytesDigest = sha256Hex(canonicalCheckpointData)
    let fields = [
      checkpointID.uuidString.lowercased(),
      checkpointKey,
      authorityBoundaryID,
      String(policyVersion),
      String(checkpointFormatVersion),
      compatibilityRevision,
      timeToken(savedAt),
      checkpointBytesDigest,
    ]
    return "sha256:"
      + sha256Hex(
        Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
      )
  }

  private static func sha256Hex(_ data: Data) -> String {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return hash
  }

  private static func timeToken(_ date: Date) -> String {
    stableTimeToken(date)
  }
}

@Model
public final class CoreAgentSwiftDataCheckpointRecord {
  public private(set) var checkpointID: UUID
  public private(set) var scopeKey: String
  public private(set) var checkpointKey: String
  public private(set) var authorityBoundaryID: String
  public private(set) var policyVersion: Int
  public private(set) var checkpointFormatVersion: Int
  public private(set) var compatibilityRevision: String
  public private(set) var savedAt: Date
  public private(set) var storedAt: Date
  public private(set) var encodedCheckpoint: Data
  public private(set) var checkpointDigest: String

  public init(snapshot: CoreAgentSwiftDataCheckpointSnapshot) {
    self.checkpointID = snapshot.checkpointID
    self.scopeKey = Self.scopeKey(
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion
    )
    self.checkpointKey = snapshot.checkpointKey
    self.authorityBoundaryID = snapshot.authorityBoundaryID
    self.policyVersion = snapshot.policyVersion
    self.checkpointFormatVersion = snapshot.checkpointFormatVersion
    self.compatibilityRevision = snapshot.compatibilityRevision
    self.savedAt = snapshot.savedAt
    self.storedAt = snapshot.storedAt
    self.encodedCheckpoint = snapshot.canonicalCheckpointData
    self.checkpointDigest = snapshot.checkpointDigest
  }

  public var snapshot: CoreAgentSwiftDataCheckpointSnapshot {
    CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: checkpointID,
      checkpointKey: checkpointKey,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      checkpointFormatVersion: checkpointFormatVersion,
      compatibilityRevision: compatibilityRevision,
      savedAt: savedAt,
      storedAt: storedAt,
      canonicalCheckpointData: encodedCheckpoint,
      checkpointDigest: checkpointDigest
    )
  }

  public static func scopeKey(
    checkpointKey: String,
    authorityBoundaryID: String,
    policyVersion: Int
  ) -> String {
    let fields = [
      checkpointKey,
      authorityBoundaryID,
      String(policyVersion),
    ]
    let payload = Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
    return "scope-sha256-v1:"
      + SHA256.hash(data: payload)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

@MainActor
public final class CoreAgentSwiftDataCheckpointStore: CoreAgentCheckpointStore {
  private let modelContext: ModelContext
  private let authorityBoundaryID: String
  private let policyVersion: Int
  private let typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy
  private let rollsBackOnFailure: Bool
  private let clock: @Sendable () -> Date

  public init(
    modelContext: ModelContext,
    authorityBoundaryID: String,
    policyVersion: Int,
    typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy = .rejectLossyContent,
    rollsBackOnFailure: Bool = false,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.modelContext = modelContext
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.typeErasurePolicy = typeErasurePolicy
    self.rollsBackOnFailure = rollsBackOnFailure
    self.clock = clock
  }

  public convenience init(
    modelContainer: ModelContainer,
    authorityBoundaryID: String,
    policyVersion: Int,
    typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy = .rejectLossyContent,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      modelContext: ModelContext(modelContainer),
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      typeErasurePolicy: typeErasurePolicy,
      rollsBackOnFailure: true,
      clock: clock
    )
  }

  public func loadCheckpoint(for key: String) async throws -> CoreAgentCheckpoint? {
    guard let record = try scopedRecords(for: key).first else {
      return nil
    }
    return try record.snapshot.decodeCheckpoint(
      expectedAuthorityBoundaryID: authorityBoundaryID,
      expectedPolicyVersion: policyVersion
    )
  }

  public func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) async throws {
    try CoreAgentCheckpointPersistenceValidation.validate(
      checkpoint,
      typeErasurePolicy: typeErasurePolicy
    )
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: key,
      checkpoint: checkpoint,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      storedAt: clock()
    )
    do {
      for record in try scopedRecords(for: key) {
        modelContext.delete(record)
      }
      modelContext.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: snapshot))
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  /// Hard-deletes all rows in this checkpoint key's authority/policy scope.
  ///
  /// When the store was created from a `ModelContainer`, failed mutations roll
  /// back its isolated context. When the host supplied a shared `ModelContext`,
  /// rollback is caller-owned so unrelated pending app changes are not
  /// discarded by the checkpoint store.
  public func removeCheckpoint(for key: String) async throws {
    do {
      for record in try scopedRecords(for: key) {
        modelContext.delete(record)
      }
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  private func scopedRecords(for key: String) throws -> [CoreAgentSwiftDataCheckpointRecord] {
    let scopeKey = CoreAgentSwiftDataCheckpointRecord.scopeKey(
      checkpointKey: key,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )
    let checkpointKey = key
    let authorityBoundaryID = self.authorityBoundaryID
    let policyVersion = self.policyVersion
    let descriptor = FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>(
      predicate: #Predicate<CoreAgentSwiftDataCheckpointRecord> { record in
        record.scopeKey == scopeKey
          && record.checkpointKey == checkpointKey
          && record.authorityBoundaryID == authorityBoundaryID
          && record.policyVersion == policyVersion
      }
    )
    let records = try modelContext.fetch(descriptor)
    return
      records
      .filter { record in
        // Keep these checks even though the SwiftData predicate includes them:
        // they are a final in-process guard if rows are manually corrupted.
        record.scopeKey == scopeKey
          && record.checkpointKey == key
          && record.authorityBoundaryID == authorityBoundaryID
          && record.policyVersion == policyVersion
      }
      .sorted { lhs, rhs in
        if lhs.savedAt != rhs.savedAt {
          return lhs.savedAt > rhs.savedAt
        }
        if lhs.storedAt != rhs.storedAt {
          return lhs.storedAt > rhs.storedAt
        }
        return lhs.checkpointID.uuidString < rhs.checkpointID.uuidString
      }
  }

  private func recoverAfterFailedMutation() {
    guard rollsBackOnFailure else {
      return
    }
    modelContext.rollback()
  }
}

private func stableTimeToken(_ date: Date) -> String {
  let scaled = (date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded()
  guard scaled.isFinite else {
    return scaled.sign == .minus ? String(Int64.min) : String(Int64.max)
  }
  if scaled >= Double(Int64.max) {
    return String(Int64.max)
  }
  if scaled <= Double(Int64.min) {
    return String(Int64.min)
  }
  return String(Int64(scaled))
}
