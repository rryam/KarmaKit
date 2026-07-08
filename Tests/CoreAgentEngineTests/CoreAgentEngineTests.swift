import CoreAgent
import CoreAgentEngine
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentEngine trace ingestion")
struct CoreAgentEngineTests {
  @Test("Ingests real CoreAgent runs and verifies receipts after readback")
  func ingestsRealRunsAndVerifiesReceiptsAfterReadback() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let run = Self.run(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      events: [
        Self.event(
          runID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
          kind: .runStarted,
          message: "Run started."
        ),
        Self.event(
          runID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
          kind: .runCompleted,
          message: "Run completed."
        ),
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent", threadID: "thread-a")
    let readback = try #require(await store.trace(projectID: "coreagent", runID: run.id))

    #expect(trace.run == run)
    #expect(readback.run == run)
    #expect(readback.receipt.verify())
    #expect(readback.receipt.runID == run.id)
    #expect(readback.projectID == "coreagent")
    #expect(readback.threadID == "thread-a")
  }

  @Test("Rejects non-finalized runs and mismatched event run IDs before storage")
  func rejectsNonFinalizedRunsAndMismatchedEventRunIDs() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let runID = Self.uuid(151)

    await #expect(throws: CoreAgentEngineStoreError.nonFinalizedRun(runID)) {
      try await store.ingest(
        Self.run(
          id: runID,
          events: [
            Self.event(runID: runID, kind: .toolExecutionFailed, message: "partial")
          ]
        ),
        projectID: "coreagent"
      )
    }

