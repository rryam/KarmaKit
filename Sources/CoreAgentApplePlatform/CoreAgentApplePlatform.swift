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

public enum CoreAgentSwiftDataGraphPersistenceError: Error, Equatable, Sendable {
  case checkpointScopeMismatch(checkpointID: String, expected: String, actual: String)
  case checkpointDigestMismatch(checkpointID: String, expected: String, actual: String)
  case checkpointPayloadDecodeFailed(checkpointID: String)
  case checkpointSidecarMismatch(checkpointID: String)
  case storeScopeMismatch(namespace: String, key: String, expected: String, actual: String)
  case storeDigestMismatch(namespace: String, key: String, expected: String, actual: String)
  case storePayloadDecodeFailed(namespace: String, key: String)
  case storeSidecarMismatch(namespace: String, key: String)
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
    return "sha256:" + sha256Hex(
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
    return "scope-sha256-v1:" + SHA256.hash(data: payload)
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
    return records
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

@Model
public final class CoreAgentSwiftDataEngineTraceRecord {
  public private(set) var traceScopeKey: String
  public private(set) var projectID: String
  public private(set) var threadID: String?
  public private(set) var runID: UUID
  public private(set) var startedAt: Date
  public private(set) var endedAt: Date
  public private(set) var ingestedAt: Date
  public private(set) var sequence: Int
  public private(set) var redactionPolicyIdentifier: String
  public private(set) var encodedTrace: Data
  public private(set) var traceDigest: String

  public convenience init(
    trace: CoreAgentEngineTrace,
    sequence: Int,
    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier
  ) throws {
    let encodedTrace = try CoreAgentSwiftDataEngineCodec.encode(trace)
    self.init(
      projectID: trace.projectID,
      threadID: trace.threadID,
      runID: trace.run.id,
      startedAt: trace.run.startedAt,
      endedAt: trace.run.endedAt,
      ingestedAt: trace.ingestedAt,
      sequence: sequence,
      redactionPolicyIdentifier: redactionPolicyIdentifier,
      encodedTrace: encodedTrace,
      traceDigest: Self.integrityDigest(
        traceScopeKey: Self.scopeKey(projectID: trace.projectID, runID: trace.run.id),
        projectID: trace.projectID,
        threadID: trace.threadID,
        runID: trace.run.id,
        startedAt: trace.run.startedAt,
        endedAt: trace.run.endedAt,
        ingestedAt: trace.ingestedAt,
        redactionPolicyIdentifier: redactionPolicyIdentifier,
        encodedTrace: encodedTrace
      )
    )
  }

  public init(
    projectID: String,
    threadID: String?,
    runID: UUID,
    startedAt: Date,
    endedAt: Date,
    ingestedAt: Date,
    sequence: Int = 0,
    traceScopeKey: String? = nil,
    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier,
    encodedTrace: Data,
    traceDigest: String
  ) {
    self.traceScopeKey = traceScopeKey ?? Self.scopeKey(projectID: projectID, runID: runID)
    self.projectID = projectID
    self.threadID = threadID
    self.runID = runID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.ingestedAt = ingestedAt
    self.sequence = sequence
    self.redactionPolicyIdentifier = redactionPolicyIdentifier
    self.encodedTrace = encodedTrace
    self.traceDigest = traceDigest
  }

  var trace: CoreAgentEngineTrace? {
    guard traceScopeKey == Self.scopeKey(projectID: projectID, runID: runID) else {
      return nil
    }
    guard traceDigest == Self.integrityDigest(
      traceScopeKey: traceScopeKey,
      projectID: projectID,
      threadID: threadID,
      runID: runID,
      startedAt: startedAt,
      endedAt: endedAt,
      ingestedAt: ingestedAt,
      redactionPolicyIdentifier: redactionPolicyIdentifier,
      encodedTrace: encodedTrace
    ) else {
      return nil
    }
    guard let trace = try? CoreAgentSwiftDataEngineCodec.decode(
      CoreAgentEngineTrace.self,
      from: encodedTrace
    ) else {
      return nil
    }
    guard trace.projectID == projectID,
      trace.threadID == threadID,
      trace.run.id == runID,
      trace.run.startedAt == startedAt,
      trace.run.endedAt == endedAt,
      trace.ingestedAt == ingestedAt,
      trace.receipt.runID == trace.run.id,
      trace.receipt.verify()
    else {
      return nil
    }
    return trace
  }

  public static func scopeKey(projectID: String, runID: UUID) -> String {
    let fields = [
      projectID,
      runID.uuidString.lowercased(),
    ]
    return "engine-trace-scope-sha256-v1:" + sha256Hex(framed(fields))
  }

  static func integrityDigest(
    traceScopeKey: String? = nil,
    projectID: String,
    threadID: String?,
    runID: UUID,
    startedAt: Date,
    endedAt: Date,
    ingestedAt: Date,
    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier,
    encodedTrace: Data
  ) -> String {
    let fields = [
      traceScopeKey ?? Self.scopeKey(projectID: projectID, runID: runID),
      projectID,
      threadID ?? "nil",
      runID.uuidString.lowercased(),
      timeToken(startedAt),
      timeToken(endedAt),
      timeToken(ingestedAt),
      redactionPolicyIdentifier,
      sha256Hex(encodedTrace),
    ]
    return "sha256:" + sha256Hex(framed(fields))
  }
}

@Model
public final class CoreAgentSwiftDataEngineIssueRecord {
  public private(set) var issueID: String
  public private(set) var projectID: String
  public private(set) var fingerprint: String
  public private(set) var statusRawValue: String
  public private(set) var firstSeenAt: Date
  public private(set) var lastSeenAt: Date
  public private(set) var encodedIssue: Data
  public private(set) var issueDigest: String

  public convenience init(issue: CoreAgentEngineIssue) throws {
    let encodedIssue = try CoreAgentSwiftDataEngineCodec.encode(issue)
    self.init(
      issueID: issue.id,
      projectID: issue.projectID,
      fingerprint: issue.fingerprint,
      statusRawValue: issue.status.rawValue,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt,
      encodedIssue: encodedIssue,
      issueDigest: Self.integrityDigest(
        issueID: issue.id,
        projectID: issue.projectID,
        fingerprint: issue.fingerprint,
        statusRawValue: issue.status.rawValue,
        firstSeenAt: issue.firstSeenAt,
        lastSeenAt: issue.lastSeenAt,
        encodedIssue: encodedIssue
      )
    )
  }

  public init(
    issueID: String,
    projectID: String,
    fingerprint: String,
    statusRawValue: String,
    firstSeenAt: Date,
    lastSeenAt: Date,
    encodedIssue: Data,
    issueDigest: String
  ) {
    self.issueID = issueID
    self.projectID = projectID
    self.fingerprint = fingerprint
    self.statusRawValue = statusRawValue
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
    self.encodedIssue = encodedIssue
    self.issueDigest = issueDigest
  }

  var issue: CoreAgentEngineIssue? {
    guard issueDigest == Self.integrityDigest(
      issueID: issueID,
      projectID: projectID,
      fingerprint: fingerprint,
      statusRawValue: statusRawValue,
      firstSeenAt: firstSeenAt,
      lastSeenAt: lastSeenAt,
      encodedIssue: encodedIssue
    ) else {
      return nil
    }
    guard let issue = try? CoreAgentSwiftDataEngineCodec.decode(
      CoreAgentEngineIssue.self,
      from: encodedIssue
    ) else {
      return nil
    }
    guard issue.id == issueID,
      issue.projectID == projectID,
      issue.fingerprint == fingerprint,
      issue.status.rawValue == statusRawValue,
      issue.firstSeenAt == firstSeenAt,
      issue.lastSeenAt == lastSeenAt
    else {
      return nil
    }
    return issue
  }

  static func integrityDigest(
    issueID: String,
    projectID: String,
    fingerprint: String,
    statusRawValue: String,
    firstSeenAt: Date,
    lastSeenAt: Date,
    encodedIssue: Data
  ) -> String {
    let fields = [
      issueID,
      projectID,
      fingerprint,
      statusRawValue,
      timeToken(firstSeenAt),
      timeToken(lastSeenAt),
      sha256Hex(encodedIssue),
    ]
    return "sha256:" + sha256Hex(framed(fields))
  }
}

@MainActor
public final class CoreAgentSwiftDataEngineStore: CoreAgentEngineStore {
  private let modelContext: ModelContext
  private let redactionPolicy: CoreAgentEngineRedactionPolicy
  private let rollsBackOnFailure: Bool

  public init(
    modelContext: ModelContext,
    redactionPolicy: CoreAgentEngineRedactionPolicy = .standard,
    rollsBackOnFailure: Bool = false
  ) {
    self.modelContext = modelContext
    self.redactionPolicy = redactionPolicy
    self.rollsBackOnFailure = rollsBackOnFailure
  }

  public convenience init(
    modelContainer: ModelContainer,
    redactionPolicy: CoreAgentEngineRedactionPolicy = .standard
  ) {
    self.init(
      modelContext: ModelContext(modelContainer),
      redactionPolicy: redactionPolicy,
      rollsBackOnFailure: true
    )
  }

  @discardableResult
  public func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String? = nil
  ) async throws -> CoreAgentEngineTrace {
    try validate(run)
    let redactedRun = redactionPolicy.redacted(run: run)
    let trace = try CoreAgentEngineTrace(
      projectID: projectID,
      threadID: threadID,
      run: redactedRun,
      receipt: CoreAgentRunReceipt(run: redactedRun)
    )
    let record = try CoreAgentSwiftDataEngineTraceRecord(
      trace: trace,
      sequence: nextTraceSequence(),
      redactionPolicyIdentifier: redactionPolicy.identifier
    )
    do {
      for record in try traceRecords(projectID: projectID, runID: redactedRun.id) {
        modelContext.delete(record)
      }
      modelContext.insert(record)
      try modelContext.save()
      return trace
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    guard let records = try? traceRecords(projectID: projectID, runID: runID) else {
      return nil
    }
    return canonicalTraces(from: records).first
  }

  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
    guard let records = try? traceRecords(projectID: projectID, threadID: threadID) else {
      return []
    }
    return canonicalTraces(from: records)
  }

  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    let existingRecords = try issueRecords(issueID: issue.id)
    let existingIssues = existingRecords.compactMap(\.issue)
    try validateIssueIdentity(existingIssues, incoming: issue)
    let storedIssue: CoreAgentEngineIssue
    if let existing = canonicalIssues(from: existingIssues).first {
      let existingRuns = Set(existing.contributingRunIDs)
      let incomingRuns = Set(issue.contributingRunIDs)
      let hasNewRuns = !incomingRuns.isSubset(of: existingRuns)
      let mergedRunIDs = existing.contributingRunIDs
        + issue.contributingRunIDs.filter { !existingRuns.contains($0) }
      let nextStatus =
        existing.status == .resolved && hasNewRuns
        ? CoreAgentEngineIssueStatus.reopened
        : existing.status
      storedIssue = CoreAgentEngineIssue(
        id: existing.id,
        projectID: existing.projectID,
        fingerprint: existing.fingerprint,
        title: issue.title,
        contributingRunIDs: mergedRunIDs,
        status: nextStatus,
        firstSeenAt: min(existing.firstSeenAt, issue.firstSeenAt),
        lastSeenAt: max(existing.lastSeenAt, issue.lastSeenAt)
      )
    } else {
      storedIssue = issue
    }
    let storedRecord = try CoreAgentSwiftDataEngineIssueRecord(issue: storedIssue)
    do {
      for record in existingRecords {
        modelContext.delete(record)
      }
      modelContext.insert(storedRecord)
      try modelContext.save()
      return storedIssue
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func updateIssueStatus(
    _ issueID: String,
    status: CoreAgentEngineIssueStatus
  ) async throws {
    let existingRecords = try issueRecords(issueID: issueID)
    guard let issue = canonicalIssues(from: existingRecords.compactMap(\.issue)).first else {
      return
    }
    let updated = CoreAgentEngineIssue(
      id: issue.id,
      projectID: issue.projectID,
      fingerprint: issue.fingerprint,
      title: issue.title,
      contributingRunIDs: issue.contributingRunIDs,
      status: status,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt
    )
    let updatedRecord = try CoreAgentSwiftDataEngineIssueRecord(issue: updated)
    do {
      for record in existingRecords {
        modelContext.delete(record)
      }
      modelContext.insert(updatedRecord)
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func issues(
    projectID: String,
    status: CoreAgentEngineIssueStatus? = nil
  ) async -> [CoreAgentEngineIssue] {
    guard let records = try? issueRecords(projectID: projectID) else {
      return []
    }
    let issues = canonicalIssues(from: records.compactMap(\.issue))
    guard let status else {
      return issues
    }
    return issues.filter { $0.status == status }
  }

  private func traceRecords(
    projectID: String,
    runID: UUID
  ) throws -> [CoreAgentSwiftDataEngineTraceRecord] {
    let scopeKey = CoreAgentSwiftDataEngineTraceRecord.scopeKey(projectID: projectID, runID: runID)
    let descriptor = FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>(
      predicate: #Predicate<CoreAgentSwiftDataEngineTraceRecord> { record in
        record.traceScopeKey == scopeKey
          && record.projectID == projectID
          && record.runID == runID
      },
      sortBy: [
        SortDescriptor(\.sequence, order: .reverse),
        SortDescriptor(\.ingestedAt, order: .reverse),
      ]
    )
    return try modelContext.fetch(descriptor)
  }

  private func traceRecords(
    projectID: String,
    threadID: String?
  ) throws -> [CoreAgentSwiftDataEngineTraceRecord] {
    let descriptor: FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>
    if let threadID {
      descriptor = FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>(
        predicate: #Predicate<CoreAgentSwiftDataEngineTraceRecord> { record in
          record.projectID == projectID && record.threadID == threadID
        },
        sortBy: [SortDescriptor(\.sequence)]
      )
    } else {
      descriptor = FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>(
        predicate: #Predicate<CoreAgentSwiftDataEngineTraceRecord> { record in
          record.projectID == projectID
        },
        sortBy: [SortDescriptor(\.sequence)]
      )
    }
    return try modelContext.fetch(descriptor)
  }

  private func issueRecords(issueID: String) throws -> [CoreAgentSwiftDataEngineIssueRecord] {
    let descriptor = FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>(
      predicate: #Predicate<CoreAgentSwiftDataEngineIssueRecord> { record in
        record.issueID == issueID
      },
      sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  private func issueRecords(
    projectID: String
  ) throws -> [CoreAgentSwiftDataEngineIssueRecord] {
    let descriptor = FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>(
      predicate: #Predicate<CoreAgentSwiftDataEngineIssueRecord> { record in
        record.projectID == projectID
      },
      sortBy: [
        SortDescriptor(\.firstSeenAt),
        SortDescriptor(\.fingerprint),
      ]
    )
    return try modelContext.fetch(descriptor)
  }

  private func nextTraceSequence() throws -> Int {
    var descriptor = FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>(
      sortBy: [SortDescriptor(\.sequence, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return ((try modelContext.fetch(descriptor).first?.sequence) ?? -1) + 1
  }

  private func verifiedTraceSnapshot(
    from record: CoreAgentSwiftDataEngineTraceRecord
  ) -> VerifiedTraceSnapshot? {
    guard let trace = record.trace,
      record.redactionPolicyIdentifier == redactionPolicy.identifier,
      redactionPolicy.redacted(run: trace.run) == trace.run
    else {
      return nil
    }
    return VerifiedTraceSnapshot(
      scopeKey: CoreAgentSwiftDataEngineTraceRecord.scopeKey(
        projectID: trace.projectID,
        runID: trace.run.id
      ),
      sequence: record.sequence,
      ingestedAt: record.ingestedAt,
      runID: record.runID,
      trace: trace
    )
  }

  private func canonicalTraces(
    from records: [CoreAgentSwiftDataEngineTraceRecord]
  ) -> [CoreAgentEngineTrace] {
    var winners: [String: VerifiedTraceSnapshot] = [:]
    for record in records {
      guard let candidate = verifiedTraceSnapshot(from: record) else {
        continue
      }
      guard let existing = winners[candidate.scopeKey] else {
        winners[candidate.scopeKey] = candidate
        continue
      }
      if candidate.isNewer(than: existing) {
        winners[candidate.scopeKey] = candidate
      }
    }
    return winners.values
      .sorted { lhs, rhs in
        if lhs.sequence != rhs.sequence {
          return lhs.sequence < rhs.sequence
        }
        if lhs.ingestedAt != rhs.ingestedAt {
          return lhs.ingestedAt < rhs.ingestedAt
        }
        return lhs.runID.uuidString < rhs.runID.uuidString
      }
      .map(\.trace)
  }

  private func canonicalIssues(from issues: [CoreAgentEngineIssue]) -> [CoreAgentEngineIssue] {
    var winners: [CoreAgentEngineIssue] = []
    let groupedIssues = Dictionary(grouping: issues, by: \.id)
    for group in groupedIssues.values {
      guard var winner = group.first,
        group.allSatisfy({
          $0.projectID == winner.projectID && $0.fingerprint == winner.fingerprint
        })
      else {
        continue
      }
      for candidate in group.dropFirst() {
        winner = winner.mergedEngineIssueDuplicate(with: candidate)
      }
      winners.append(winner)
    }
    return winners.sorted { lhs, rhs in
      if lhs.firstSeenAt != rhs.firstSeenAt {
        return lhs.firstSeenAt < rhs.firstSeenAt
      }
      return lhs.fingerprint < rhs.fingerprint
    }
  }

  private func validateIssueIdentity(
    _ existingIssues: [CoreAgentEngineIssue],
    incoming issue: CoreAgentEngineIssue
  ) throws {
    for existing in existingIssues {
      guard existing.projectID == issue.projectID,
        existing.fingerprint == issue.fingerprint
      else {
        throw CoreAgentEngineStoreError.issueIdentityMismatch(
          issueID: issue.id,
          existingProjectID: existing.projectID,
          incomingProjectID: issue.projectID,
          existingFingerprint: existing.fingerprint,
          incomingFingerprint: issue.fingerprint
        )
      }
    }
  }

  private func validate(_ run: CoreAgentRun) throws {
    guard run.events.contains(where: { $0.kind == .runCompleted || $0.kind == .runFailed })
    else {
      throw CoreAgentEngineStoreError.nonFinalizedRun(run.id)
    }
    for event in run.events where event.runID != run.id {
      throw CoreAgentEngineStoreError.eventRunIDMismatch(
        eventRunID: event.runID,
        runID: run.id
      )
    }
  }

  private func recoverAfterFailedMutation() {
    guard rollsBackOnFailure else {
      return
    }
    modelContext.rollback()
  }

  private struct VerifiedTraceSnapshot {
    let scopeKey: String
    let sequence: Int
    let ingestedAt: Date
    let runID: UUID
    let trace: CoreAgentEngineTrace

    func isNewer(than other: VerifiedTraceSnapshot) -> Bool {
      if sequence != other.sequence {
        return sequence > other.sequence
      }
      if ingestedAt != other.ingestedAt {
        return ingestedAt > other.ingestedAt
      }
      return runID.uuidString < other.runID.uuidString
    }
  }
}

private extension CoreAgentEngineIssue {
  func mergedEngineIssueDuplicate(with other: CoreAgentEngineIssue) -> CoreAgentEngineIssue {
    let preferred = other.isNewerEngineIssue(than: self) ? other : self
    let existingRunIDs = Set(contributingRunIDs)
    let mergedRunIDs = contributingRunIDs
      + other.contributingRunIDs.filter { !existingRunIDs.contains($0) }
    let sortedRunIDs = mergedRunIDs.sorted { $0.uuidString < $1.uuidString }
    return CoreAgentEngineIssue(
      id: preferred.id,
      projectID: preferred.projectID,
      fingerprint: preferred.fingerprint,
      title: preferred.title,
      contributingRunIDs: sortedRunIDs,
      status: preferred.status,
      firstSeenAt: min(firstSeenAt, other.firstSeenAt),
      lastSeenAt: max(lastSeenAt, other.lastSeenAt)
    )
  }

  func isNewerEngineIssue(than other: CoreAgentEngineIssue) -> Bool {
    if lastSeenAt != other.lastSeenAt {
      return lastSeenAt > other.lastSeenAt
    }
    if firstSeenAt != other.firstSeenAt {
      return firstSeenAt < other.firstSeenAt
    }
    if status.enginePersistencePriority != other.status.enginePersistencePriority {
      return status.enginePersistencePriority > other.status.enginePersistencePriority
    }
    if contributingRunIDs.count != other.contributingRunIDs.count {
      return contributingRunIDs.count > other.contributingRunIDs.count
    }
    return fingerprint < other.fingerprint
  }
}

private extension CoreAgentEngineIssueStatus {
  var enginePersistencePriority: Int {
    switch self {
    case .ignored:
      return 3
    case .reopened:
      return 2
    case .resolved:
      return 1
    case .open:
      return 0
    }
  }
}

@Model
public final class CoreAgentSwiftDataGraphCheckpointRecord {
  public private(set) var checkpointScopeKey: String
  public private(set) var checkpointID: String
  public private(set) var threadID: String
  public private(set) var namespace: String
  public private(set) var parentCheckpointID: String?
  public private(set) var step: Int
  public private(set) var createdAt: Date
  public private(set) var storedAt: Date
  public private(set) var saveSequence: Int
  public private(set) var encodedCheckpoint: Data
  public private(set) var checkpointDigest: String

  public convenience init<State: Codable & Sendable>(
    checkpoint: CoreAgentGraphCheckpoint<State>,
    saveSequence: Int,
    storedAt: Date = Date()
  ) throws {
    let encodedCheckpoint = try CoreAgentSwiftDataGraphCodec.encode(checkpoint)
    self.init(
      checkpointID: checkpoint.id.rawValue,
      threadID: checkpoint.threadID.rawValue,
      namespace: checkpoint.namespace.rawValue,
      parentCheckpointID: checkpoint.parentCheckpointID?.rawValue,
      step: checkpoint.step,
      createdAt: checkpoint.createdAt,
      storedAt: storedAt,
      saveSequence: saveSequence,
      encodedCheckpoint: encodedCheckpoint,
      checkpointDigest: Self.integrityDigest(
        checkpointScopeKey: Self.scopeKey(
          threadID: checkpoint.threadID.rawValue,
          namespace: checkpoint.namespace.rawValue
        ),
        checkpointID: checkpoint.id.rawValue,
        threadID: checkpoint.threadID.rawValue,
        namespace: checkpoint.namespace.rawValue,
        parentCheckpointID: checkpoint.parentCheckpointID?.rawValue,
        step: checkpoint.step,
        createdAt: checkpoint.createdAt,
        storedAt: storedAt,
        saveSequence: saveSequence,
        encodedCheckpoint: encodedCheckpoint
      )
    )
  }

  public init(
    checkpointID: String,
    threadID: String,
    namespace: String,
    parentCheckpointID: String?,
    step: Int,
    createdAt: Date,
    storedAt: Date,
    saveSequence: Int = 0,
    checkpointScopeKey: String? = nil,
    encodedCheckpoint: Data,
    checkpointDigest: String
  ) {
    self.checkpointScopeKey = checkpointScopeKey ?? Self.scopeKey(
      threadID: threadID,
      namespace: namespace
    )
    self.checkpointID = checkpointID
    self.threadID = threadID
    self.namespace = namespace
    self.parentCheckpointID = parentCheckpointID
    self.step = step
    self.createdAt = createdAt
    self.storedAt = storedAt
    self.saveSequence = saveSequence
    self.encodedCheckpoint = encodedCheckpoint
    self.checkpointDigest = checkpointDigest
  }

  func checkpoint<State: Codable & Sendable>(
    as type: State.Type
  ) throws -> CoreAgentGraphCheckpoint<State> {
    let expectedScopeKey = Self.scopeKey(threadID: threadID, namespace: namespace)
    guard checkpointScopeKey == expectedScopeKey else {
      throw CoreAgentSwiftDataGraphPersistenceError.checkpointScopeMismatch(
        checkpointID: checkpointID,
        expected: expectedScopeKey,
        actual: checkpointScopeKey
      )
    }
    let actualDigest = Self.integrityDigest(
      checkpointScopeKey: checkpointScopeKey,
      checkpointID: checkpointID,
      threadID: threadID,
      namespace: namespace,
      parentCheckpointID: parentCheckpointID,
      step: step,
      createdAt: createdAt,
      storedAt: storedAt,
      saveSequence: saveSequence,
      encodedCheckpoint: encodedCheckpoint
    )
    guard checkpointDigest == actualDigest else {
      throw CoreAgentSwiftDataGraphPersistenceError.checkpointDigestMismatch(
        checkpointID: checkpointID,
        expected: checkpointDigest,
        actual: actualDigest
      )
    }
    let checkpoint: CoreAgentGraphCheckpoint<State>
    do {
      checkpoint = try CoreAgentSwiftDataGraphCodec.decode(
        CoreAgentGraphCheckpoint<State>.self,
        from: encodedCheckpoint
      )
    } catch {
      throw CoreAgentSwiftDataGraphPersistenceError.checkpointPayloadDecodeFailed(
        checkpointID: checkpointID
      )
    }
    guard checkpoint.id.rawValue == checkpointID,
      checkpoint.threadID.rawValue == threadID,
      checkpoint.namespace.rawValue == namespace,
      checkpoint.parentCheckpointID?.rawValue == parentCheckpointID,
      checkpoint.step == step,
      checkpoint.createdAt == createdAt
    else {
      throw CoreAgentSwiftDataGraphPersistenceError.checkpointSidecarMismatch(
        checkpointID: checkpointID
      )
    }
    return checkpoint
  }

  public static func scopeKey(threadID: String, namespace: String) -> String {
    "graph-checkpoint-scope-sha256-v1:" + sha256Hex(framed([threadID, namespace]))
  }

  static func integrityDigest(
    checkpointScopeKey: String? = nil,
    checkpointID: String,
    threadID: String,
    namespace: String,
    parentCheckpointID: String?,
    step: Int,
    createdAt: Date,
    storedAt: Date,
    saveSequence: Int = 0,
    encodedCheckpoint: Data
  ) -> String {
    let fields = [
      checkpointScopeKey ?? Self.scopeKey(threadID: threadID, namespace: namespace),
      checkpointID,
      threadID,
      namespace,
      parentCheckpointID ?? "nil",
      String(step),
      timeToken(createdAt),
      timeToken(storedAt),
      String(saveSequence),
      sha256Hex(encodedCheckpoint),
    ]
    return "sha256:" + sha256Hex(framed(fields))
  }
}

@Model
public final class CoreAgentSwiftDataGraphStoreRecord {
  public private(set) var storeScopeKey: String
  public private(set) var namespace: String
  public private(set) var key: String
  public private(set) var updatedAt: Date
  public private(set) var encodedValue: Data
  public private(set) var valueDigest: String

  public convenience init<Value: Codable & Sendable>(
    record: CoreAgentGraphStoreRecord<Value>
  ) throws {
    let encodedValue = try CoreAgentSwiftDataGraphCodec.encode(record.value)
    self.init(
      namespace: record.namespace.rawValue,
      key: record.key.rawValue,
      updatedAt: record.updatedAt,
      encodedValue: encodedValue,
      valueDigest: Self.integrityDigest(
        storeScopeKey: Self.scopeKey(
          namespace: record.namespace.rawValue,
          key: record.key.rawValue
        ),
        namespace: record.namespace.rawValue,
        key: record.key.rawValue,
        updatedAt: record.updatedAt,
        encodedValue: encodedValue
      )
    )
  }

  public init(
    namespace: String,
    key: String,
    updatedAt: Date,
    storeScopeKey: String? = nil,
    encodedValue: Data,
    valueDigest: String
  ) {
    self.storeScopeKey = storeScopeKey ?? Self.scopeKey(namespace: namespace, key: key)
    self.namespace = namespace
    self.key = key
    self.updatedAt = updatedAt
    self.encodedValue = encodedValue
    self.valueDigest = valueDigest
  }

  func graphRecord<Value: Codable & Sendable>(
    as type: Value.Type
  ) throws -> CoreAgentGraphStoreRecord<Value> {
    try validateIntegrity()
    let value: Value
    do {
      value = try CoreAgentSwiftDataGraphCodec.decode(Value.self, from: encodedValue)
    } catch {
      throw CoreAgentSwiftDataGraphPersistenceError.storePayloadDecodeFailed(
        namespace: namespace,
        key: key
      )
    }
    let graphRecord = CoreAgentGraphStoreRecord(
      namespace: CoreAgentGraphStoreNamespace(namespace),
      key: CoreAgentGraphStoreKey(key),
      value: value,
      updatedAt: updatedAt
    )
    guard graphRecord.namespace.rawValue == namespace,
      graphRecord.key.rawValue == key
    else {
      throw CoreAgentSwiftDataGraphPersistenceError.storeSidecarMismatch(
        namespace: namespace,
        key: key
      )
    }
    return graphRecord
  }

  func validateIntegrity() throws {
    let expectedScopeKey = Self.scopeKey(namespace: namespace, key: key)
    guard storeScopeKey == expectedScopeKey else {
      throw CoreAgentSwiftDataGraphPersistenceError.storeScopeMismatch(
        namespace: namespace,
        key: key,
        expected: expectedScopeKey,
        actual: storeScopeKey
      )
    }
    let actualDigest = Self.integrityDigest(
      storeScopeKey: storeScopeKey,
      namespace: namespace,
      key: key,
      updatedAt: updatedAt,
      encodedValue: encodedValue
    )
    guard valueDigest == actualDigest else {
      throw CoreAgentSwiftDataGraphPersistenceError.storeDigestMismatch(
        namespace: namespace,
        key: key,
        expected: valueDigest,
        actual: actualDigest
      )
    }
  }

  public static func scopeKey(namespace: String, key: String) -> String {
    "graph-store-scope-sha256-v1:" + sha256Hex(framed([namespace, key]))
  }

  static func integrityDigest(
    storeScopeKey: String? = nil,
    namespace: String,
    key: String,
    updatedAt: Date,
    encodedValue: Data
  ) -> String {
    let fields = [
      storeScopeKey ?? Self.scopeKey(namespace: namespace, key: key),
      namespace,
      key,
      timeToken(updatedAt),
      sha256Hex(encodedValue),
    ]
    return "sha256:" + sha256Hex(framed(fields))
  }
}

@MainActor
public final class CoreAgentSwiftDataGraphCheckpointer<State: Codable & Sendable>:
  CoreAgentGraphCheckpointer
{
  private let modelContext: ModelContext
  private let rollsBackOnFailure: Bool

  public init(modelContext: ModelContext, rollsBackOnFailure: Bool = true) {
    self.modelContext = modelContext
    self.rollsBackOnFailure = rollsBackOnFailure
  }

  public convenience init(modelContainer: ModelContainer) {
    self.init(modelContext: ModelContext(modelContainer), rollsBackOnFailure: true)
  }

  public func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) async throws {
    let record = try CoreAgentSwiftDataGraphCheckpointRecord(
      checkpoint: checkpoint,
      saveSequence: nextCheckpointSequence()
    )
    do {
      modelContext.insert(record)
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func checkpoint(
    id: CoreAgentGraphCheckpointID
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    let checkpointID = id.rawValue
    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphCheckpointRecord> { record in
        record.checkpointID == checkpointID
      },
      sortBy: [
        SortDescriptor(\.saveSequence, order: .reverse),
        SortDescriptor(\.storedAt, order: .reverse),
        SortDescriptor(\.createdAt, order: .reverse),
      ]
    )
    let checkpoints = try modelContext.fetch(descriptor).map { record in
      try record.checkpoint(as: State.self)
    }
    guard let checkpoint = checkpoints.first else {
      return nil
    }
    return checkpoint
  }

  public func latest(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    guard let record = try checkpointRecords(
      threadID: threadID,
      namespace: namespace,
      fetchLimit: 1
    ).first else {
      return nil
    }
    return try record.checkpoint(as: State.self)
  }

  public func history(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default
  ) async throws -> [CoreAgentGraphCheckpoint<State>] {
    let records = try checkpointRecords(threadID: threadID, namespace: namespace)
    return try records.map { try $0.checkpoint(as: State.self) }
  }

  private func checkpointRecords(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    fetchLimit: Int? = nil
  ) throws -> [CoreAgentSwiftDataGraphCheckpointRecord] {
    let threadID = threadID.rawValue
    let namespace = namespace.rawValue
    let scopeKey = CoreAgentSwiftDataGraphCheckpointRecord.scopeKey(
      threadID: threadID,
      namespace: namespace
    )
    var descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphCheckpointRecord> { record in
        record.checkpointScopeKey == scopeKey
          || (record.threadID == threadID && record.namespace == namespace)
      },
      sortBy: [
        SortDescriptor(\.saveSequence, order: .reverse),
        SortDescriptor(\.storedAt, order: .reverse),
        SortDescriptor(\.createdAt, order: .reverse),
        SortDescriptor(\.checkpointID),
      ]
    )
    if let fetchLimit {
      descriptor.fetchLimit = fetchLimit
    }
    return try modelContext.fetch(descriptor)
  }

  private func nextCheckpointSequence() throws -> Int {
    var descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
      sortBy: [SortDescriptor(\.saveSequence, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return ((try modelContext.fetch(descriptor).first?.saveSequence) ?? -1) + 1
  }

  private func recoverAfterFailedMutation() {
    guard rollsBackOnFailure else {
      return
    }
    modelContext.rollback()
  }
}

@MainActor
public final class CoreAgentSwiftDataGraphStore<Value: Codable & Sendable>:
  CoreAgentGraphStore
{
  private let modelContext: ModelContext
  private let rollsBackOnFailure: Bool

  public init(modelContext: ModelContext, rollsBackOnFailure: Bool = true) {
    self.modelContext = modelContext
    self.rollsBackOnFailure = rollsBackOnFailure
  }

  public convenience init(modelContainer: ModelContainer) {
    self.init(modelContext: ModelContext(modelContainer), rollsBackOnFailure: true)
  }

  public func put(
    _ value: Value,
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) async throws {
    let graphRecord = CoreAgentGraphStoreRecord(namespace: namespace, key: key, value: value)
    let record = try CoreAgentSwiftDataGraphStoreRecord(record: graphRecord)
    do {
      let existingRecords = try storeRecords(forKey: key, namespace: namespace)
      for existing in existingRecords {
        try existing.validateIntegrity()
      }
      for existing in existingRecords {
        modelContext.delete(existing)
      }
      modelContext.insert(record)
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func value(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) async throws -> Value? {
    try await record(forKey: key, namespace: namespace)?.value
  }

  public func record(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) async throws -> CoreAgentGraphStoreRecord<Value>? {
    let graphRecords = try storeRecords(forKey: key, namespace: namespace).map { record in
      try record.graphRecord(as: Value.self)
    }
    guard let graphRecord = graphRecords.first else {
      return nil
    }
    return graphRecord
  }

  public func removeValue(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace = .default
  ) async throws {
    do {
      let records = try storeRecords(forKey: key, namespace: namespace)
      for record in records {
        try record.validateIntegrity()
      }
      for record in records {
        modelContext.delete(record)
      }
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func keys(
    namespace: CoreAgentGraphStoreNamespace = .default
  ) async throws -> [CoreAgentGraphStoreKey] {
    let namespace = namespace.rawValue
    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { record in
        record.namespace == namespace
      },
      sortBy: [
        SortDescriptor(\.key),
        SortDescriptor(\.updatedAt, order: .reverse),
      ]
    )
    var keys: Set<CoreAgentGraphStoreKey> = []
    for record in try modelContext.fetch(descriptor) {
      try record.validateIntegrity()
      keys.insert(CoreAgentGraphStoreKey(record.key))
    }
    return keys.sorted()
  }

  private func storeRecords(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) throws -> [CoreAgentSwiftDataGraphStoreRecord] {
    let namespace = namespace.rawValue
    let key = key.rawValue
    let scopeKey = CoreAgentSwiftDataGraphStoreRecord.scopeKey(namespace: namespace, key: key)
    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { record in
        record.storeScopeKey == scopeKey
          || (record.namespace == namespace && record.key == key)
      },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  private func recoverAfterFailedMutation() {
    guard rollsBackOnFailure else {
      return
    }
    modelContext.rollback()
  }
}

private enum CoreAgentSwiftDataGraphCodec {
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return try decoder.decode(type, from: data)
  }
}

private enum CoreAgentSwiftDataEngineCodec {
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return try decoder.decode(type, from: data)
  }
}

private func framed(_ fields: [String]) -> Data {
  Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func timeToken(_ date: Date) -> String {
  stableTimeToken(date)
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

public enum CoreAgentAppleExecutionCapability: String, Codable, Hashable, Sendable {
  case deterministicCodeInterpreter
  case wasiCodeInterpreter
  case helperCodeInterpreter
  case remoteCodeInterpreter
  case computerUse
  case appIntentExecution
  case appIntentDonation
  case swiftDataCheckpointPersistence
}

public enum CoreAgentAppleNetworkPolicy: String, Codable, Equatable, Sendable {
  case denied
  case localOnly
  case allowed
}

public struct CoreAgentAppleSandboxProfile: Equatable, Sendable {
  public let capabilities: Set<CoreAgentAppleExecutionCapability>
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let authorityBoundaryID: String
  public let policyVersion: Int

  public init(
    capabilities: Set<CoreAgentAppleExecutionCapability>,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    authorityBoundaryID: String = "default",
    policyVersion: Int = 1
  ) {
    self.capabilities = capabilities
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
  }

  public func allows(_ capability: CoreAgentAppleExecutionCapability) -> Bool {
    capabilities.contains(capability)
  }
}

public enum CoreAgentAppleInterpreterTier: String, Codable, Equatable, Sendable {
  case deterministicInProcess
  case wasiWebAssembly
  case helperProcess
  case remote

  var requiredCapability: CoreAgentAppleExecutionCapability {
    switch self {
    case .deterministicInProcess:
      .deterministicCodeInterpreter
    case .wasiWebAssembly:
      .wasiCodeInterpreter
    case .helperProcess:
      .helperCodeInterpreter
    case .remote:
      .remoteCodeInterpreter
    }
  }
}

public enum CoreAgentAppleExecutionRequest: Equatable, Sendable {
  case codeInterpreter(tier: CoreAgentAppleInterpreterTier)
  case codeInterpreterInvocation(
    tier: CoreAgentAppleInterpreterTier,
    programDigest: String,
    inputDigest: String
  )
  case computerUsePlan(actionID: String)
  case computerUse(actionID: String)
  case computerUseExecution(actionID: String, approvedPlanDigest: String)
  case swiftDataCheckpointPersistence(checkpointKey: String)
  case appIntentDonation(descriptor: CoreAgentAppIntentDescriptor)
  case appIntentDonationRecord(record: CoreAgentAppIntentDonationRecord)
  case appIntentDonationInvalidation(
    record: CoreAgentAppIntentDonationRecord,
    reason: CoreAgentAppIntentDonationInvalidationReason
  )
  case appIntent(
    descriptor: CoreAgentAppIntentDescriptor,
    mode: CoreAgentAppleAppIntentMode,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
}

public struct CoreAgentAppleConsentRequirement:
  Codable, Equatable, Sendable
{
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let capability: CoreAgentAppleExecutionCapability
  public let requestFingerprint: String

  public init(
    authorityBoundaryID: String,
    policyVersion: Int,
    capability: CoreAgentAppleExecutionCapability,
    requestFingerprint: String
  ) {
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.capability = capability
    self.requestFingerprint = requestFingerprint
  }
}

public struct CoreAgentAppleConsentReceipt:
  Codable, Equatable, Sendable
{
  public let id: String
  public let issuerID: String
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let capability: CoreAgentAppleExecutionCapability
  public let requestFingerprint: String
  public let grantedAt: Date
  public let expiresAt: Date?
  public let signature: String

  public init(
    id: String,
    issuerID: String,
    authorityBoundaryID: String,
    policyVersion: Int,
    capability: CoreAgentAppleExecutionCapability,
    requestFingerprint: String,
    grantedAt: Date,
    expiresAt: Date?,
    signature: String
  ) {
    self.id = id
    self.issuerID = issuerID
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.capability = capability
    self.requestFingerprint = requestFingerprint
    self.grantedAt = grantedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }

  private init(
    id: String,
    issuerID: String,
    requirement: CoreAgentAppleConsentRequirement,
    grantedAt: Date,
    expiresAt: Date,
    signature: String
  ) {
    self.init(
      id: id,
      issuerID: issuerID,
      authorityBoundaryID: requirement.authorityBoundaryID,
      policyVersion: requirement.policyVersion,
      capability: requirement.capability,
      requestFingerprint: requirement.requestFingerprint,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: signature
    )
  }

  public static func issue(
    id: String,
    issuerID: String,
    requirement: CoreAgentAppleConsentRequirement,
    signingKey: CoreAgentAppleConsentSigningKey,
    grantedAt: Date,
    expiresAt: Date
  ) -> CoreAgentAppleConsentReceipt {
    let unsigned = CoreAgentAppleConsentReceipt(
      id: id,
      issuerID: issuerID,
      requirement: requirement,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: ""
    )
    return CoreAgentAppleConsentReceipt(
      id: id,
      issuerID: issuerID,
      requirement: requirement,
      grantedAt: grantedAt,
      expiresAt: expiresAt,
      signature: unsigned.signature(signingKey: signingKey)
    )
  }

  fileprivate func verifies(with signingKey: CoreAgentAppleConsentSigningKey) -> Bool {
    guard let authenticationCode = Self.authenticationCode(from: signature) else {
      return false
    }
    return HMAC<SHA256>.isValidAuthenticationCode(
      authenticationCode,
      authenticating: signaturePayload,
      using: SymmetricKey(data: signingKey.material)
    )
  }

  private func signature(signingKey: CoreAgentAppleConsentSigningKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: signaturePayload,
      using: SymmetricKey(data: signingKey.material)
    )
    return "hmac-sha256:" + mac.map { String(format: "%02x", $0) }.joined()
  }

  private var signaturePayload: Data {
    let fields = [
      id,
      issuerID,
      authorityBoundaryID,
      String(policyVersion),
      capability.rawValue,
      requestFingerprint,
      Self.timeToken(grantedAt),
      expiresAt.map(Self.timeToken) ?? "nil",
    ]
    return Data(fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").utf8)
  }

  private static func authenticationCode(from signature: String) -> [UInt8]? {
    let prefix = "hmac-sha256:"
    guard signature.hasPrefix(prefix) else {
      return nil
    }
    let hex = signature.dropFirst(prefix.count)
    guard hex.count == 64 else {
      return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(32)
    var index = hex.startIndex
    while index < hex.endIndex {
      let nextIndex = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
        return nil
      }
      bytes.append(byte)
      index = nextIndex
    }
    return bytes.count == 32 ? bytes : nil
  }

  private static func timeToken(_ date: Date) -> String {
    stableTimeToken(date)
  }
}

public struct CoreAgentAppleConsentSigningKey: Equatable, Sendable {
  fileprivate let material: Data

  public init?(_ material: Data) {
    guard material.count >= 32 else {
      return nil
    }
    self.material = material
  }
}

private final class CoreAgentAppleConsumedConsentReceipts: @unchecked Sendable {
  private let lock = NSLock()
  private var consumedReceiptKeys: Set<String> = []

  func consume(_ key: String) -> Bool {
    lock.withLock {
      if consumedReceiptKeys.contains(key) {
        return false
      }
      consumedReceiptKeys.insert(key)
      return true
    }
  }
}

public enum CoreAgentAppleConsent: Equatable, Sendable {
  case notRequired
  case required(reason: String)
  case granted(CoreAgentAppleConsentReceipt)
}

public enum CoreAgentAppleActionGateDenial: Equatable, Sendable {
  case missingCapability(CoreAgentAppleExecutionCapability)
  case missingConsent(CoreAgentAppleExecutionCapability)
  case remoteExecutionRequiresNetworkPolicy
  case invalidConsentReceipt(String)
  case consentAuthorityBoundaryMismatch(expected: String, actual: String)
  case consentPolicyVersionMismatch(expected: Int, actual: Int)
  case consentCapabilityMismatch(
    expected: CoreAgentAppleExecutionCapability,
    actual: CoreAgentAppleExecutionCapability
  )
  case consentRequestMismatch(expected: String, actual: String)
  case expiredConsentReceipt(String)
  case missingConsentExpiry(String)
  case untrustedConsentIssuer(expected: String, actual: String)
  case invalidConsentSignature(String)
  case reusedConsentReceipt(String)
  case notYetValidConsentReceipt(String)
  case consentVerifierUnavailable(CoreAgentAppleExecutionCapability)
  case invalidAppIntentDescriptor(CoreAgentAppIntentDescriptorError)
  case unexpectedAppIntentDescriptorError(String)
  case unsupportedAppIntentMode(identifier: String, mode: CoreAgentAppleAppIntentMode)
  case unsupportedAppIntentExecutionTarget(
    identifier: String,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
  case appIntentDonationDisabled(identifier: String)
  case appIntentDonationAuthorityBoundaryMismatch(expected: String, actual: String)
  case appIntentDonationPolicyVersionMismatch(expected: Int, actual: Int)
  case appIntentExecutionTargetRequiresForeground(
    identifier: String,
    target: CoreAgentAppleAppIntentExecutionTarget
  )
}

public enum CoreAgentAppleActionGateDecision: Equatable, Sendable {
  case allowed
  case denied(CoreAgentAppleActionGateDenial)

  public var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }
}

public struct CoreAgentAppleActionGate: Sendable {
  public let sandbox: CoreAgentAppleSandboxProfile
  public let trustedConsentIssuerID: String
  private let consentSigningKey: CoreAgentAppleConsentSigningKey?
  private let consumedConsentReceipts: CoreAgentAppleConsumedConsentReceipts
  private let now: @Sendable () -> Date

  public init(
    sandbox: CoreAgentAppleSandboxProfile,
    trustedConsentIssuerID: String = "default",
    consentSigningKey: CoreAgentAppleConsentSigningKey? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sandbox = sandbox
    self.trustedConsentIssuerID = trustedConsentIssuerID
    self.consentSigningKey = consentSigningKey
    self.consumedConsentReceipts = CoreAgentAppleConsumedConsentReceipts()
    self.now = now
  }

  public func consentRequirement(
    for request: CoreAgentAppleExecutionRequest
  ) -> CoreAgentAppleConsentRequirement {
    let policy = policy(for: request)
    return CoreAgentAppleConsentRequirement(
      authorityBoundaryID: sandbox.authorityBoundaryID,
      policyVersion: sandbox.policyVersion,
      capability: policy.requiredCapability,
      requestFingerprint: policy.requestFingerprint
    )
  }

  public func evaluate(
    _ request: CoreAgentAppleExecutionRequest,
    consent: CoreAgentAppleConsent
  ) -> CoreAgentAppleActionGateDecision {
    let policy = policy(for: request)

    if let denial = policy.preflightDenial {
      return .denied(denial)
    }
    guard sandbox.allows(policy.requiredCapability) else {
      return .denied(.missingCapability(policy.requiredCapability))
    }
    guard !policy.consentRequired else {
      let requirement = CoreAgentAppleConsentRequirement(
        authorityBoundaryID: sandbox.authorityBoundaryID,
        policyVersion: sandbox.policyVersion,
        capability: policy.requiredCapability,
        requestFingerprint: policy.requestFingerprint
      )
      if let denial = validate(consent: consent, requirement: requirement) {
        return .denied(denial)
      }
      return .allowed
    }
    return .allowed
  }

  private struct RequestPolicy {
    let requiredCapability: CoreAgentAppleExecutionCapability
    let consentRequired: Bool
    let requestFingerprint: String
    let preflightDenial: CoreAgentAppleActionGateDenial?
  }

  private func policy(for request: CoreAgentAppleExecutionRequest) -> RequestPolicy {
    switch request {
    case .codeInterpreter(let tier):
      if tier == .remote && sandbox.networkPolicy != .allowed {
        return RequestPolicy(
          requiredCapability: tier.requiredCapability,
          consentRequired: true,
          requestFingerprint: fingerprint(["code", tier.rawValue]),
          preflightDenial: .remoteExecutionRequiresNetworkPolicy
        )
      }
      return RequestPolicy(
        requiredCapability: tier.requiredCapability,
        consentRequired: tier == .helperProcess || tier == .remote,
        requestFingerprint: fingerprint(["code", tier.rawValue]),
        preflightDenial: nil
      )
    case .codeInterpreterInvocation(let tier, let programDigest, let inputDigest):
      if tier == .remote && sandbox.networkPolicy != .allowed {
        return RequestPolicy(
          requiredCapability: tier.requiredCapability,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "code-invocation",
            tier.rawValue,
            programDigest,
            inputDigest,
          ]),
          preflightDenial: .remoteExecutionRequiresNetworkPolicy
        )
      }
      return RequestPolicy(
        requiredCapability: tier.requiredCapability,
        consentRequired: tier == .helperProcess || tier == .remote,
        requestFingerprint: fingerprint([
          "code-invocation",
          tier.rawValue,
          programDigest,
          inputDigest,
        ]),
        preflightDenial: nil
      )
    case .computerUsePlan(let actionID):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: false,
        requestFingerprint: fingerprint(["computer-use-plan", actionID]),
        preflightDenial: nil
      )
    case .computerUse(let actionID):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: true,
        requestFingerprint: fingerprint(["computer-use", actionID]),
        preflightDenial: nil
      )
    case .computerUseExecution(let actionID, let approvedPlanDigest):
      return RequestPolicy(
        requiredCapability: .computerUse,
        consentRequired: true,
        requestFingerprint: fingerprint(["computer-use-execution", actionID, approvedPlanDigest]),
        preflightDenial: nil
      )
    case .swiftDataCheckpointPersistence(let checkpointKey):
      return RequestPolicy(
        requiredCapability: .swiftDataCheckpointPersistence,
        consentRequired: false,
        requestFingerprint: fingerprint(["swiftdata-checkpoint", checkpointKey]),
        preflightDenial: nil
      )
    case .appIntentDonation(let descriptor):
      if let denial = appIntentDonationDenial(descriptor: descriptor) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint(["app-intent-donation", descriptor.exposureFingerprint]),
        preflightDenial: nil
      )
    case .appIntentDonationRecord(let record):
      if let denial = appIntentDonationRecordDenial(record: record) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint(["app-intent-donation-record", record.gateFingerprint]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint(["app-intent-donation-record", record.gateFingerprint]),
        preflightDenial: nil
      )
    case .appIntentDonationInvalidation(let record, let reason):
      if let denial = appIntentDonationRecordDenial(record: record) {
        return RequestPolicy(
          requiredCapability: .appIntentDonation,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "app-intent-donation-invalidation",
            record.gateFingerprint,
            reason.rawValue,
          ]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentDonation,
        consentRequired: true,
        requestFingerprint: fingerprint([
          "app-intent-donation-invalidation",
          record.gateFingerprint,
          reason.rawValue,
        ]),
        preflightDenial: nil
      )
    case .appIntent(let descriptor, let mode, let target):
      if let denial = appIntentDenial(descriptor: descriptor, mode: mode, target: target) {
        return RequestPolicy(
          requiredCapability: .appIntentExecution,
          consentRequired: true,
          requestFingerprint: fingerprint([
            "app-intent-execution",
            descriptor.exposureFingerprint,
            mode.rawValue,
            target.rawValue,
          ]),
          preflightDenial: denial
        )
      }
      return RequestPolicy(
        requiredCapability: .appIntentExecution,
        consentRequired: true,
        requestFingerprint: fingerprint([
          "app-intent-execution",
          descriptor.exposureFingerprint,
          mode.rawValue,
          target.rawValue,
        ]),
        preflightDenial: nil
      )
    }
  }

  private func appIntentDonationDenial(
    descriptor: CoreAgentAppIntentDescriptor
  ) -> CoreAgentAppleActionGateDenial? {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      return .invalidAppIntentDescriptor(error)
    } catch {
      return .unexpectedAppIntentDescriptorError(String(describing: error))
    }
    guard descriptor.donationPolicy != .doNotDonate else {
      return .appIntentDonationDisabled(identifier: descriptor.identifier)
    }
    return nil
  }

  private func appIntentDonationRecordDenial(
    record: CoreAgentAppIntentDonationRecord
  ) -> CoreAgentAppleActionGateDenial? {
    guard record.authorityBoundaryID == sandbox.authorityBoundaryID else {
      return .appIntentDonationAuthorityBoundaryMismatch(
        expected: sandbox.authorityBoundaryID,
        actual: record.authorityBoundaryID
      )
    }
    guard record.policyVersion == sandbox.policyVersion else {
      return .appIntentDonationPolicyVersionMismatch(
        expected: sandbox.policyVersion,
        actual: record.policyVersion
      )
    }
    return nil
  }

  private func appIntentDenial(
    descriptor: CoreAgentAppIntentDescriptor,
    mode: CoreAgentAppleAppIntentMode,
    target: CoreAgentAppleAppIntentExecutionTarget
  ) -> CoreAgentAppleActionGateDenial? {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      return .invalidAppIntentDescriptor(error)
    } catch {
      return .unexpectedAppIntentDescriptorError(String(describing: error))
    }
    guard descriptor.supportedModes.contains(mode) else {
      return .unsupportedAppIntentMode(identifier: descriptor.identifier, mode: mode)
    }
    guard descriptor.allowedExecutionTargets.contains(target) else {
      return .unsupportedAppIntentExecutionTarget(
        identifier: descriptor.identifier,
        target: target
      )
    }
    guard descriptor.mutability == .readOnly || target == .foreground else {
      return .appIntentExecutionTargetRequiresForeground(
        identifier: descriptor.identifier,
        target: target
      )
    }
    return nil
  }

  private func validate(
    consent: CoreAgentAppleConsent,
    requirement: CoreAgentAppleConsentRequirement
  ) -> CoreAgentAppleActionGateDenial? {
    guard case .granted(let receipt) = consent else {
      return .missingConsent(requirement.capability)
    }
    guard !receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidConsentReceipt("empty receipt id")
    }
    guard receipt.authorityBoundaryID == requirement.authorityBoundaryID else {
      return .consentAuthorityBoundaryMismatch(
        expected: requirement.authorityBoundaryID,
        actual: receipt.authorityBoundaryID
      )
    }
    guard receipt.policyVersion == requirement.policyVersion else {
      return .consentPolicyVersionMismatch(
        expected: requirement.policyVersion,
        actual: receipt.policyVersion
      )
    }
    guard receipt.capability == requirement.capability else {
      return .consentCapabilityMismatch(
        expected: requirement.capability,
        actual: receipt.capability
      )
    }
    guard receipt.requestFingerprint == requirement.requestFingerprint else {
      return .consentRequestMismatch(
        expected: requirement.requestFingerprint,
        actual: receipt.requestFingerprint
      )
    }
    guard let expiresAt = receipt.expiresAt else {
      return .missingConsentExpiry(receipt.id)
    }
    let currentTime = now()
    if receipt.grantedAt > currentTime {
      return .notYetValidConsentReceipt(receipt.id)
    }
    if expiresAt <= currentTime {
      return .expiredConsentReceipt(receipt.id)
    }
    guard receipt.issuerID == trustedConsentIssuerID else {
      return .untrustedConsentIssuer(expected: trustedConsentIssuerID, actual: receipt.issuerID)
    }
    guard let consentSigningKey else {
      return .consentVerifierUnavailable(requirement.capability)
    }
    guard receipt.verifies(with: consentSigningKey) else {
      return .invalidConsentSignature(receipt.id)
    }
    guard consumedConsentReceipts.consume(consumptionKey(receipt)) else {
      return .reusedConsentReceipt(receipt.id)
    }
    return nil
  }

  private func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }

  private func consumptionKey(_ receipt: CoreAgentAppleConsentReceipt) -> String {
    fingerprint([
      receipt.id,
      receipt.authorityBoundaryID,
      String(receipt.policyVersion),
      receipt.capability.rawValue,
      receipt.requestFingerprint,
    ])
  }
}

public enum CoreAgentAppleCodeValue:
  Codable, Equatable, Sendable, CustomStringConvertible
{
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public var description: String {
    switch self {
    case .string(let value):
      value
    case .number(let value):
      if value.isFinite && value.rounded() == value
        && value >= Double(Int64.min) && value <= Double(Int64.max)
      {
        String(Int64(value))
      } else {
        String(value)
      }
    case .bool(let value):
      value ? "true" : "false"
    case .null:
      "null"
    }
  }
}

public enum CoreAgentAppleCodeOperand: Codable, Equatable, Sendable {
  case literal(CoreAgentAppleCodeValue)
  case variable(String)
  case input(String)
}

public enum CoreAgentAppleDeterministicInstruction: Codable, Equatable, Sendable {
  case set(String, CoreAgentAppleCodeValue)
  case add(String, CoreAgentAppleCodeOperand, CoreAgentAppleCodeOperand)
  case concatenate(String, [CoreAgentAppleCodeOperand])
  case emit(CoreAgentAppleCodeOperand)
  case output(String, CoreAgentAppleCodeOperand)
}

public struct CoreAgentAppleDeterministicProgram: Codable, Equatable, Sendable {
  public let instructions: [CoreAgentAppleDeterministicInstruction]

