import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentTestSupport
import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import CoreAgentApplePlatform

extension CoreAgentApplePlatformTests {
  @MainActor
  @Test("SwiftData Engine store fails closed on corrupted trace payloads")
  func swiftDataEngineStoreFailsClosedOnCorruptedTracePayloads() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(731)
    context.insert(
      CoreAgentSwiftDataEngineTraceRecord(
        projectID: "coreagent",
        threadID: "thread-a",
        runID: runID,
        startedAt: Date(timeIntervalSince1970: 1),
        endedAt: Date(timeIntervalSince1970: 2),
        ingestedAt: Date(timeIntervalSince1970: 3),
        encodedTrace: Data("not-json".utf8),
        traceDigest: "sha256:corrupted"
      ))
    try context.save()

    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
    #expect(await store.traces(projectID: "coreagent").isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine store rejects valid trace JSON with stale receipts or unredacted runs")
  func swiftDataEngineStoreRejectsValidTraceJSONWithStaleReceiptsOrUnredactedRuns() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let redactedRunID = Self.uuid(732)
    let redactedRun = CoreAgentEngineRedactionPolicy.standard.redacted(
      run: Self.engineRun(
        id: redactedRunID,
        events: [
          Self.event(
            runID: redactedRunID,
            kind: .runFailed,
            message: "Failed with token=canary-not-a-token-regex",
            attributes: ["api_key": "canary-not-a-token-regex"]
          )
        ]
      ))
    let validReceipt = try CoreAgentRunReceipt(run: redactedRun)
    let staleReceipt = CoreAgentRunReceipt(
      runID: Self.uuid(799),
      receipts: validReceipt.receipts,
      rootHash: validReceipt.rootHash
    )
    let staleReceiptTrace = CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: redactedRun,
      receipt: staleReceipt,
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_020)
    )
    let staleReceiptData = try Self.engineTraceData(staleReceiptTrace)
    context.insert(
      CoreAgentSwiftDataEngineTraceRecord(
        projectID: "coreagent",
        threadID: "thread-a",
        runID: redactedRunID,
        startedAt: redactedRun.startedAt,
        endedAt: redactedRun.endedAt,
        ingestedAt: staleReceiptTrace.ingestedAt,
        encodedTrace: staleReceiptData,
        traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
          projectID: "coreagent",
          threadID: "thread-a",
          runID: redactedRunID,
          startedAt: redactedRun.startedAt,
          endedAt: redactedRun.endedAt,
          ingestedAt: staleReceiptTrace.ingestedAt,
          encodedTrace: staleReceiptData
        )
      ))

    let unredactedRunID = Self.uuid(733)
    let unredactedRun = Self.engineRun(
      id: unredactedRunID,
      events: [
        Self.event(
          runID: unredactedRunID,
          kind: .runFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: ["api_key": "canary-not-a-token-regex"]
        )
      ]
    )
    let unredactedTrace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: unredactedRun,
      receipt: CoreAgentRunReceipt(run: unredactedRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_021)
    )
    let unredactedData = try Self.engineTraceData(unredactedTrace)
    context.insert(
      CoreAgentSwiftDataEngineTraceRecord(
        projectID: "coreagent",
        threadID: "thread-a",
        runID: unredactedRunID,
        startedAt: unredactedRun.startedAt,
        endedAt: unredactedRun.endedAt,
        ingestedAt: unredactedTrace.ingestedAt,
        encodedTrace: unredactedData,
        traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
          projectID: "coreagent",
          threadID: "thread-a",
          runID: unredactedRunID,
          startedAt: unredactedRun.startedAt,
          endedAt: unredactedRun.endedAt,
          ingestedAt: unredactedTrace.ingestedAt,
          encodedTrace: unredactedData
        )
      ))
    try context.save()

    #expect(await store.trace(projectID: "coreagent", runID: redactedRunID) == nil)
    #expect(await store.trace(projectID: "coreagent", runID: unredactedRunID) == nil)
    #expect(await store.traces(projectID: "coreagent").isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine store rejects trace rows from a mismatched redaction policy")
  func swiftDataEngineStoreRejectsTraceRowsFromMismatchedRedactionPolicy() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(744)
    let run = CoreAgentEngineRedactionPolicy.standard.redacted(
      run: Self.engineRun(
        id: runID,
        events: [
          Self.event(
            runID: runID,
            kind: .runFailed,
            message: "Failed with token=canary-not-a-token-regex",
            attributes: ["api_key": "canary-not-a-token-regex"]
          )
        ]
      ))
    let trace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: run,
      receipt: CoreAgentRunReceipt(run: run),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_022)
    )
    context.insert(
      try Self.engineTraceRecord(
        trace,
        redactionPolicyIdentifier: "custom-redaction-policy-v2"
      ))
    try context.save()

    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
    #expect(await store.traces(projectID: "coreagent").isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine trace records bind indexed sidecar metadata into integrity")
  func swiftDataEngineTraceRecordsBindIndexedSidecarMetadataIntoIntegrity() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let baseRunID = Self.uuid(734)
    let baseRun = Self.engineRun(id: baseRunID)
    let baseTrace = try CoreAgentEngineTrace(
      projectID: "encoded-project",
      threadID: "encoded-thread",
      run: baseRun,
      receipt: CoreAgentRunReceipt(run: baseRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_030.123456)
    )
    let encodedTraceData = try Self.engineTraceData(baseTrace)
    let sidecarProjectID = "coreagent"
    let sidecarThreadID = "thread-a"
    let sidecarIngestedAt = Date(timeIntervalSince1970: 1_800_000_031.654321)

    context.insert(
      CoreAgentSwiftDataEngineTraceRecord(
        projectID: sidecarProjectID,
        threadID: sidecarThreadID,
        runID: baseRunID,
        startedAt: baseRun.startedAt,
        endedAt: baseRun.endedAt,
        ingestedAt: sidecarIngestedAt,
        encodedTrace: encodedTraceData,
        traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
          projectID: sidecarProjectID,
          threadID: sidecarThreadID,
          runID: baseRunID,
          startedAt: baseRun.startedAt,
          endedAt: baseRun.endedAt,
          ingestedAt: sidecarIngestedAt,
          encodedTrace: encodedTraceData
        )
      ))

    let digestRunID = Self.uuid(735)
    let digestRun = Self.engineRun(id: digestRunID)
    let digestTrace = try CoreAgentEngineTrace(
      projectID: sidecarProjectID,
      threadID: sidecarThreadID,
      run: digestRun,
      receipt: CoreAgentRunReceipt(run: digestRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_032)
    )
    let digestData = try Self.engineTraceData(digestTrace)
    context.insert(
      CoreAgentSwiftDataEngineTraceRecord(
        projectID: sidecarProjectID,
        threadID: sidecarThreadID,
        runID: digestRunID,
        startedAt: digestRun.startedAt,
        endedAt: digestRun.endedAt,
        ingestedAt: digestTrace.ingestedAt,
        encodedTrace: digestData,
        traceDigest: "sha256:stale"
      ))
    try context.save()

    #expect(await store.trace(projectID: sidecarProjectID, runID: baseRunID) == nil)
    #expect(await store.trace(projectID: sidecarProjectID, runID: digestRunID) == nil)
    #expect(await store.traces(projectID: sidecarProjectID).isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine trace records reject forged scope keys")
  func swiftDataEngineTraceRecordsRejectForgedScopeKeys() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(749)
    let run = Self.engineRun(id: runID)
    let trace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: run,
      receipt: CoreAgentRunReceipt(run: run),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_043)
    )
    context.insert(
      try Self.engineTraceRecord(
        trace,
        sequence: 3,
        traceScopeKey: "engine-trace-scope-sha256-v1:forged"
      ))
    try context.save()

    #expect(await store.trace(projectID: "coreagent", runID: runID) == nil)
    #expect(await store.traces(projectID: "coreagent").isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine store collapses duplicate valid trace rows on readback")
  func swiftDataEngineStoreCollapsesDuplicateValidTraceRowsOnReadback() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(745)
    let olderRun = Self.engineRun(
      id: runID,
      events: [
        Self.event(runID: runID, kind: .runCompleted, message: "older trace")
      ]
    )
    let newerRun = Self.engineRun(
      id: runID,
      events: [
        Self.event(runID: runID, kind: .runCompleted, message: "newer trace")
      ]
    )
    let olderTrace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: olderRun,
      receipt: CoreAgentRunReceipt(run: olderRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_040)
    )
    let newerTrace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: newerRun,
      receipt: CoreAgentRunReceipt(run: newerRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_041)
    )
    context.insert(try Self.engineTraceRecord(olderTrace, sequence: 0))
    context.insert(try Self.engineTraceRecord(newerTrace, sequence: 5))
    try context.save()

    let exact = try #require(await store.trace(projectID: "coreagent", runID: runID))
    let projectTraces = await store.traces(projectID: "coreagent")

    #expect(exact.run.events.first?.message == "newer trace")
    #expect(projectTraces.map(\.run.id) == [runID])
    #expect(projectTraces.first?.run.events.first?.message == "newer trace")
  }

  @MainActor
  @Test("SwiftData Engine store scopes traces by project plus run ID")
  func swiftDataEngineStoreScopesTracesByProjectAndRunID() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(736)
    let run = Self.engineRun(id: runID)

    try await store.ingest(run, projectID: "coreagent", threadID: "a")
    try await store.ingest(run, projectID: "other", threadID: "b")

    #expect(await store.trace(projectID: "coreagent", runID: runID)?.projectID == "coreagent")
    #expect(await store.trace(projectID: "other", runID: runID)?.projectID == "other")
    #expect(await store.traces(projectID: "coreagent").map(\.threadID) == ["a"])
    #expect(await store.traces(projectID: "other").map(\.threadID) == ["b"])
  }

  @MainActor
  @Test("SwiftData Engine store replaces duplicate traces and keeps stable ordering")
  func swiftDataEngineStoreReplacesDuplicateTracesAndKeepsStableOrdering() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let firstRunID = Self.uuid(737)
    let secondRunID = Self.uuid(738)

    try await store.ingest(Self.engineRun(id: firstRunID), projectID: "coreagent", threadID: "old")
    try await store.ingest(
      Self.engineRun(id: secondRunID), projectID: "coreagent", threadID: "middle")
    let replacement = Self.engineRun(
      id: firstRunID,
      events: [
        Self.event(
          runID: firstRunID,
          kind: .runCompleted,
          message: "Run completed after replacement."
        )
      ]
    )
    try await store.ingest(replacement, projectID: "coreagent", threadID: "new")

    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineTraceRecord>())
      .filter { $0.projectID == "coreagent" }

    #expect(rawRecords.filter { $0.runID == firstRunID }.count == 1)
    #expect(rawRecords.count == 2)
    #expect(
      await store.traces(projectID: "coreagent").map(\.run.id) == [
        secondRunID,
        firstRunID,
      ])
    #expect(await store.trace(projectID: "coreagent", runID: firstRunID)?.threadID == "new")
    #expect(
      await store.trace(projectID: "coreagent", runID: firstRunID)?
        .run.events.first?.message == "Run completed after replacement."
    )
  }

  @MainActor
  @Test("SwiftData Engine store preserves issue status and seen bounds on upsert")
  func swiftDataEngineStorePreservesIssueStatusAndSeenBoundsOnUpsert() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let issueID = "issue-manual"
    let firstRunID = Self.uuid(739)
    let secondRunID = Self.uuid(740)
    let baseIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "First title",
      contributingRunIDs: [firstRunID],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 200),
      lastSeenAt: Date(timeIntervalSince1970: 300)
    )
    _ = try await store.upsertIssue(baseIssue)
    try await store.updateIssueStatus(issueID, status: .ignored)
    let incomingIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Latest title",
      contributingRunIDs: [firstRunID, secondRunID],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 400)
    )

    let stored = try await store.upsertIssue(incomingIssue)
    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())

    #expect(stored.status == .ignored)
    #expect(stored.title == "Latest title")
    #expect(stored.contributingRunIDs == [firstRunID, secondRunID])
    #expect(stored.firstSeenAt == Date(timeIntervalSince1970: 100))
    #expect(stored.lastSeenAt == Date(timeIntervalSince1970: 400))
    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
    #expect(await store.issues(projectID: "coreagent", status: .ignored).map(\.id) == [issueID])
  }

  @MainActor
  @Test("SwiftData Engine store merges issue run provenance and rejects identity collisions")
  func swiftDataEngineStoreMergesIssueRunProvenanceAndRejectsIdentityCollisions() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let issue = CoreAgentEngineIssue(
      id: "issue-partial-swiftdata",
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "First",
      contributingRunIDs: [Self.uuid(750)],
      status: .resolved,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    _ = try await store.upsertIssue(issue)

    let merged = try await store.upsertIssue(
      CoreAgentEngineIssue(
        id: "issue-partial-swiftdata",
        projectID: "coreagent",
        fingerprint: "fingerprint",
        title: "Second",
        contributingRunIDs: [Self.uuid(751)],
        status: .open,
        firstSeenAt: Date(timeIntervalSince1970: 150),
        lastSeenAt: Date(timeIntervalSince1970: 300)
      ))

    #expect(merged.status == .reopened)
    #expect(merged.contributingRunIDs == [Self.uuid(750), Self.uuid(751)])

    await #expect(
      throws: CoreAgentEngineStoreError.issueIdentityMismatch(
        issueID: "issue-partial-swiftdata",
        existingProjectID: "coreagent",
        incomingProjectID: "other",
        existingFingerprint: "fingerprint",
        incomingFingerprint: "other-fingerprint"
      )
    ) {
      _ = try await store.upsertIssue(
        CoreAgentEngineIssue(
          id: "issue-partial-swiftdata",
          projectID: "other",
          fingerprint: "other-fingerprint",
          title: "Collision",
          contributingRunIDs: [Self.uuid(752)],
          status: .open,
          firstSeenAt: Date(timeIntervalSince1970: 400),
          lastSeenAt: Date(timeIntervalSince1970: 500)
        ))
    }
  }

  @MainActor
  @Test("SwiftData Engine store ignores corrupt issue duplicates before lifecycle updates")
  func swiftDataEngineStoreIgnoresCorruptIssueDuplicatesBeforeLifecycleUpdates() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let issueID = "issue-corrupt-shadow"
    let validIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Valid issue",
      contributingRunIDs: [Self.uuid(746)],
      status: .resolved,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    let corruptIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Corrupt issue",
      contributingRunIDs: [Self.uuid(746), Self.uuid(747)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 300)
    )
    context.insert(try Self.engineIssueRecord(validIssue))
    context.insert(try Self.engineIssueRecord(corruptIssue, issueDigest: "sha256:corrupt"))
    try context.save()

    let incoming = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Incoming issue",
      contributingRunIDs: [Self.uuid(746), Self.uuid(747)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 300)
    )
    let reopened = try await store.upsertIssue(incoming)
    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())

    #expect(reopened.status == .reopened)
    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
    #expect(
      await store.issues(projectID: "coreagent", status: .reopened).map(\.id) == [
        issueID
      ])
  }

  @MainActor
  @Test("SwiftData Engine store collapses duplicate valid issues before status filtering")
  func swiftDataEngineStoreCollapsesDuplicateValidIssuesBeforeStatusFiltering() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let issueID = "issue-valid-duplicate"
    let openIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Open issue",
      contributingRunIDs: [Self.uuid(748)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    let resolvedIssue = CoreAgentEngineIssue(
      id: issueID,
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Resolved issue",
      contributingRunIDs: [Self.uuid(749)],
      status: .resolved,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    context.insert(try Self.engineIssueRecord(openIssue))
    context.insert(try Self.engineIssueRecord(resolvedIssue))
    try context.save()

    let issuesBeforeUpsert = await store.issues(projectID: "coreagent")
    #expect(issuesBeforeUpsert.map(\.status) == [.resolved])
    #expect(
      issuesBeforeUpsert.first?.contributingRunIDs == [
        Self.uuid(748),
        Self.uuid(749),
      ])
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
    #expect(
      await store.issues(projectID: "coreagent", status: .resolved).map(\.id) == [
        issueID
      ])

    let collapsed = try await store.upsertIssue(
      CoreAgentEngineIssue(
        id: issueID,
        projectID: "coreagent",
        fingerprint: "fingerprint",
        title: "Reopened issue",
        contributingRunIDs: [Self.uuid(752)],
        status: .open,
        firstSeenAt: Date(timeIntervalSince1970: 150),
        lastSeenAt: Date(timeIntervalSince1970: 300)
      ))
    let rawRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataEngineIssueRecord>())

    #expect(collapsed.status == .reopened)
    #expect(collapsed.contributingRunIDs == [Self.uuid(748), Self.uuid(749), Self.uuid(752)])
    #expect(rawRecords.filter { $0.issueID == issueID }.count == 1)
  }

}
