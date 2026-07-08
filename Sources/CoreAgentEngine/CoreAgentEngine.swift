import CoreAgent
import CryptoKit
import Foundation

public struct CoreAgentEngineTrace: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { run.id }

  public let projectID: String
  public let threadID: String?
  public let run: CoreAgentRun
  public let receipt: CoreAgentRunReceipt
  public let ingestedAt: Date

  public init(
    projectID: String,
    threadID: String?,
    run: CoreAgentRun,
    receipt: CoreAgentRunReceipt,
    ingestedAt: Date = Date()
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.run = run
    self.receipt = receipt
    self.ingestedAt = ingestedAt
  }
}

public enum CoreAgentEngineIssueStatus: String, Codable, Equatable, Sendable {
  case open
  case ignored
  case resolved
  case reopened
}

public struct CoreAgentEngineIssue: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let projectID: String
  public let fingerprint: String
  public let title: String
  public let contributingRunIDs: [UUID]
  public let status: CoreAgentEngineIssueStatus
  public let firstSeenAt: Date
  public let lastSeenAt: Date

  public init(
    id: String,
    projectID: String,
    fingerprint: String,
    title: String,
    contributingRunIDs: [UUID],
    status: CoreAgentEngineIssueStatus,
    firstSeenAt: Date,
    lastSeenAt: Date
  ) {
    self.id = id
    self.projectID = projectID
    self.fingerprint = fingerprint
    self.title = title
    self.contributingRunIDs = contributingRunIDs
    self.status = status
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
  }
}

public protocol CoreAgentEngineStore: Sendable {
  @discardableResult
  func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String?
  ) async throws -> CoreAgentEngineTrace

  func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace?
  func traces(projectID: String, threadID: String?) async -> [CoreAgentEngineTrace]
  func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue
  func updateIssueStatus(_ issueID: String, status: CoreAgentEngineIssueStatus) async throws
  func issues(
    projectID: String,
    status: CoreAgentEngineIssueStatus?
  ) async -> [CoreAgentEngineIssue]
}

public enum CoreAgentEngineStoreError: Error, Equatable, Sendable {
  case nonFinalizedRun(UUID)
  case eventRunIDMismatch(eventRunID: UUID, runID: UUID)
  case issueIdentityMismatch(
    issueID: String,
    existingProjectID: String,
    incomingProjectID: String,
    existingFingerprint: String,
    incomingFingerprint: String
  )
}

extension CoreAgentEngineStore {
  @discardableResult
  public func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String? = nil
  ) async throws -> CoreAgentEngineTrace {
    try await ingest(run, projectID: projectID, threadID: threadID)
  }

  public func traces(projectID: String) async -> [CoreAgentEngineTrace] {
    await traces(projectID: projectID, threadID: nil)
  }

  public func issues(projectID: String) async -> [CoreAgentEngineIssue] {
    await issues(projectID: projectID, status: nil)
  }
}

public struct CoreAgentEngineRedactionPolicy: Sendable {
  public let identifier: String
  private let redactor: @Sendable (String) -> String

  public init(
    identifier: String = "custom",
    _ redactor: @escaping @Sendable (String) -> String
  ) {
    self.identifier = identifier
    self.redactor = redactor
  }

  public func redact(_ value: String) -> String {
    redactor(value)
  }

  public func redacted(run: CoreAgentRun) -> CoreAgentRun {
    CoreAgentRun(
      id: run.id,
      startedAt: run.startedAt,
      endedAt: run.endedAt,
      usage: run.usage,
      events: run.events.map { event in
        CoreAgentEvent(
          id: event.id,
          runID: event.runID,
          timestamp: event.timestamp,
          kind: event.kind,
          message: redact(event.message),
          attributes: redact(attributes: event.attributes)
        )
      }
    )
  }

