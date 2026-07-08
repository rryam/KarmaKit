import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

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
    guard
      traceDigest
        == Self.integrityDigest(
          traceScopeKey: traceScopeKey,
          projectID: projectID,
          threadID: threadID,
          runID: runID,
          startedAt: startedAt,
          endedAt: endedAt,
          ingestedAt: ingestedAt,
          redactionPolicyIdentifier: redactionPolicyIdentifier,
          encodedTrace: encodedTrace
        )
    else {
      return nil
    }
    guard
      let trace = try? CoreAgentSwiftDataEngineCodec.decode(
        CoreAgentEngineTrace.self,
        from: encodedTrace
      )
    else {
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
    guard
      issueDigest
        == Self.integrityDigest(
          issueID: issueID,
          projectID: projectID,
          fingerprint: fingerprint,
          statusRawValue: statusRawValue,
          firstSeenAt: firstSeenAt,
          lastSeenAt: lastSeenAt,
          encodedIssue: encodedIssue
        )
    else {
      return nil
    }
    guard
      let issue = try? CoreAgentSwiftDataEngineCodec.decode(
        CoreAgentEngineIssue.self,
        from: encodedIssue
      )
    else {
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
      let mergedRunIDs =
        existing.contributingRunIDs
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

extension CoreAgentEngineIssue {
  fileprivate func mergedEngineIssueDuplicate(with other: CoreAgentEngineIssue)
    -> CoreAgentEngineIssue
  {
    let preferred = other.isNewerEngineIssue(than: self) ? other : self
    let existingRunIDs = Set(contributingRunIDs)
    let mergedRunIDs =
      contributingRunIDs
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

  fileprivate func isNewerEngineIssue(than other: CoreAgentEngineIssue) -> Bool {
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

extension CoreAgentEngineIssueStatus {
  fileprivate var enginePersistencePriority: Int {
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