  public init(instructions: [CoreAgentAppleDeterministicInstruction]) {
    self.instructions = instructions
  }
}

public struct CoreAgentAppleDeterministicCodeLimits: Codable, Equatable, Sendable {
  public let maxInstructionCount: Int
  public let maxOutputBytes: Int
  public let maxInputBytes: Int
  public let maxStateBytes: Int
  public let maxValueBytes: Int
  public let maxOperandCount: Int
  public let maxVariableCount: Int
  public let maxIdentifierLength: Int

  public init(
    maxInstructionCount: Int = 64,
    maxOutputBytes: Int = 64 * 1024,
    maxInputBytes: Int = 64 * 1024,
    maxStateBytes: Int = 64 * 1024,
    maxValueBytes: Int = 16 * 1024,
    maxOperandCount: Int = 32,
    maxVariableCount: Int = 128,
    maxIdentifierLength: Int = 128
  ) {
    self.maxInstructionCount = maxInstructionCount
    self.maxOutputBytes = maxOutputBytes
    self.maxInputBytes = maxInputBytes
    self.maxStateBytes = maxStateBytes
    self.maxValueBytes = maxValueBytes
    self.maxOperandCount = maxOperandCount
    self.maxVariableCount = maxVariableCount
    self.maxIdentifierLength = maxIdentifierLength
  }
}

public struct CoreAgentAppleDeterministicCodeRequest: Codable, Equatable, Sendable {
  public let id: String
  public let program: CoreAgentAppleDeterministicProgram
  public let inputs: [String: CoreAgentAppleCodeValue]
  public let limits: CoreAgentAppleDeterministicCodeLimits