    let otherID = Self.uuid(152)
    await #expect(throws: CoreAgentEngineStoreError.eventRunIDMismatch(
      eventRunID: otherID,
      runID: runID
    )) {
      try await store.ingest(
        Self.run(
          id: runID,
          events: [
            Self.event(runID: otherID, kind: .runCompleted, message: "wrong")
          ]
        ),
        projectID: "coreagent"
      )
    }

    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
  }

  @Test("Queries traces by project and optional thread")
  func queriesTracesByProjectAndThread() async throws {
    let store = InMemoryCoreAgentEngineStore()
    try await store.ingest(Self.run(id: Self.uuid(201)), projectID: "coreagent", threadID: "a")
    try await store.ingest(Self.run(id: Self.uuid(202)), projectID: "coreagent", threadID: "b")
    try await store.ingest(Self.run(id: Self.uuid(203)), projectID: "other", threadID: "a")

    #expect(await store.traces(projectID: "coreagent").map(\.run.id) == [
      Self.uuid(201),
      Self.uuid(202),
    ])
    #expect(await store.traces(projectID: "coreagent", threadID: "a").map(\.run.id) == [
      Self.uuid(201)
    ])
  }

  @Test("Redacts secret-marked fields before trace storage")
  func redactsSecretMarkedFieldsBeforeTraceStorage() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let runID = Self.uuid(301)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(
          runID: runID,
          kind: .toolExecutionFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: [
            "api_key": "canary-not-a-token-regex",
            "tool": "search",
          ]
        ),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: [
            "api_key": "canary-not-a-token-regex",
            "tool": "search",
          ]
        )
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent")
    let event = try #require(trace.run.events.first)

    #expect(event.message == "Failed with token=[REDACTED]")
    #expect(event.attributes["api_key"] == "[REDACTED]")
    #expect(event.attributes["tool"] == "search")
    #expect(trace.receipt.verify())
  }

  @Test("Failed run scan clusters issues by typed failure evidence")
  func failedRunScanClustersIssuesByTypedFailureEvidence() async throws {
    let store = InMemoryCoreAgentEngineStore()
    try await store.ingest(
      Self.failedRun(id: Self.uuid(401), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(402), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(403), errorType: "timeout", tool: "browser"),
      projectID: "coreagent"
    )

    let scanner = CoreAgentEngineIssueScanner(store: store)
    let issues = try await scanner.scan(projectID: "coreagent")

    #expect(issues.map(\.contributingRunIDs) == [
      [Self.uuid(401), Self.uuid(402)],
      [Self.uuid(403)],
    ])
    #expect(issues.map(\.status) == [.open, .open])
    #expect(issues.map(\.fingerprint) == [
      "9:runFailed|13:authorization|10:write_file",
      "9:runFailed|7:timeout|7:browser",
    ])
  }

  @Test("Resolved issues reopen when a new contributing run appears")
  func resolvedIssuesReopenWhenNewContributingRunAppears() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let scanner = CoreAgentEngineIssueScanner(store: store)
    try await store.ingest(
      Self.failedRun(id: Self.uuid(451), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    let first = try #require(try await scanner.scan(projectID: "coreagent").first)
    try await store.updateIssueStatus(first.id, status: .resolved)
    try await store.ingest(
      Self.failedRun(id: Self.uuid(452), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )

    let rescanned = try #require(try await scanner.scan(projectID: "coreagent").first)

    #expect(rescanned.status == .reopened)
    #expect(rescanned.contributingRunIDs == [Self.uuid(451), Self.uuid(452)])
  }

  @Test("Issue upserts merge contributing run provenance")
  func issueUpsertsMergeContributingRunProvenance() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let issue = CoreAgentEngineIssue(
      id: "issue-partial",
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "First",
      contributingRunIDs: [Self.uuid(461)],
      status: .resolved,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    _ = try await store.upsertIssue(issue)

    let merged = try await store.upsertIssue(CoreAgentEngineIssue(
      id: "issue-partial",
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Second",
      contributingRunIDs: [Self.uuid(462)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 150),
      lastSeenAt: Date(timeIntervalSince1970: 300)
    ))

    #expect(merged.status == .reopened)
    #expect(merged.contributingRunIDs == [Self.uuid(461), Self.uuid(462)])
    #expect(merged.firstSeenAt == Date(timeIntervalSince1970: 100))
    #expect(merged.lastSeenAt == Date(timeIntervalSince1970: 300))
  }

  @Test("Issue upserts reject project or fingerprint identity collisions")
  func issueUpsertsRejectProjectOrFingerprintIdentityCollisions() async throws {
    let store = InMemoryCoreAgentEngineStore()
    _ = try await store.upsertIssue(CoreAgentEngineIssue(
      id: "issue-collision",
      projectID: "coreagent",
      fingerprint: "fingerprint-a",
      title: "First",
      contributingRunIDs: [Self.uuid(471)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    ))

    await #expect(throws: CoreAgentEngineStoreError.issueIdentityMismatch(
      issueID: "issue-collision",
      existingProjectID: "coreagent",
      incomingProjectID: "other",
      existingFingerprint: "fingerprint-a",
      incomingFingerprint: "fingerprint-b"
    )) {
      _ = try await store.upsertIssue(CoreAgentEngineIssue(
        id: "issue-collision",
        projectID: "other",
        fingerprint: "fingerprint-b",
        title: "Collision",
        contributingRunIDs: [Self.uuid(472)],
        status: .open,
        firstSeenAt: Date(timeIntervalSince1970: 300),
        lastSeenAt: Date(timeIntervalSince1970: 400)
      ))
    }
  }

  @Test("Issues can be filtered by project and lifecycle status")
  func issuesCanBeFilteredByProjectAndLifecycleStatus() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let scanner = CoreAgentEngineIssueScanner(store: store)
    try await store.ingest(
      Self.failedRun(id: Self.uuid(501), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(502), errorType: "authorization", tool: "write_file"),
      projectID: "other"
    )

    let issues = try await scanner.scan(projectID: "coreagent")
    let issue = try #require(issues.first)
    try await store.updateIssueStatus(issue.id, status: .resolved)

    #expect(await store.issues(projectID: "coreagent", status: .resolved).map(\.id) == [
      issue.id
    ])
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
    #expect(await store.issues(projectID: "other", status: .open).isEmpty)
  }

  @Test("Engine plugin ingests the finalized CoreAgent run")
  func enginePluginIngestsFinalizedCoreAgentRun() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let plugin = CoreAgentEnginePlugin(
      store: store,
      projectID: "coreagent",
      threadID: "session-thread"
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "ok", inputTokens: 11, cachedInputTokens: 3, outputTokens: 5)
      ]),
      plugins: [plugin]
    )

    let response = try await session.respond(to: "hello")
    let trace = try #require(await store.trace(projectID: "coreagent", runID: response.run.id))

    #expect(trace.run == response.run)
    #expect(trace.threadID == "session-thread")
    #expect(trace.receipt.verify())
    #expect(trace.run.events.contains { $0.kind == .runCompleted })
    #expect(trace.run.usage == response.usage)
  }

  @Test("Engine plugin reports ingestion failures")
  func enginePluginReportsIngestionFailures() async throws {
    let failureProbe = EngineFailureProbe()
    let plugin = CoreAgentEnginePlugin(
      store: RejectingEngineStore(),
      projectID: "coreagent",
      onIngestFailure: { run, error in
        await failureProbe.record(runID: run.id, error: error)
      }
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "ok")]),
      plugins: [plugin]
    )

    let response = try await session.respond(to: "hello")
    let failures = await failureProbe.failures

    #expect(failures.map(\.runID) == [response.run.id])
    #expect(failures.first?.error is RejectingEngineStoreError)
  }

  private static func failedRun(id: UUID, errorType: String, tool: String) -> CoreAgentRun {
    run(
      id: id,
      events: [
        event(
          runID: id,
          kind: .toolExecutionFailed,
          message: "Tool failed.",
          attributes: [
            "error_type": errorType,
            "tool": tool,
          ]
        ),
        event(
          runID: id,
          kind: .runFailed,
          message: "Run failed.",
          attributes: [
            "error_type": errorType,
            "tool": tool,
          ]
        ),
      ]
    )
  }

  private static func run(
    id: UUID,
    events: [CoreAgentEvent] = []
  ) -> CoreAgentRun {
    let storedEvents =
      events.isEmpty
      ? [event(runID: id, kind: .runCompleted, message: "Run completed.")]
      : events
    return CoreAgentRun(
      id: id,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      usage: CoreAgentUsage(
        inputTokens: 10,
        cachedInputTokens: 2,
        outputTokens: 4,
        reasoningTokens: 1
      ),
      events: storedEvents
    )
  }

  private static func event(
    runID: UUID,
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) -> CoreAgentEvent {
    CoreAgentEvent(
      id: UUID(),
      runID: runID,
      timestamp: Date(timeIntervalSince1970: 1),
      kind: kind,
      message: message,
      attributes: attributes
    )
  }

  private static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }
}

private enum RejectingEngineStoreError: Error {
  case rejected
}

private struct RejectingEngineStore: CoreAgentEngineStore {
  func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String?
  ) async throws -> CoreAgentEngineTrace {
    throw RejectingEngineStoreError.rejected
  }

  func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    nil
  }

  func traces(projectID: String, threadID: String?) async -> [CoreAgentEngineTrace] {
    []
  }

  func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    issue
  }

  func updateIssueStatus(_ issueID: String, status: CoreAgentEngineIssueStatus) async throws {}

  func issues(projectID: String, status: CoreAgentEngineIssueStatus?) async
    -> [CoreAgentEngineIssue]
  {
    []
  }
}

private actor EngineFailureProbe {
  private(set) var failures: [(runID: UUID, error: any Error)] = []

  func record(runID: UUID, error: any Error) {
    failures.append((runID, error))
  }
}