  public static let standard = CoreAgentEngineRedactionPolicy(
    identifier: "coreagent-engine-standard-redaction-v1"
  ) { value in
    var result = value
    let patterns: [(String, String)] = [
      (#"(?i)bearer\s+[a-z0-9._~+/=-]{1,256}"#, "Bearer [REDACTED]"),
      (#"(?i)\bsk-[a-z0-9_-]{8,128}\b"#, "[REDACTED_API_KEY]"),
      (
        #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]{1,256}"#,
        "$1=[REDACTED]"
      ),
    ]
    for (pattern, replacement) in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }
    return result
  }

  func redact(attributes: [String: String]) -> [String: String] {
    let sensitiveMarkers = ["authorization", "api_key", "apikey", "token", "secret", "password"]
    return attributes.reduce(into: [:]) { result, pair in
      if sensitiveMarkers.contains(where: { pair.key.lowercased().contains($0) }) {
        result[pair.key] = "[REDACTED]"
      } else {
        result[pair.key] = redactor(pair.value)
      }
    }
  }

  func redact(run: CoreAgentRun) -> CoreAgentRun {
    redacted(run: run)
  }
}

public actor InMemoryCoreAgentEngineStore: CoreAgentEngineStore {
  private let redactionPolicy: CoreAgentEngineRedactionPolicy
  private var tracesByKey: [TraceKey: StoredTrace] = [:]
  private var issuesByID: [String: CoreAgentEngineIssue] = [:]
  private var nextSequence = 0

  public init(redactionPolicy: CoreAgentEngineRedactionPolicy = .standard) {
    self.redactionPolicy = redactionPolicy
  }

  @discardableResult
  public func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String? = nil
  ) async throws -> CoreAgentEngineTrace {
    try validate(run)
    let redactedRun = redactionPolicy.redact(run: run)
    let trace = try CoreAgentEngineTrace(
      projectID: projectID,
      threadID: threadID,
      run: redactedRun,
      receipt: CoreAgentRunReceipt(run: redactedRun)
    )
    let sequence = nextSequence
    nextSequence += 1
    tracesByKey[TraceKey(projectID: projectID, runID: redactedRun.id)] = StoredTrace(
      sequence: sequence,
      trace: trace
    )
    return trace
  }

  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    guard let trace = tracesByKey[TraceKey(projectID: projectID, runID: runID)]?.trace,
      verified(trace)
    else {
      return nil
    }
    return trace
  }

  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
    tracesByKey.values
      .filter {
        $0.trace.projectID == projectID
          && (threadID == nil || $0.trace.threadID == threadID)
          && verified($0.trace)
      }
      .sorted { $0.sequence < $1.sequence }
      .map(\.trace)
  }

  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    if let existing = issuesByID[issue.id] {
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
      let merged = CoreAgentEngineIssue(
        id: existing.id,
        projectID: existing.projectID,
        fingerprint: existing.fingerprint,
        title: issue.title,
        contributingRunIDs: mergedRunIDs,
        status: nextStatus,
        firstSeenAt: min(existing.firstSeenAt, issue.firstSeenAt),
        lastSeenAt: max(existing.lastSeenAt, issue.lastSeenAt)
      )
      issuesByID[issue.id] = merged
      return merged
    }
    issuesByID[issue.id] = issue
    return issue
  }

  public func updateIssueStatus(
    _ issueID: String,
    status: CoreAgentEngineIssueStatus
  ) async throws {
    guard let issue = issuesByID[issueID] else { return }
    issuesByID[issueID] = CoreAgentEngineIssue(
      id: issue.id,
      projectID: issue.projectID,
      fingerprint: issue.fingerprint,
      title: issue.title,
      contributingRunIDs: issue.contributingRunIDs,
      status: status,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt
    )
  }

  public func issues(
    projectID: String,
    status: CoreAgentEngineIssueStatus? = nil
  ) async -> [CoreAgentEngineIssue] {
    issuesByID.values
      .filter { $0.projectID == projectID && (status == nil || $0.status == status) }
      .sorted { lhs, rhs in
        if lhs.firstSeenAt != rhs.firstSeenAt {
          return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.fingerprint < rhs.fingerprint
      }
  }

  private struct TraceKey: Hashable {
    let projectID: String
    let runID: UUID
  }

  private struct StoredTrace {
    let sequence: Int
    let trace: CoreAgentEngineTrace
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

  private func verified(_ trace: CoreAgentEngineTrace) -> Bool {
    trace.receipt.runID == trace.run.id && trace.receipt.verify()
  }
}

public struct CoreAgentEngineIssueScanner: Sendable {
  private let store: any CoreAgentEngineStore

  public init(store: any CoreAgentEngineStore) {
    self.store = store
  }

  public func scan(projectID: String) async throws -> [CoreAgentEngineIssue] {
    let traces = await store.traces(projectID: projectID)
    let groups = Dictionary(grouping: traces.compactMap(FailureEvidence.init(trace:))) {
      $0.fingerprint
    }

    var issues: [CoreAgentEngineIssue] = []
    for fingerprint in groups.keys.sorted() {
      guard
        let evidence = groups[fingerprint]?.sorted(by: { lhs, rhs in
          lhs.trace.run.startedAt < rhs.trace.run.startedAt
        })
      else {
        continue
      }
      let first = evidence[0]
      let issue = CoreAgentEngineIssue(
        id: Self.issueID(projectID: projectID, fingerprint: fingerprint),
        projectID: projectID,
        fingerprint: fingerprint,
        title: first.title,
        contributingRunIDs: evidence.map(\.trace.run.id),
        status: .open,
        firstSeenAt: evidence.map(\.trace.run.startedAt).min() ?? Date(),
        lastSeenAt: evidence.map(\.trace.run.endedAt).max() ?? Date()
      )
      issues.append(try await store.upsertIssue(issue))
    }
    return issues
  }

  private static func issueID(projectID: String, fingerprint: String) -> String {
    let data = Data("coreagent-engine-issue-v1\u{0}\(projectID)\u{0}\(fingerprint)".utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "issue-\(digest)"
  }

  private struct FailureEvidence {
    let trace: CoreAgentEngineTrace
    let fingerprint: String
    let title: String

    init?(trace: CoreAgentEngineTrace) {
      guard let failed = trace.run.events.first(where: { $0.kind == .runFailed }) else {
        return nil
      }
      let errorType = failed.attributes["error_type"] ?? "unknown"
      let tool = failed.attributes["tool"] ?? failed.attributes["tool_name"] ?? "none"
      self.trace = trace
      self.fingerprint = [
        failed.kind.rawValue,
        errorType,
        tool,
      ].map { "\($0.count):\($0)" }.joined(separator: "|")
      self.title = "\(failed.kind.rawValue): \(errorType) / \(tool)"
    }
  }
}

public struct CoreAgentEnginePlugin: CoreAgentSessionPlugin, CoreAgentRunObserver {
  public let identifier: String
  private let store: any CoreAgentEngineStore
  private let projectID: String
  private let threadID: String?
  private let onIngestFailure: (@Sendable (CoreAgentRun, any Error) async -> Void)?

  public init(
    identifier: String = "coreagent.engine",
    store: any CoreAgentEngineStore,
    projectID: String,
    threadID: String? = nil,
    onIngestFailure: (@Sendable (CoreAgentRun, any Error) async -> Void)? = nil
  ) {
    self.identifier = identifier
    self.store = store
    self.projectID = projectID
    self.threadID = threadID
    self.onIngestFailure = onIngestFailure
  }

  public func coreAgentRunDidFinish(_ run: CoreAgentRun) async {
    do {
      try await store.ingest(run, projectID: projectID, threadID: threadID)
    } catch {
      await onIngestFailure?(run, error)
    }
  }
}