  public init(
    id: String,
    program: CoreAgentAppleDeterministicProgram,
    inputs: [String: CoreAgentAppleCodeValue] = [:],
    limits: CoreAgentAppleDeterministicCodeLimits = .init()
  ) {
    self.id = id
    self.program = program
    self.inputs = inputs
    self.limits = limits
  }
}

public enum CoreAgentAppleHelperCodeInterpreterNetworkAccess:
  String, Codable, Equatable, Sendable
{
  case none
  case localOnly
  case remote
}

public enum CoreAgentAppleCodeInterpreterFailure: Equatable, Sendable {
  case cancelled
  case backendFailed
  case instructionLimitExceeded(max: Int, actual: Int)
  case outputLimitExceeded(max: Int, actual: Int)
  case inputLimitExceeded(max: Int, actual: Int)
  case stateLimitExceeded(max: Int, actual: Int)
  case valueLimitExceeded(max: Int, actual: Int)
  case operandLimitExceeded(max: Int, actual: Int)
  case variableLimitExceeded(max: Int, actual: Int)
  case undefinedValue(String)
  case typeMismatch(operation: String)
  case invalidIdentifier(String)
  case invalidOutputName(String)
  case duplicateOutputName(String)
  case nonFiniteNumber(String)
  case invalidRequest(String)
  case executableNotAllowed(String)
  case blockedExecutableName(String)
  case workingDirectoryOutsideWorkspace(String)
  case networkAccessDenied(
    requested: CoreAgentAppleHelperCodeInterpreterNetworkAccess,
    policy: CoreAgentAppleNetworkPolicy
  )
  case stdoutLimitExceeded(max: Int, actual: Int)
  case stderrLimitExceeded(max: Int, actual: Int)
  case nonZeroExitStatus(Int32)
}

public enum CoreAgentAppleCodeInterpreterStatus: Equatable, Sendable {
  case succeeded
  case denied(CoreAgentAppleActionGateDenial)
  case failed(CoreAgentAppleCodeInterpreterFailure)
}

public struct CoreAgentAppleCodeInterpreterAudit: Equatable, Sendable {
  public let requestID: String
  public let tier: CoreAgentAppleInterpreterTier
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let startedAt: Date
  public let endedAt: Date
  public let programDigest: String
  public let inputDigest: String
  public let status: CoreAgentAppleCodeInterpreterStatus
}

public struct CoreAgentAppleCodeInterpreterResult: Equatable, Sendable {
  public let status: CoreAgentAppleCodeInterpreterStatus
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]
  public let audit: CoreAgentAppleCodeInterpreterAudit
}

public struct CoreAgentAppleDeterministicCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.clock = clock
  }

  public func run(
    _ request: CoreAgentAppleDeterministicCodeRequest
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let programDigest = Self.digest(request.program)
    let inputDigest = Self.digest(request.inputs)
    let gateDecision = actionGate.evaluate(
      .codeInterpreter(tier: .deterministicInProcess),
      consent: .notRequired
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }
    if Task.isCancelled {
      return failed(
        .cancelled,
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        stdout: "",
        outputs: [:]
      )
    }
    guard request.program.instructions.count <= request.limits.maxInstructionCount else {
      return result(
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: .failed(.instructionLimitExceeded(
          max: request.limits.maxInstructionCount,
          actual: request.program.instructions.count
        )),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }
    if let failure = Self.validateRequest(request) {
      return failed(
        failure,
        request: request,
        startedAt: startedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        stdout: "",
        outputs: [:]
      )
    }

    var variables: [String: CoreAgentAppleCodeValue] = [:]
    var stdout = ""
    var outputs: [String: CoreAgentAppleCodeValue] = [:]
    for instruction in request.program.instructions {
      if Task.isCancelled {
        return failed(
          .cancelled,
          request: request,
          startedAt: startedAt,
          programDigest: programDigest,
          inputDigest: inputDigest,
          stdout: stdout,
          outputs: outputs
        )
      }
      switch instruction {
      case .set(let name, let value):
        if let failure = Self.assignmentFailure(
          name: name,
          value: value,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = value
      case .add(let name, let lhs, let rhs):
        guard case .number(let lhsValue) = resolve(lhs, variables: variables, request: request),
          case .number(let rhsValue) = resolve(rhs, variables: variables, request: request)
        else {
          return failed(
            .typeMismatch(operation: "add"),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let value = lhsValue + rhsValue
        guard value.isFinite else {
          return failed(
            .nonFiniteNumber(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let codeValue = CoreAgentAppleCodeValue.number(value)
        if let failure = Self.assignmentFailure(
          name: name,
          value: codeValue,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = codeValue
      case .concatenate(let name, let operands):
        var combined = ""
        for operand in operands {
          guard let value = resolve(operand, variables: variables, request: request) else {
            return failed(
              .undefinedValue(name),
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          if let failure = Self.valueFailure(value, label: name, limits: request.limits) {
            return failed(
              failure,
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          let actualBytes = combined.utf8.count + value.description.utf8.count
          guard actualBytes <= request.limits.maxValueBytes else {
            return failed(
              .valueLimitExceeded(max: request.limits.maxValueBytes, actual: actualBytes),
              request: request,
              startedAt: startedAt,
              programDigest: programDigest,
              inputDigest: inputDigest,
              stdout: stdout,
              outputs: outputs
            )
          }
          combined += value.description
        }
        let value = CoreAgentAppleCodeValue.string(combined)
        if let failure = Self.assignmentFailure(
          name: name,
          value: value,
          variables: variables,
          limits: request.limits
        ) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        variables[name] = value
      case .emit(let operand):
        guard let value = resolve(operand, variables: variables, request: request) else {
          return failed(
            .undefinedValue(String(describing: operand)),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        if let failure = Self.valueFailure(value, label: "emit", limits: request.limits) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        let candidate = stdout + value.description + "\n"
        let actualOutputBytes = Self.outputByteCount(stdout: candidate, outputs: outputs)
        guard actualOutputBytes <= request.limits.maxOutputBytes else {
          return failed(
            .outputLimitExceeded(max: request.limits.maxOutputBytes, actual: actualOutputBytes),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        stdout = candidate
      case .output(let name, let operand):
        guard Self.isValidOutputName(name, maxLength: request.limits.maxIdentifierLength) else {
          return failed(
            .invalidOutputName(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        guard outputs[name] == nil else {
          return failed(
            .duplicateOutputName(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        guard let value = resolve(operand, variables: variables, request: request) else {
          return failed(
            .undefinedValue(name),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        if let failure = Self.valueFailure(value, label: name, limits: request.limits) {
          return failed(
            failure,
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        var candidateOutputs = outputs
        candidateOutputs[name] = value
        let actualOutputBytes = Self.outputByteCount(stdout: stdout, outputs: candidateOutputs)
        guard actualOutputBytes <= request.limits.maxOutputBytes else {
          return failed(
            .outputLimitExceeded(max: request.limits.maxOutputBytes, actual: actualOutputBytes),
            request: request,
            startedAt: startedAt,
            programDigest: programDigest,
            inputDigest: inputDigest,
            stdout: stdout,
            outputs: outputs
          )
        }
        outputs = candidateOutputs
      }
    }
    return result(
      request: request,
      startedAt: startedAt,
      programDigest: programDigest,
      inputDigest: inputDigest,
      status: .succeeded,
      stdout: stdout,
      stderr: "",
      outputs: outputs
    )
  }

  private func resolve(
    _ operand: CoreAgentAppleCodeOperand,
    variables: [String: CoreAgentAppleCodeValue],
    request: CoreAgentAppleDeterministicCodeRequest
  ) -> CoreAgentAppleCodeValue? {
    switch operand {
    case .literal(let value):
      value
    case .variable(let name):
      variables[name]
    case .input(let name):
      request.inputs[name]
    }
  }

  private func failed(
    _ failure: CoreAgentAppleCodeInterpreterFailure,
    request: CoreAgentAppleDeterministicCodeRequest,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    stdout: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    result(
      request: request,
      startedAt: startedAt,
      programDigest: programDigest,
      inputDigest: inputDigest,
      status: .failed(failure),
      stdout: stdout,
      stderr: failure.description,
      outputs: outputs
    )
  }

  private func result(
    request: CoreAgentAppleDeterministicCodeRequest,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    let endedAt = clock()
    return CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: request.id,
        tier: .deterministicInProcess,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: endedAt,
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func validateRequest(
    _ request: CoreAgentAppleDeterministicCodeRequest
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    for (name, value) in request.inputs {
      guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
        return .invalidIdentifier("input:\(name)")
      }
      if let failure = valueFailure(value, label: "input:\(name)", limits: request.limits) {
        return failure
      }
    }
    let actualInputBytes = inputByteCount(request.inputs)
    guard actualInputBytes <= request.limits.maxInputBytes else {
      return .inputLimitExceeded(max: request.limits.maxInputBytes, actual: actualInputBytes)
    }

    for instruction in request.program.instructions {
      switch instruction {
      case .set(let name, let value):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        if let failure = valueFailure(value, label: name, limits: request.limits) {
          return failure
        }
      case .add(let name, let lhs, let rhs):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        if let failure = validateOperand(lhs, limits: request.limits) {
          return failure
        }
        if let failure = validateOperand(rhs, limits: request.limits) {
          return failure
        }
      case .concatenate(let name, let operands):
        guard isValidIdentifier(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidIdentifier(name)
        }
        guard operands.count <= request.limits.maxOperandCount else {
          return .operandLimitExceeded(
            max: request.limits.maxOperandCount,
            actual: operands.count
          )
        }
        for operand in operands {
          if let failure = validateOperand(operand, limits: request.limits) {
            return failure
          }
        }
      case .emit(let operand):
        if let failure = validateOperand(operand, limits: request.limits) {
          return failure
        }
      case .output(let name, let operand):
        guard isValidOutputName(name, maxLength: request.limits.maxIdentifierLength) else {
          return .invalidOutputName(name)
        }
        if let failure = validateOperand(operand, limits: request.limits) {
          return failure
        }
      }
    }
    return nil
  }

  private static func validateOperand(
    _ operand: CoreAgentAppleCodeOperand,
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    switch operand {
    case .literal(let value):
      valueFailure(value, label: "literal", limits: limits)
    case .variable(let name):
      isValidIdentifier(name, maxLength: limits.maxIdentifierLength)
        ? nil
        : .invalidIdentifier("variable:\(name)")
    case .input(let name):
      isValidIdentifier(name, maxLength: limits.maxIdentifierLength)
        ? nil
        : .invalidIdentifier("input:\(name)")
    }
  }

  private static func assignmentFailure(
    name: String,
    value: CoreAgentAppleCodeValue,
    variables: [String: CoreAgentAppleCodeValue],
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    if let failure = valueFailure(value, label: name, limits: limits) {
      return failure
    }
    let actualVariableCount = variables[name] == nil ? variables.count + 1 : variables.count
    guard actualVariableCount <= limits.maxVariableCount else {
      return .variableLimitExceeded(max: limits.maxVariableCount, actual: actualVariableCount)
    }
    var candidateVariables = variables
    candidateVariables[name] = value
    let actualStateBytes = stateByteCount(candidateVariables)
    guard actualStateBytes <= limits.maxStateBytes else {
      return .stateLimitExceeded(max: limits.maxStateBytes, actual: actualStateBytes)
    }
    return nil
  }

  private static func valueFailure(
    _ value: CoreAgentAppleCodeValue,
    label: String,
    limits: CoreAgentAppleDeterministicCodeLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !value.isNonFiniteNumber else {
      return .nonFiniteNumber(label)
    }
    let actualValueBytes = valueByteCount(value)
    guard actualValueBytes <= limits.maxValueBytes else {
      return .valueLimitExceeded(max: limits.maxValueBytes, actual: actualValueBytes)
    }
    return nil
  }

  private static func inputByteCount(_ inputs: [String: CoreAgentAppleCodeValue]) -> Int {
    inputs.reduce(0) { total, entry in
      total + entry.key.utf8.count + valueByteCount(entry.value)
    }
  }

  private static func stateByteCount(_ variables: [String: CoreAgentAppleCodeValue]) -> Int {
    variables.reduce(0) { total, entry in
      total + entry.key.utf8.count + valueByteCount(entry.value)
    }
  }

  private static func valueByteCount(_ value: CoreAgentAppleCodeValue) -> Int {
    value.description.utf8.count
  }

  private static func outputByteCount(
    stdout: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> Int {
    stdout.utf8.count + outputs.reduce(0) { total, entry in
      total + entry.key.utf8.count + entry.value.description.utf8.count
    }
  }

  private static func isValidIdentifier(_ name: String, maxLength: Int) -> Bool {
    guard !name.isEmpty, name.utf8.count <= maxLength else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || ("a"..."z").contains(scalar)
        || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
  }

  private static func isValidOutputName(_ name: String, maxLength: Int) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == name, !name.isEmpty, name.utf8.count <= maxLength,
      name != ".", name != ".."
    else {
      return false
    }
    guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || scalar == "-" || scalar == "."
        || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar)
    }
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

public struct CoreAgentAppleHelperCodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxArgumentCount: Int
  public let maxArgumentBytes: Int
  public let maxEnvironmentEntryCount: Int
  public let maxEnvironmentBytes: Int
  public let maxStandardInputBytes: Int
  public let maxStdoutBytes: Int
  public let maxStderrBytes: Int
  public let maxOutputBytes: Int
  public let maxOutputCount: Int
  public let maxValueBytes: Int

  public init(
    maxArgumentCount: Int = 32,
    maxArgumentBytes: Int = 16 * 1024,
    maxEnvironmentEntryCount: Int = 64,
    maxEnvironmentBytes: Int = 16 * 1024,
    maxStandardInputBytes: Int = 64 * 1024,
    maxStdoutBytes: Int = 64 * 1024,
    maxStderrBytes: Int = 64 * 1024,
    maxOutputBytes: Int = 64 * 1024,
    maxOutputCount: Int = 128,
    maxValueBytes: Int = 16 * 1024
  ) {
    self.maxArgumentCount = maxArgumentCount
    self.maxArgumentBytes = maxArgumentBytes
    self.maxEnvironmentEntryCount = maxEnvironmentEntryCount
    self.maxEnvironmentBytes = maxEnvironmentBytes
    self.maxStandardInputBytes = maxStandardInputBytes
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxOutputCount = maxOutputCount
    self.maxValueBytes = maxValueBytes
  }
}

public struct CoreAgentAppleHelperCodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectory: URL?
  public let standardInput: String
  public let networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess
  public let limits: CoreAgentAppleHelperCodeInterpreterLimits

  public init(
    id: String,
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    workingDirectory: URL? = nil,
    standardInput: String = "",
    networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess = .none,
    limits: CoreAgentAppleHelperCodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.standardInput = standardInput
    self.networkAccess = networkAccess
    self.limits = limits
  }
}

public struct CoreAgentAppleHelperCodeInterpreterPolicy: Equatable, Sendable {
  public static let defaultBlockedExecutableNames: Set<String> = [
    "bash",
    "csh",
    "fish",
    "sh",
    "tcsh",
    "zsh",
  ]

  public let allowedExecutableURLs: Set<URL>
  public let blockedExecutableNames: Set<String>

  public init(
    allowedExecutableURLs: Set<URL>,
    blockedExecutableNames: Set<String> = Self.defaultBlockedExecutableNames
  ) {
    self.allowedExecutableURLs = Set(
      allowedExecutableURLs.map(Self.canonicalFileURL(_:))
    )
    self.blockedExecutableNames = Set(blockedExecutableNames.map { $0.lowercased() })
  }

  fileprivate static func canonicalFileURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }
}

public struct CoreAgentAppleAuthorizedHelperCodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleHelperCodeInterpreterRequest
  public let canonicalExecutableURL: URL
  public let canonicalWorkingDirectory: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleHelperCodeInterpreterRequest,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalExecutableURL = canonicalExecutableURL
    self.canonicalWorkingDirectory = canonicalWorkingDirectory
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleHelperCodeInterpreterBackendResult:
  Codable, Equatable, Sendable
{
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue] = [:]
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.outputs = outputs
  }
}

public struct CoreAgentAppleHelperCodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
    ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult

  public init(
    _ run: @escaping @Sendable (
      CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
    ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
  ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleHelperCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleHelperCodeInterpreterPolicy
  public let backend: CoreAgentAppleHelperCodeInterpreterBackend
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleHelperCodeInterpreterPolicy,
    backend: CoreAgentAppleHelperCodeInterpreterBackend,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleHelperCodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(
      for: request,
      actionGate: actionGate
    )
    return actionGate.consentRequirement(for: .codeInterpreterInvocation(
      tier: .helperProcess,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    ))
  }

  public func run(
    _ request: CoreAgentAppleHelperCodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalExecutableURL = Self.canonicalFileURL(request.executableURL)
    let canonicalWorkingDirectory = Self.canonicalFileURL(
      request.workingDirectory ?? actionGate.sandbox.workspaceRoot
    )
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory
    )

    if let failure = Self.requestFailure(
      request,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory,
      policy: policy,
      sandbox: actionGate.sandbox
    ) {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    let gateDecision = actionGate.evaluate(
      .codeInterpreterInvocation(
        tier: .helperProcess,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }
    if Task.isCancelled {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
        outputs: [:]
      )
    }

    let authorizedRequest = CoreAgentAppleAuthorizedHelperCodeInterpreterRequest(
      request: request,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion,
      workspaceRoot: actionGate.sandbox.workspaceRoot,
      networkPolicy: actionGate.sandbox.networkPolicy,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    )

    let backendResult: CoreAgentAppleHelperCodeInterpreterBackendResult
    do {
      backendResult = try await backend.run(authorizedRequest)
    } catch is CancellationError {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
        outputs: [:]
      )
    } catch {
      if Task.isCancelled {
        return result(
          requestID: request.id,
          startedAt: startedAt,
          programDigest: digests.programDigest,
          inputDigest: digests.inputDigest,
          status: .failed(.cancelled),
          stdout: "",
          stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
          outputs: [:]
        )
      }
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.backendFailed),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.backendFailed.description,
        outputs: [:]
      )
    }

    if Task.isCancelled {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    }
    if backendResult.exitCode != 0 {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.nonZeroExitStatus(backendResult.exitCode)),
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    }
    if let failure = Self.backendOutputFailure(backendResult, limits: request.limits) {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }
    return result(
      requestID: request.id,
      startedAt: startedAt,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest,
      status: .succeeded,
      stdout: backendResult.stdout,
      stderr: backendResult.stderr,
      outputs: backendResult.outputs
    )
  }

  private func result(
    requestID: String,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: requestID,
        tier: .helperProcess,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleHelperCodeInterpreterRequest,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL,
    policy: CoreAgentAppleHelperCodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard isBoundedNonEmpty(request.id, maxBytes: 128) else {
      return .invalidRequest("request id")
    }
    guard request.executableURL.isFileURL, !canonicalExecutableURL.path.isEmpty else {
      return .invalidRequest("executable url")
    }
    let executableName = canonicalExecutableURL.lastPathComponent.lowercased()
    guard !policy.blockedExecutableNames.contains(executableName) else {
      return .blockedExecutableName(executableName)
    }
    guard policy.allowedExecutableURLs.contains(canonicalExecutableURL) else {
      return .executableNotAllowed(canonicalExecutableURL.path)
    }
    guard canonicalWorkingDirectory.isFileURL else {
      return .invalidRequest("working directory")
    }
    guard isInsideWorkspace(canonicalWorkingDirectory, workspaceRoot: sandbox.workspaceRoot) else {
      return .workingDirectoryOutsideWorkspace(canonicalWorkingDirectory.path)
    }
    if let failure = networkFailure(request.networkAccess, policy: sandbox.networkPolicy) {
      return failure
    }
    guard request.arguments.count <= request.limits.maxArgumentCount else {
      return .invalidRequest("argument count")
    }
    let argumentBytes = request.arguments.reduce(0) { $0 + $1.utf8.count }
    guard argumentBytes <= request.limits.maxArgumentBytes else {
      return .invalidRequest("arguments")
    }
    guard request.environment.count <= request.limits.maxEnvironmentEntryCount else {
      return .invalidRequest("environment entry count")
    }
    var environmentBytes = 0
    for (key, value) in request.environment {
      guard isEnvironmentKey(key) else {
        return .invalidRequest("environment key")
      }
      environmentBytes += key.utf8.count + value.utf8.count
    }
    guard environmentBytes <= request.limits.maxEnvironmentBytes else {
      return .invalidRequest("environment")
    }
    guard request.standardInput.utf8.count <= request.limits.maxStandardInputBytes else {
      return .inputLimitExceeded(
        max: request.limits.maxStandardInputBytes,
        actual: request.standardInput.utf8.count
      )
    }
    return nil
  }

  private static func backendOutputFailure(
    _ result: CoreAgentAppleHelperCodeInterpreterBackendResult,
    limits: CoreAgentAppleHelperCodeInterpreterLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    let stdoutBytes = result.stdout.utf8.count
    guard stdoutBytes <= limits.maxStdoutBytes else {
      return .stdoutLimitExceeded(max: limits.maxStdoutBytes, actual: stdoutBytes)
    }
    let stderrBytes = result.stderr.utf8.count
    guard stderrBytes <= limits.maxStderrBytes else {
      return .stderrLimitExceeded(max: limits.maxStderrBytes, actual: stderrBytes)
    }
    guard result.outputs.count <= limits.maxOutputCount else {
      return .outputLimitExceeded(max: limits.maxOutputCount, actual: result.outputs.count)
    }
    var outputBytes = stdoutBytes + stderrBytes
    for (name, value) in result.outputs {
      guard isValidOutputName(name) else {
        return .invalidOutputName(name)
      }
      guard !value.isNonFiniteNumber else {
        return .nonFiniteNumber(name)
      }
      let valueBytes = value.description.utf8.count
      guard valueBytes <= limits.maxValueBytes else {
        return .valueLimitExceeded(max: limits.maxValueBytes, actual: valueBytes)
      }
      outputBytes += name.utf8.count + valueBytes
    }
    guard outputBytes <= limits.maxOutputBytes else {
      return .outputLimitExceeded(max: limits.maxOutputBytes, actual: outputBytes)
    }
    return nil
  }

  private static func digests(
    for request: CoreAgentAppleHelperCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate
  ) -> (programDigest: String, inputDigest: String) {
    digests(
      for: request,
      actionGate: actionGate,
      canonicalExecutableURL: canonicalFileURL(request.executableURL),
      canonicalWorkingDirectory: canonicalFileURL(
        request.workingDirectory ?? actionGate.sandbox.workspaceRoot
      )
    )
  }

  private static func digests(
    for request: CoreAgentAppleHelperCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL
  ) -> (programDigest: String, inputDigest: String) {
    let program = ProgramDigestInput(
      executablePath: canonicalExecutableURL.path,
      arguments: request.arguments,
      environment: request.environment,
      workingDirectoryPath: canonicalWorkingDirectory.path,
      networkAccess: request.networkAccess,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion
    )
    return (
      digest(program),
      digest(InputDigestInput(standardInput: request.standardInput))
    )
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(url)
  }

  private static func networkFailure(
    _ access: CoreAgentAppleHelperCodeInterpreterNetworkAccess,
    policy: CoreAgentAppleNetworkPolicy
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    switch (access, policy) {
    case (.none, _):
      nil
    case (.localOnly, .localOnly), (.localOnly, .allowed):
      nil
    case (.remote, .allowed):
      nil
    case (.localOnly, _), (.remote, _):
      .networkAccessDenied(requested: access, policy: policy)
    }
  }

  private static func isInsideWorkspace(
    _ candidate: URL,
    workspaceRoot: URL
  ) -> Bool {
    let rootPath = canonicalFileURL(workspaceRoot).path
    let candidatePath = canonicalFileURL(candidate).path
    if rootPath == "/" {
      return true
    }
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private static func isEnvironmentKey(_ key: String) -> Bool {
    guard isBoundedNonEmpty(key, maxBytes: 128), !key.contains("=") else {
      return false
    }
    return key.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || ("a"..."z").contains(scalar)
        || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
  }

  private static func isBoundedNonEmpty(_ value: String, maxBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !value.isEmpty && value.utf8.count <= maxBytes
  }

  private static func isValidOutputName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == name, !name.isEmpty, name.utf8.count <= 128,
      name != ".", name != ".."
    else {
      return false
    }
    guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || scalar == "-" || scalar == "."
        || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar)
    }
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }

  private struct ProgramDigestInput: Encodable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String
    let networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess
    let authorityBoundaryID: String
    let policyVersion: Int
  }

  private struct InputDigestInput: Encodable {
    let standardInput: String
  }
}

private extension CoreAgentAppleCodeValue {
  var isNonFiniteNumber: Bool {
    if case .number(let value) = self {
      return !value.isFinite
    }
    return false
  }
}

private extension CoreAgentAppleCodeInterpreterFailure {
  var description: String {
    switch self {
    case .cancelled:
      "cancelled"
    case .backendFailed:
      "backend failed"
    case .instructionLimitExceeded(let max, let actual):
      "instruction limit exceeded: max=\(max) actual=\(actual)"
    case .outputLimitExceeded(let max, let actual):
      "output limit exceeded: max=\(max) actual=\(actual)"
    case .inputLimitExceeded(let max, let actual):
      "input limit exceeded: max=\(max) actual=\(actual)"
    case .stateLimitExceeded(let max, let actual):
      "state limit exceeded: max=\(max) actual=\(actual)"
    case .valueLimitExceeded(let max, let actual):
      "value limit exceeded: max=\(max) actual=\(actual)"
    case .operandLimitExceeded(let max, let actual):
      "operand limit exceeded: max=\(max) actual=\(actual)"
    case .variableLimitExceeded(let max, let actual):
      "variable limit exceeded: max=\(max) actual=\(actual)"
    case .undefinedValue(let name):
      "undefined value: \(name)"
    case .typeMismatch(let operation):
      "type mismatch for operation: \(operation)"
    case .invalidIdentifier(let name):
      "invalid identifier: \(name)"
    case .invalidOutputName(let name):
      "invalid output name: \(name)"
    case .duplicateOutputName(let name):
      "duplicate output name: \(name)"
    case .nonFiniteNumber(let name):
      "non-finite number: \(name)"
    case .invalidRequest(let reason):
      "invalid request: \(reason)"
    case .executableNotAllowed(let path):
      "executable not allowed: \(path)"
    case .blockedExecutableName(let name):
      "blocked executable name: \(name)"
    case .workingDirectoryOutsideWorkspace(let path):
      "working directory outside workspace: \(path)"
    case .networkAccessDenied(let requested, let policy):
      "network access denied: requested=\(requested.rawValue) policy=\(policy.rawValue)"
    case .stdoutLimitExceeded(let max, let actual):
      "stdout limit exceeded: max=\(max) actual=\(actual)"
    case .stderrLimitExceeded(let max, let actual):
      "stderr limit exceeded: max=\(max) actual=\(actual)"
    case .nonZeroExitStatus(let exitCode):
      "non-zero exit status: \(exitCode)"
    }
  }
}


public struct CoreAgentAppleWASICodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxModuleBytes: Int
  public let maxStandardInputBytes: Int
  public let maxStdoutBytes: Int
  public let maxStderrBytes: Int
  public let maxOutputBytes: Int
  public let maxOutputCount: Int

  public init(
    maxModuleBytes: Int = 8 * 1024 * 1024,
    maxStandardInputBytes: Int = 64 * 1024,
    maxStdoutBytes: Int = 64 * 1024,
    maxStderrBytes: Int = 64 * 1024,
    maxOutputBytes: Int = 64 * 1024,
    maxOutputCount: Int = 128
  ) {
    self.maxModuleBytes = maxModuleBytes
    self.maxStandardInputBytes = maxStandardInputBytes
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxOutputCount = maxOutputCount
  }
}

public struct CoreAgentAppleWASICodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let moduleURL: URL
  public let entrypoint: String
  public let standardInput: String
  public let limits: CoreAgentAppleWASICodeInterpreterLimits

  public init(
    id: String,
    moduleURL: URL,
    entrypoint: String = "_start",
    standardInput: String = "",
    limits: CoreAgentAppleWASICodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.moduleURL = moduleURL
    self.entrypoint = entrypoint
    self.standardInput = standardInput
    self.limits = limits
  }
}

public struct CoreAgentAppleWASICodeInterpreterPolicy: Equatable, Sendable {
  public let allowedModuleURLs: Set<URL>

  public init(allowedModuleURLs: Set<URL>) {
    self.allowedModuleURLs = Set(
      allowedModuleURLs.map(CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(_:))
    )
  }
}

public struct CoreAgentAppleAuthorizedWASICodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleWASICodeInterpreterRequest
  public let canonicalModuleURL: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleWASICodeInterpreterRequest,
    canonicalModuleURL: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalModuleURL = canonicalModuleURL
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleWASICodeInterpreterBackendResult:
  Codable, Equatable, Sendable
{
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue] = [:]
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.outputs = outputs
  }
}

public struct CoreAgentAppleWASICodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedWASICodeInterpreterRequest
    ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult

  public init(
    _ run: @escaping @Sendable (
      CoreAgentAppleAuthorizedWASICodeInterpreterRequest
    ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedWASICodeInterpreterRequest
  ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleWASICodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleWASICodeInterpreterPolicy
  public let backend: CoreAgentAppleWASICodeInterpreterBackend?
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleWASICodeInterpreterPolicy,
    backend: CoreAgentAppleWASICodeInterpreterBackend? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleWASICodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(for: request, actionGate: actionGate)
    return actionGate.consentRequirement(for: .codeInterpreterInvocation(
      tier: .wasiWebAssembly,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    ))
  }

  public func run(
    _ request: CoreAgentAppleWASICodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalModuleURL = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(
      request.moduleURL
    )
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalModuleURL: canonicalModuleURL
    )

    if let failure = Self.requestFailure(
      request,
      canonicalModuleURL: canonicalModuleURL,
      policy: policy,
      sandbox: actionGate.sandbox
    ) {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    guard let backend else {
      let failure = CoreAgentAppleCodeInterpreterFailure.invalidRequest(
        "wasi backend unavailable"
      )
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    let gateDecision = actionGate.evaluate(
      .codeInterpreterInvocation(
        tier: .wasiWebAssembly,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }

    let authorized = CoreAgentAppleAuthorizedWASICodeInterpreterRequest(
      request: request,
      canonicalModuleURL: canonicalModuleURL,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion,
      workspaceRoot: actionGate.sandbox.workspaceRoot,
      networkPolicy: actionGate.sandbox.networkPolicy,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    )

    do {
      let backendResult = try await backend.run(authorized)
      if backendResult.exitCode != 0 {
        let failure = CoreAgentAppleCodeInterpreterFailure.nonZeroExitStatus(
          backendResult.exitCode
        )
        return result(
          requestID: request.id,
          startedAt: startedAt,
          programDigest: digests.programDigest,
          inputDigest: digests.inputDigest,
          status: .failed(failure),
          stdout: backendResult.stdout,
          stderr: backendResult.stderr,
          outputs: backendResult.outputs
        )
      }
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .succeeded,
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    } catch {
      let failure = CoreAgentAppleCodeInterpreterFailure.backendFailed
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }
  }

  private func result(
    requestID: String,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: requestID,
        tier: .wasiWebAssembly,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleWASICodeInterpreterRequest,
    canonicalModuleURL: URL,
    policy: CoreAgentAppleWASICodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("request id is empty")
    }
    guard !request.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("entrypoint is empty")
    }
    guard policy.allowedModuleURLs.contains(canonicalModuleURL) else {
      return .invalidRequest("module not allowed")
    }
    guard isInsideWorkspace(canonicalModuleURL, workspaceRoot: sandbox.workspaceRoot) else {
      return .workingDirectoryOutsideWorkspace(canonicalModuleURL.path)
    }
    guard request.standardInput.utf8.count <= request.limits.maxStandardInputBytes else {
      return .inputLimitExceeded(
        max: request.limits.maxStandardInputBytes,
        actual: request.standardInput.utf8.count
      )
    }
    return nil
  }

  private static func digests(
    for request: CoreAgentAppleWASICodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalModuleURL: URL? = nil
  ) -> (programDigest: String, inputDigest: String) {
    let moduleURL = canonicalModuleURL
      ?? CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(request.moduleURL)
    let programPayload: [String: String] = [
      "authority_boundary_id": actionGate.sandbox.authorityBoundaryID,
      "entrypoint": request.entrypoint,
      "module_path": moduleURL.path,
      "policy_version": String(actionGate.sandbox.policyVersion),
      "tier": CoreAgentAppleInterpreterTier.wasiWebAssembly.rawValue,
    ]
    let inputPayload: [String: String] = [
      "request_id": request.id,
      "stdin_digest": sha256Digest(request.standardInput),
    ]
    return (
      programDigest: canonicalJSONDigest(programPayload),
      inputDigest: canonicalJSONDigest(inputPayload)
    )
  }

  private static func isInsideWorkspace(_ url: URL, workspaceRoot: URL) -> Bool {
    let root = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(workspaceRoot)
    let candidate = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(url)
    let rootPath = root.path(percentEncoded: false)
    let candidatePath = candidate.path(percentEncoded: false)
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
  }

  private static func sha256Digest(_ value: String) -> String {
    "sha256:" + sha256Hex(Data(value.utf8))
  }

  private static func canonicalJSONDigest(_ payload: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(payload)
    return "sha256:" + sha256Hex(data)
  }
}


public struct CoreAgentAppleRemoteCodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxStandardInputBytes: Int
  public let maxStandardOutputBytes: Int
  public let maxStandardErrorBytes: Int
  public let maxTypedOutputBytes: Int

  public init(
    maxStandardInputBytes: Int = 65_536,
    maxStandardOutputBytes: Int = 65_536,
    maxStandardErrorBytes: Int = 65_536,
    maxTypedOutputBytes: Int = 65_536
  ) {
    self.maxStandardInputBytes = max(0, maxStandardInputBytes)
    self.maxStandardOutputBytes = max(0, maxStandardOutputBytes)
    self.maxStandardErrorBytes = max(0, maxStandardErrorBytes)
    self.maxTypedOutputBytes = max(0, maxTypedOutputBytes)
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let endpointURL: URL
  public let standardInput: String
  public let limits: CoreAgentAppleRemoteCodeInterpreterLimits

  public init(
    id: String,
    endpointURL: URL,
    standardInput: String = "",
    limits: CoreAgentAppleRemoteCodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.endpointURL = endpointURL
    self.standardInput = standardInput
    self.limits = limits
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterPolicy: Equatable, Sendable {
  public let allowedEndpointURLs: Set<URL>

  public init(allowedEndpointURLs: Set<URL>) {
    self.allowedEndpointURLs = Set(
      allowedEndpointURLs.map { $0.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) }
        .compactMap { URL(string: $0) }
    )
  }
}

public struct CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleRemoteCodeInterpreterRequest
  public let canonicalEndpointURL: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleRemoteCodeInterpreterRequest,
    canonicalEndpointURL: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalEndpointURL = canonicalEndpointURL
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterBackendResult:
  Codable, Equatable, Sendable
{
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue] = [:]
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.outputs = outputs
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
    ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult

  public init(
    _ run: @escaping @Sendable (
      CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
    ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
  ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleRemoteCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleRemoteCodeInterpreterPolicy
  public let backend: CoreAgentAppleRemoteCodeInterpreterBackend?
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleRemoteCodeInterpreterPolicy,
    backend: CoreAgentAppleRemoteCodeInterpreterBackend? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleRemoteCodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(for: request, actionGate: actionGate)
    return actionGate.consentRequirement(for: .codeInterpreterInvocation(
      tier: .remote,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    ))
  }

  public func run(
    _ request: CoreAgentAppleRemoteCodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalEndpointURL = request.endpointURL
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalEndpointURL: canonicalEndpointURL
    )

    if let failure = Self.requestFailure(
      request,
      canonicalEndpointURL: canonicalEndpointURL,
      policy: policy,
      sandbox: actionGate.sandbox
    ) {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    guard let backend else {
      let failure = CoreAgentAppleCodeInterpreterFailure.invalidRequest(
        "remote backend unavailable"
      )
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    let gateDecision = actionGate.evaluate(
      .codeInterpreterInvocation(
        tier: .remote,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }

    let authorized = CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest(
      request: request,
      canonicalEndpointURL: canonicalEndpointURL,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion,
      workspaceRoot: actionGate.sandbox.workspaceRoot,
      networkPolicy: actionGate.sandbox.networkPolicy,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    )

    do {
      let backendResult = try await backend.run(authorized)
      if backendResult.exitCode != 0 {
        let failure = CoreAgentAppleCodeInterpreterFailure.nonZeroExitStatus(
          backendResult.exitCode
        )
        return result(
          requestID: request.id,
          startedAt: startedAt,
          programDigest: digests.programDigest,
          inputDigest: digests.inputDigest,
          status: .failed(failure),
          stdout: backendResult.stdout,
          stderr: backendResult.stderr,
          outputs: backendResult.outputs
        )
      }
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .succeeded,
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    } catch {
      let failure = CoreAgentAppleCodeInterpreterFailure.backendFailed
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }
  }

  private func result(
    requestID: String,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: requestID,
        tier: .remote,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleRemoteCodeInterpreterRequest,
    canonicalEndpointURL: URL,
    policy: CoreAgentAppleRemoteCodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("request id is empty")
    }
    guard let scheme = canonicalEndpointURL.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      return .invalidRequest("endpoint must use http or https")
    }
    guard policy.allowedEndpointURLs.contains(canonicalEndpointURL) else {
      return .invalidRequest("endpoint not allowed")
    }
    if sandbox.networkPolicy != .allowed {
      return .invalidRequest("remote execution requires allowed network policy")
    }
    guard request.standardInput.utf8.count <= request.limits.maxStandardInputBytes else {
      return .inputLimitExceeded(
        max: request.limits.maxStandardInputBytes,
        actual: request.standardInput.utf8.count
      )
    }
    return nil
  }

  private static func digests(
    for request: CoreAgentAppleRemoteCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalEndpointURL: URL? = nil
  ) -> (programDigest: String, inputDigest: String) {
    let endpointURL = canonicalEndpointURL ?? request.endpointURL
    let programPayload: [String: String] = [
      "authority_boundary_id": actionGate.sandbox.authorityBoundaryID,
      "endpoint": endpointURL.absoluteString,
      "policy_version": String(actionGate.sandbox.policyVersion),
      "tier": CoreAgentAppleInterpreterTier.remote.rawValue,
    ]
    let inputPayload: [String: String] = [
      "request_id": request.id,
      "stdin_digest": sha256Digest(request.standardInput),
    ]
    return (
      programDigest: canonicalJSONDigest(programPayload),
      inputDigest: canonicalJSONDigest(inputPayload)
    )
  }

  private static func sha256Digest(_ value: String) -> String {
    "sha256:" + sha256Hex(Data(value.utf8))
  }

  private static func canonicalJSONDigest(_ payload: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(payload)
    return "sha256:" + sha256Hex(data)
  }
}

public enum CoreAgentAppleComputerUseMode: String, Codable, Equatable, Sendable {
  case dryRun
  case execute
}

public struct CoreAgentAppleComputerUseRequest: Codable, Equatable, Sendable {
  public let id: String
  public let actionID: String
  public let mode: CoreAgentAppleComputerUseMode
  public let approvedPlan: CoreAgentAppleComputerUsePlan?
  public let approvedPlanDigest: String?

  public init(
    id: String,
    actionID: String,
    mode: CoreAgentAppleComputerUseMode,
    approvedPlan: CoreAgentAppleComputerUsePlan? = nil,
    approvedPlanDigest: String? = nil
  ) {
    self.id = id
    self.actionID = actionID
    self.mode = mode
    self.approvedPlan = approvedPlan
    self.approvedPlanDigest = approvedPlanDigest ?? approvedPlan?.digest
  }
}

public enum CoreAgentAppleComputerUseEvidenceKind: String, Codable, Hashable, Sendable {
  case screenshotDigest
  case accessibilityTreeDigest
  case userVisibleStateDigest
}

public struct CoreAgentAppleComputerUsePlanStep: Codable, Equatable, Sendable {
  public let id: String
  public let summary: String

  public init(id: String, summary: String) {
    self.id = id
    self.summary = summary
  }
}

public struct CoreAgentAppleComputerUsePlan: Codable, Equatable, Sendable {
  public let steps: [CoreAgentAppleComputerUsePlanStep]
  public let requiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]

  public var digest: String {
    Self.digest(self)
  }

  public init(
    steps: [CoreAgentAppleComputerUsePlanStep],
    requiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) {
    self.steps = steps
    self.requiredEvidence = requiredEvidence
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

public struct CoreAgentAppleComputerUseEvidence: Codable, Equatable, Sendable {
  public let kind: CoreAgentAppleComputerUseEvidenceKind
  public let digest: String
  public let capturedAt: Date

  public init(
    kind: CoreAgentAppleComputerUseEvidenceKind,
    digest: String,
    capturedAt: Date
  ) {
    self.kind = kind
    self.digest = digest
    self.capturedAt = capturedAt
  }
}

public struct CoreAgentAppleComputerUseBackend: Sendable {
  private let planHandler:
    @Sendable (CoreAgentAppleComputerUseRequest) async throws -> CoreAgentAppleComputerUsePlan
  private let executeHandler:
    @Sendable (
      CoreAgentAppleComputerUseRequest,
      CoreAgentAppleComputerUsePlan
    ) async throws -> [CoreAgentAppleComputerUseEvidence]

  public init(
    plan: @escaping @Sendable (
      CoreAgentAppleComputerUseRequest
    ) async throws -> CoreAgentAppleComputerUsePlan,
    execute: @escaping @Sendable (
      CoreAgentAppleComputerUseRequest,
      CoreAgentAppleComputerUsePlan
    ) async throws -> [CoreAgentAppleComputerUseEvidence]
  ) {
    self.planHandler = plan
    self.executeHandler = execute
  }

  public func plan(
    _ request: CoreAgentAppleComputerUseRequest
  ) async throws -> CoreAgentAppleComputerUsePlan {
    try await planHandler(request)
  }

  public func execute(
    _ request: CoreAgentAppleComputerUseRequest,
    plan: CoreAgentAppleComputerUsePlan
  ) async throws -> [CoreAgentAppleComputerUseEvidence] {
    try await executeHandler(request, plan)
  }
}

public enum CoreAgentAppleComputerUseFailure: Equatable, Sendable {
  case cancelled
  case backendFailed
  case missingApprovedPlan
  case unapprovedPlanDigest
  case approvedPlanDigestMismatch
  case invalidRequest(String)
  case invalidPlan(String)
  case invalidEvidenceDigest(kind: CoreAgentAppleComputerUseEvidenceKind)
  case missingEvidence(kind: CoreAgentAppleComputerUseEvidenceKind)
}

public enum CoreAgentAppleComputerUseStatus: Equatable, Sendable {
  case planned
  case executed
  case denied(CoreAgentAppleActionGateDenial)
  case failed(CoreAgentAppleComputerUseFailure)
}

public struct CoreAgentAppleComputerUseAudit: Equatable, Sendable {
  public let requestID: String
  public let actionID: String
  public let mode: CoreAgentAppleComputerUseMode
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let startedAt: Date
  public let endedAt: Date
  public let planDigest: String?
  public let evidenceDigest: String?
  public let status: CoreAgentAppleComputerUseStatus
}

public struct CoreAgentAppleComputerUseResult: Equatable, Sendable {
  public let status: CoreAgentAppleComputerUseStatus
  public let plan: CoreAgentAppleComputerUsePlan?
  public let evidence: [CoreAgentAppleComputerUseEvidence]
  public let audit: CoreAgentAppleComputerUseAudit
}

public struct CoreAgentAppleComputerUseExecutor: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let backend: CoreAgentAppleComputerUseBackend
  public let minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  private let approvedPlans = CoreAgentAppleComputerUseApprovedPlans()
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    backend: CoreAgentAppleComputerUseBackend,
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind] = [.screenshotDigest],
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.backend = backend
    self.minimumRequiredEvidence = Self.canonicalMinimumEvidence(minimumRequiredEvidence)
    self.clock = clock
  }

  public func run(
    _ request: CoreAgentAppleComputerUseRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleComputerUseResult {
    let startedAt = clock()
    if let failure = Self.requestFailure(request) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(failure)
      )
    }
    if request.mode == .execute {
      guard let approvedPlan = request.approvedPlan,
        let approvedPlanDigest = request.approvedPlanDigest
      else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: nil,
          evidence: [],
          status: .failed(.missingApprovedPlan)
        )
      }
      guard approvedPlan.digest == approvedPlanDigest else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(.approvedPlanDigestMismatch)
        )
      }
      if let failure = Self.planFailure(
        approvedPlan,
        minimumRequiredEvidence: minimumRequiredEvidence
      ) {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(failure)
        )
      }
      guard approvedPlans.contains(actionID: request.actionID, digest: approvedPlanDigest) else {
        return result(
          request: request,
          startedAt: startedAt,
          plan: approvedPlan,
          evidence: [],
          status: .failed(.unapprovedPlanDigest)
        )
      }
      return await executeApprovedPlan(
        request,
        plan: approvedPlan,
        approvedPlanDigest: approvedPlanDigest,
        consent: consent,
        startedAt: startedAt
      )
    }

    let gateRequest: CoreAgentAppleExecutionRequest =
      .computerUsePlan(actionID: request.actionID)
    let gateDecision = actionGate.evaluate(
      gateRequest,
      consent: .notRequired
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .denied(denial)
      )
    }
    guard !Task.isCancelled else {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.cancelled)
      )
    }

    let plan: CoreAgentAppleComputerUsePlan
    do {
      plan = try await backend.plan(request)
    } catch is CancellationError {
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.cancelled)
      )
    } catch {
      if Task.isCancelled {
        return result(
          request: request,
          startedAt: startedAt,
          plan: nil,
          evidence: [],
          status: .failed(.cancelled)
        )
      }
      return result(
        request: request,
        startedAt: startedAt,
        plan: nil,
        evidence: [],
        status: .failed(.backendFailed)
      )
    }
    if let failure = Self.planFailure(
      plan,
      minimumRequiredEvidence: minimumRequiredEvidence
    ) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(failure)
      )
    }
    approvedPlans.record(actionID: request.actionID, digest: plan.digest)
    return result(
      request: request,
      startedAt: startedAt,
      plan: plan,
      evidence: [],
      status: .planned
    )
  }

  private func executeApprovedPlan(
    _ request: CoreAgentAppleComputerUseRequest,
    plan: CoreAgentAppleComputerUsePlan,
    approvedPlanDigest: String,
    consent: CoreAgentAppleConsent,
    startedAt: Date
  ) async -> CoreAgentAppleComputerUseResult {
    let gateDecision = actionGate.evaluate(
      .computerUseExecution(
        actionID: request.actionID,
        approvedPlanDigest: approvedPlanDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .denied(denial)
      )
    }
    guard !Task.isCancelled else {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.cancelled)
      )
    }

    let evidence: [CoreAgentAppleComputerUseEvidence]
    do {
      evidence = try await backend.execute(request, plan: plan)
    } catch is CancellationError {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.cancelled)
      )
    } catch {
      if Task.isCancelled {
        return result(
          request: request,
          startedAt: startedAt,
          plan: plan,
          evidence: [],
          status: .failed(.cancelled)
        )
      }
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: [],
        status: .failed(.backendFailed)
      )
    }
    if Task.isCancelled {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: evidence,
        status: .failed(.cancelled)
      )
    }
    if let failure = Self.evidenceFailure(
      plan: plan,
      evidence: evidence,
      minimumRequiredEvidence: minimumRequiredEvidence
    ) {
      return result(
        request: request,
        startedAt: startedAt,
        plan: plan,
        evidence: evidence,
        status: .failed(failure)
      )
    }
    return result(
      request: request,
      startedAt: startedAt,
      plan: plan,
      evidence: evidence,
      status: .executed
    )
  }

  private func result(
    request: CoreAgentAppleComputerUseRequest,
    startedAt: Date,
    plan: CoreAgentAppleComputerUsePlan?,
    evidence: [CoreAgentAppleComputerUseEvidence],
    status: CoreAgentAppleComputerUseStatus
  ) -> CoreAgentAppleComputerUseResult {
    CoreAgentAppleComputerUseResult(
      status: status,
      plan: plan,
      evidence: evidence,
      audit: CoreAgentAppleComputerUseAudit(
        requestID: request.id,
        actionID: request.actionID,
        mode: request.mode,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        planDigest: plan?.digest,
        evidenceDigest: evidence.isEmpty ? nil : Self.digest(evidence),
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleComputerUseRequest
  ) -> CoreAgentAppleComputerUseFailure? {
    guard isBoundedNonEmpty(request.id, maxBytes: 128) else {
      return .invalidRequest("request id")
    }
    guard isBoundedNonEmpty(request.actionID, maxBytes: 256) else {
      return .invalidRequest("action id")
    }
    return nil
  }

  private static func canonicalMinimumEvidence(
    _ configured: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> [CoreAgentAppleComputerUseEvidenceKind] {
    Array(Set(configured).union([.screenshotDigest])).sorted { $0.rawValue < $1.rawValue }
  }

  private static func planFailure(
    _ plan: CoreAgentAppleComputerUsePlan,
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> CoreAgentAppleComputerUseFailure? {
    guard !plan.steps.isEmpty, plan.steps.count <= 32 else {
      return .invalidPlan("step count")
    }
    var stepIDs: Set<String> = []
    for step in plan.steps {
      guard isBoundedNonEmpty(step.id, maxBytes: 128) else {
        return .invalidPlan("step id")
      }
      guard isBoundedNonEmpty(step.summary, maxBytes: 2048) else {
        return .invalidPlan("step summary")
      }
      guard stepIDs.insert(step.id).inserted else {
        return .invalidPlan("duplicate step id")
      }
    }
    guard plan.requiredEvidence.count <= 8 else {
      return .invalidPlan("evidence requirement count")
    }
    guard Set(plan.requiredEvidence).count == plan.requiredEvidence.count else {
      return .invalidPlan("duplicate evidence requirement")
    }
    for requiredKind in minimumRequiredEvidence
    where !plan.requiredEvidence.contains(requiredKind) {
      return .invalidPlan("missing baseline evidence")
    }
    return nil
  }

  private static func evidenceFailure(
    plan: CoreAgentAppleComputerUsePlan,
    evidence: [CoreAgentAppleComputerUseEvidence],
    minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind]
  ) -> CoreAgentAppleComputerUseFailure? {
    for item in evidence where !isSHA256Digest(item.digest) {
      return .invalidEvidenceDigest(kind: item.kind)
    }
    let requiredKinds = Array(Set(plan.requiredEvidence).union(minimumRequiredEvidence))
    for requiredKind in requiredKinds
    where !evidence.contains(where: { $0.kind == requiredKind }) {
      return .missingEvidence(kind: requiredKind)
    }
    return nil
  }

  private static func isSHA256Digest(_ digest: String) -> Bool {
    let prefix = "sha256:"
    guard digest.hasPrefix(prefix), digest.count == prefix.count + 64 else {
      return false
    }
    return digest.dropFirst(prefix.count).allSatisfy { character in
      guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
        return false
      }
      return (48...57).contains(scalar.value)
        || (65...70).contains(scalar.value)
        || (97...102).contains(scalar.value)
    }
  }

  private static func isBoundedNonEmpty(_ value: String, maxBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !value.isEmpty && value.utf8.count <= maxBytes
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }
}

private final class CoreAgentAppleComputerUseApprovedPlans: @unchecked Sendable {
  private let lock = NSLock()
  private let maxEntryCount = 4_096
  private var approvedPlanKeys: Set<String> = []
  private var approvedPlanOrder: [String] = []

  func record(actionID: String, digest: String) {
    lock.withLock {
      let planKey = key(actionID: actionID, digest: digest)
      guard approvedPlanKeys.insert(planKey).inserted else {
        return
      }
      approvedPlanOrder.append(planKey)
      while approvedPlanOrder.count > maxEntryCount {
        approvedPlanKeys.remove(approvedPlanOrder.removeFirst())
      }
    }
  }

  func contains(actionID: String, digest: String) -> Bool {
    lock.withLock {
      approvedPlanKeys.contains(key(actionID: actionID, digest: digest))
    }
  }

  private func key(actionID: String, digest: String) -> String {
    "\(actionID.utf8.count):\(actionID)|\(digest.utf8.count):\(digest)"
  }
}

public enum CoreAgentAppIntentMutability: String, Codable, Equatable, Sendable {
  case readOnly
  case mutating
  case destructive
}

public enum CoreAgentAppleAppIntentExecutionTarget: String, Codable, Hashable, Sendable {
  case foreground
  case background
}

public enum CoreAgentAppleAppIntentMode: String, Codable, Hashable, Sendable {
  case app
  case siri
  case shortcuts
  case spotlight
}

public enum CoreAgentAppIntentDonationPolicy: String, Codable, Equatable, Sendable {
  case doNotDonate
  case donateAfterUserInitiatedAction
}

public enum CoreAgentAppIntentDescriptorError: Error, Equatable, Sendable {
  case missingExecutionTarget(identifier: String)
  case missingSupportedMode(identifier: String)
  case agentExposureRequired(identifier: String)
  case authorizationRequired(identifier: String)
  case hitlRequired(identifier: String)
  case foregroundExecutionRequired(identifier: String)
}

public struct CoreAgentAppIntentDescriptor: Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let mutability: CoreAgentAppIntentMutability
  public let exposureRevision: String
  public let allowsAgentExecution: Bool
  public let allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>
  public let supportedModes: Set<CoreAgentAppleAppIntentMode>
  public let donationPolicy: CoreAgentAppIntentDonationPolicy
  public let requiresAuthorization: Bool
  public let requiresHITLForSensitiveOperations: Bool

  public init(
    identifier: String,
    title: String,
    mutability: CoreAgentAppIntentMutability,
    exposureRevision: String = "1",
    allowsAgentExecution: Bool,
    allowedExecutionTargets: Set<CoreAgentAppleAppIntentExecutionTarget>,
    supportedModes: Set<CoreAgentAppleAppIntentMode>,
    donationPolicy: CoreAgentAppIntentDonationPolicy,
    requiresAuthorization: Bool,
    requiresHITLForSensitiveOperations: Bool
  ) {
    self.identifier = identifier
    self.title = title
    self.mutability = mutability
    self.exposureRevision = exposureRevision
    self.allowsAgentExecution = allowsAgentExecution
    self.allowedExecutionTargets = allowedExecutionTargets
    self.supportedModes = supportedModes
    self.donationPolicy = donationPolicy
    self.requiresAuthorization = requiresAuthorization
    self.requiresHITLForSensitiveOperations = requiresHITLForSensitiveOperations
  }

  public func validatedForAgentExposure() throws -> Self {
    guard !allowedExecutionTargets.isEmpty else {
      throw CoreAgentAppIntentDescriptorError.missingExecutionTarget(identifier: identifier)
    }
    guard !supportedModes.isEmpty else {
      throw CoreAgentAppIntentDescriptorError.missingSupportedMode(identifier: identifier)
    }
    guard allowsAgentExecution else {
      throw CoreAgentAppIntentDescriptorError.agentExposureRequired(identifier: identifier)
    }
    guard mutability == .readOnly || requiresAuthorization else {
      throw CoreAgentAppIntentDescriptorError.authorizationRequired(identifier: identifier)
    }
    guard mutability == .readOnly || requiresHITLForSensitiveOperations else {
      throw CoreAgentAppIntentDescriptorError.hitlRequired(identifier: identifier)
    }
    guard mutability == .readOnly || allowedExecutionTargets.contains(.foreground) else {
      throw CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(identifier: identifier)
    }
    return self
  }

  public var exposureFingerprint: String {
    Self.fingerprint([
      identifier,
      title,
      mutability.rawValue,
      exposureRevision,
      allowsAgentExecution ? "agent-exposed" : "not-agent-exposed",
      allowedExecutionTargets.map(\.rawValue).sorted().joined(separator: ","),
      supportedModes.map(\.rawValue).sorted().joined(separator: ","),
      donationPolicy.rawValue,
      requiresAuthorization ? "requires-authorization" : "no-authorization",
      requiresHITLForSensitiveOperations ? "requires-hitl" : "no-hitl",
    ])
  }

  private static func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

public enum CoreAgentAppIntentDonationSubjectKind:
  String, Codable, Equatable, Hashable, Sendable
{
  case workflowOutcome
  case stableEntity
  case runOutcome
  case traceIssue
  case memoryRecord
  case promptText
  case toolArguments
  case transientToolCall

  var isDonationAllowed: Bool {
    switch self {
    case .workflowOutcome, .stableEntity, .runOutcome, .traceIssue, .memoryRecord:
      true
    case .promptText, .toolArguments, .transientToolCall:
      false
    }
  }
}

public struct CoreAgentAppIntentDonationSubject:
  Codable, Equatable, Hashable, Sendable
{
  public let kind: CoreAgentAppIntentDonationSubjectKind
  public let stableIdentifier: String
  public let scopeID: String

  public init(
    kind: CoreAgentAppIntentDonationSubjectKind,
    stableIdentifier: String,
    scopeID: String
  ) {
    self.kind = kind
    self.stableIdentifier = stableIdentifier
    self.scopeID = scopeID
  }

  func validatedForDonation() throws -> Self {
    guard kind.isDonationAllowed else {
      throw CoreAgentAppIntentDonationError.disallowedSubjectKind(kind)
    }
    guard !stableIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentAppIntentDonationError.emptyStableIdentifier
    }
    guard !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentAppIntentDonationError.emptyScopeID
    }
    return self
  }
}

public enum CoreAgentAppIntentDonationError: Error, Equatable, Sendable {
  case disallowedSubjectKind(CoreAgentAppIntentDonationSubjectKind)
  case emptyStableIdentifier
  case emptyScopeID
  case disabledDonation(identifier: String)
  case invalidDescriptor(CoreAgentAppIntentDescriptorError)
  case unexpectedDescriptorError(String)
  case donationIdentifierMismatch(expected: String, actual: String)
}

public struct CoreAgentAppIntentDonationRecord:
  Codable, Equatable, Identifiable, Sendable
{
  public var id: String { donationIdentifier }

  public let donationIdentifier: String
  public let descriptorIdentifier: String
  public let descriptorExposureFingerprint: String
  public let subject: CoreAgentAppIntentDonationSubject
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let donatedAt: Date

  enum CodingKeys: String, CodingKey {
    case donationIdentifier
    case descriptorIdentifier
    case descriptorExposureFingerprint
    case subject
    case authorityBoundaryID
    case policyVersion
    case donatedAt
  }

  public init(
    descriptor: CoreAgentAppIntentDescriptor,
    subject: CoreAgentAppIntentDonationSubject,
    authorityBoundaryID: String,
    policyVersion: Int,
    donatedAt: Date = Date()
  ) throws {
    do {
      _ = try descriptor.validatedForAgentExposure()
    } catch let error as CoreAgentAppIntentDescriptorError {
      throw CoreAgentAppIntentDonationError.invalidDescriptor(error)
    } catch {
      throw CoreAgentAppIntentDonationError.unexpectedDescriptorError(String(describing: error))
    }
    guard descriptor.donationPolicy != .doNotDonate else {
      throw CoreAgentAppIntentDonationError.disabledDonation(identifier: descriptor.identifier)
    }
    let validatedSubject = try subject.validatedForDonation()
    self.descriptorIdentifier = descriptor.identifier
    self.descriptorExposureFingerprint = descriptor.exposureFingerprint
    self.subject = validatedSubject
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.donatedAt = donatedAt
    self.donationIdentifier = Self.makeDonationIdentifier(
      descriptorIdentifier: descriptor.identifier,
      descriptorExposureFingerprint: descriptor.exposureFingerprint,
      subject: validatedSubject,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let donationIdentifier = try container.decode(String.self, forKey: .donationIdentifier)
    let descriptorIdentifier = try container.decode(String.self, forKey: .descriptorIdentifier)
    let descriptorExposureFingerprint = try container.decode(
      String.self,
      forKey: .descriptorExposureFingerprint
    )
    let subject = try container.decode(CoreAgentAppIntentDonationSubject.self, forKey: .subject)
      .validatedForDonation()
    let authorityBoundaryID = try container.decode(String.self, forKey: .authorityBoundaryID)
    let policyVersion = try container.decode(Int.self, forKey: .policyVersion)
    let donatedAt = try container.decode(Date.self, forKey: .donatedAt)
    let expectedIdentifier = Self.makeDonationIdentifier(
      descriptorIdentifier: descriptorIdentifier,
      descriptorExposureFingerprint: descriptorExposureFingerprint,
      subject: subject,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )
    guard donationIdentifier == expectedIdentifier else {
      throw CoreAgentAppIntentDonationError.donationIdentifierMismatch(
        expected: expectedIdentifier,
        actual: donationIdentifier
      )
    }
    self.donationIdentifier = donationIdentifier
    self.descriptorIdentifier = descriptorIdentifier
    self.descriptorExposureFingerprint = descriptorExposureFingerprint
    self.subject = subject
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.donatedAt = donatedAt
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(donationIdentifier, forKey: .donationIdentifier)
    try container.encode(descriptorIdentifier, forKey: .descriptorIdentifier)
    try container.encode(descriptorExposureFingerprint, forKey: .descriptorExposureFingerprint)
    try container.encode(subject, forKey: .subject)
    try container.encode(authorityBoundaryID, forKey: .authorityBoundaryID)
    try container.encode(policyVersion, forKey: .policyVersion)
    try container.encode(donatedAt, forKey: .donatedAt)
  }

  var gateFingerprint: String {
    "sha256:" + sha256Hex(framed([
      donationIdentifier,
      descriptorIdentifier,
      descriptorExposureFingerprint,
      subject.kind.rawValue,
      subject.stableIdentifier,
      subject.scopeID,
      authorityBoundaryID,
      String(policyVersion),
    ]))
  }

  private static func makeDonationIdentifier(
    descriptorIdentifier: String,
    descriptorExposureFingerprint: String,
    subject: CoreAgentAppIntentDonationSubject,
    authorityBoundaryID: String,
    policyVersion: Int
  ) -> String {
    "coreagent-app-intent-donation-sha256-v1:" + sha256Hex(framed([
      descriptorIdentifier,
      descriptorExposureFingerprint,
      subject.kind.rawValue,
      subject.stableIdentifier,
      subject.scopeID,
      authorityBoundaryID,
      String(policyVersion),
    ]))
  }

  private static func fingerprint(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
  }
}

public enum CoreAgentAppIntentDonationInvalidationReason:
  String, Codable, Equatable, Sendable
{
  case erased
  case accessScopeChanged
  case descriptorChanged
  case policyChanged
  case systemDonationFailed
  case userRevoked
}

public struct CoreAgentAppIntentDonationInvalidationRequest:
  Codable, Equatable, Sendable
{
  public let donationIdentifier: String?
  public let scopeID: String?
  public let reason: CoreAgentAppIntentDonationInvalidationReason
  public let invalidatedAt: Date

  public init(
    donationIdentifier: String? = nil,
    scopeID: String? = nil,
    reason: CoreAgentAppIntentDonationInvalidationReason,
    invalidatedAt: Date = Date()
  ) {
    self.donationIdentifier = donationIdentifier
    self.scopeID = scopeID
    self.reason = reason
    self.invalidatedAt = invalidatedAt
  }
}

public struct CoreAgentAppIntentDonationInvalidationRecord:
  Codable, Equatable, Identifiable, Sendable
{
  public var id: String { donationIdentifier }

  public let donationIdentifier: String
  public let descriptorIdentifier: String
  public let subject: CoreAgentAppIntentDonationSubject
  public let reason: CoreAgentAppIntentDonationInvalidationReason
  public let invalidatedAt: Date

  public init(
    donationIdentifier: String,
    descriptorIdentifier: String,
    subject: CoreAgentAppIntentDonationSubject,
    reason: CoreAgentAppIntentDonationInvalidationReason,
    invalidatedAt: Date
  ) {
    self.donationIdentifier = donationIdentifier
    self.descriptorIdentifier = descriptorIdentifier
    self.subject = subject
    self.reason = reason
    self.invalidatedAt = invalidatedAt
  }
}

public actor InMemoryCoreAgentAppIntentDonationStore {
  private var recordsByIdentifier: [String: CoreAgentAppIntentDonationRecord]
  private var invalidations: [CoreAgentAppIntentDonationInvalidationRecord]
  private var invalidatedDonationIdentifiers: Set<String>
  private var invalidatedScopeIDs: Set<String>

  public init(records: [CoreAgentAppIntentDonationRecord] = []) {
    self.recordsByIdentifier = Dictionary(
      uniqueKeysWithValues: records.map { ($0.donationIdentifier, $0) }
    )
    self.invalidations = []
    self.invalidatedDonationIdentifiers = []
    self.invalidatedScopeIDs = []
  }

  @discardableResult
  public func record(_ record: CoreAgentAppIntentDonationRecord) -> Bool {
    guard !invalidatedDonationIdentifiers.contains(record.donationIdentifier),
      !invalidatedScopeIDs.contains(record.subject.scopeID)
    else {
      return false
    }
    recordsByIdentifier[record.donationIdentifier] = record
    return true
  }

  public func activeRecords() -> [CoreAgentAppIntentDonationRecord] {
    recordsByIdentifier.values.sorted(by: Self.recordSort)
  }

  public func invalidationRecords() -> [CoreAgentAppIntentDonationInvalidationRecord] {
    invalidations
  }

  @discardableResult
  public func invalidate(
    _ request: CoreAgentAppIntentDonationInvalidationRequest
  ) -> [CoreAgentAppIntentDonationInvalidationRecord] {
    guard request.donationIdentifier != nil || request.scopeID != nil else {
      return []
    }
    let matched = activeRecords().filter { record in
      let matchesDonation = request.donationIdentifier.map {
        $0 == record.donationIdentifier
      } ?? true
      let matchesScope = request.scopeID.map {
        $0 == record.subject.scopeID
      } ?? true
      return matchesDonation && matchesScope
    }
    let invalidated = matched.map { record in
      CoreAgentAppIntentDonationInvalidationRecord(
        donationIdentifier: record.donationIdentifier,
        descriptorIdentifier: record.descriptorIdentifier,
        subject: record.subject,
        reason: request.reason,
        invalidatedAt: request.invalidatedAt
      )
    }
    for record in matched {
      recordsByIdentifier.removeValue(forKey: record.donationIdentifier)
      invalidatedDonationIdentifiers.insert(record.donationIdentifier)
      invalidatedScopeIDs.insert(record.subject.scopeID)
    }
    if let donationIdentifier = request.donationIdentifier {
      invalidatedDonationIdentifiers.insert(donationIdentifier)
    }
    if let scopeID = request.scopeID {
      invalidatedScopeIDs.insert(scopeID)
    }
    invalidations.append(contentsOf: invalidated)
    return invalidated
  }

  private static func recordSort(
    _ lhs: CoreAgentAppIntentDonationRecord,
    _ rhs: CoreAgentAppIntentDonationRecord
  ) -> Bool {
    if lhs.donatedAt != rhs.donatedAt {
      return lhs.donatedAt < rhs.donatedAt
    }
    return lhs.donationIdentifier < rhs.donationIdentifier
  }
}

public enum CoreAgentRunProjectionStatus: String, Codable, Equatable, Sendable {
  case running
  case completed
  case failed
}

public struct CoreAgentRunProjection: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { runID }

  public let runID: UUID
  public let projectID: String
  public let threadID: String?
  public let startedAt: Date
  public let endedAt: Date
  public let duration: TimeInterval
  public let status: CoreAgentRunProjectionStatus
  public let lastEventKind: CoreAgentEventKind?
  public let eventCounts: [CoreAgentEventKind: Int]
  public let ingestedAt: Date

  public init(trace: CoreAgentEngineTrace) {
    self.runID = trace.run.id
    self.projectID = trace.projectID
    self.threadID = trace.threadID
    self.startedAt = trace.run.startedAt
    self.endedAt = trace.run.endedAt
    self.duration = trace.run.duration
    self.status = Self.status(for: trace.run)
    self.lastEventKind = trace.run.events.last?.kind
    self.eventCounts = Dictionary(
      grouping: trace.run.events,
      by: \.kind
    ).mapValues(\.count)
    self.ingestedAt = trace.ingestedAt
  }

  private static func status(for run: CoreAgentRun) -> CoreAgentRunProjectionStatus {
    if run.events.contains(where: { $0.kind == .runFailed }) {
      return .failed
    }
    if run.events.contains(where: { $0.kind == .runCompleted }) {
      return .completed
    }
    return .running
  }
}

@MainActor
@Observable
public final class CoreAgentRunProjectionStore {
  public private(set) var projections: [CoreAgentRunProjection]

  public init(projections: [CoreAgentRunProjection] = []) {
    self.projections = projections
  }

  public func apply(traces: [CoreAgentEngineTrace]) {
    var projectionsByRunID: [UUID: CoreAgentRunProjection] = Dictionary(
      uniqueKeysWithValues: projections.map { ($0.runID, $0) }
    )
    for trace in traces {
      projectionsByRunID[trace.run.id] = CoreAgentRunProjection(trace: trace)
    }
    projections = projectionsByRunID.values
      .sorted { lhs, rhs in
        if lhs.startedAt != rhs.startedAt {
          return lhs.startedAt < rhs.startedAt
        }
        return lhs.runID.uuidString < rhs.runID.uuidString
      }
  }
}
