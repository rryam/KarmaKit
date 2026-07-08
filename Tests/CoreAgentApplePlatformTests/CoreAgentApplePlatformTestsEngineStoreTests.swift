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
  @Test("SwiftData Engine store fails closed on valid issue identity collisions")
  func swiftDataEngineStoreFailsClosedOnValidIssueIdentityCollisions() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let first = CoreAgentEngineIssue(
      id: "issue-read-collision",
      projectID: "coreagent",
      fingerprint: "fingerprint-a",
      title: "First issue",
      contributingRunIDs: [Self.uuid(753)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    let second = CoreAgentEngineIssue(
      id: "issue-read-collision",
      projectID: "coreagent",
      fingerprint: "fingerprint-b",
      title: "Second issue",
      contributingRunIDs: [Self.uuid(754)],
      status: .resolved,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    context.insert(try Self.engineIssueRecord(first))
    context.insert(try Self.engineIssueRecord(second))
    try context.save()

    #expect(await store.issues(projectID: "coreagent").isEmpty)
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
    #expect(await store.issues(projectID: "coreagent", status: .resolved).isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine issue records fail closed on corrupted sidecar fields")
  func swiftDataEngineIssueRecordsFailClosedOnCorruptedSidecarFields() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let issue = CoreAgentEngineIssue(
      id: "issue-corrupt",
      projectID: "coreagent",
      fingerprint: "fingerprint",
      title: "Corrupt issue",
      contributingRunIDs: [Self.uuid(741)],
      status: .open,
      firstSeenAt: Date(timeIntervalSince1970: 100),
      lastSeenAt: Date(timeIntervalSince1970: 200)
    )
    let encodedIssue = try Self.engineIssueData(issue)
    context.insert(
      CoreAgentSwiftDataEngineIssueRecord(
        issueID: issue.id,
        projectID: issue.projectID,
        fingerprint: issue.fingerprint,
        statusRawValue: "unknown",
        firstSeenAt: issue.firstSeenAt,
        lastSeenAt: issue.lastSeenAt,
        encodedIssue: encodedIssue,
        issueDigest: CoreAgentSwiftDataEngineIssueRecord.integrityDigest(
          issueID: issue.id,
          projectID: issue.projectID,
          fingerprint: issue.fingerprint,
          statusRawValue: "unknown",
          firstSeenAt: issue.firstSeenAt,
          lastSeenAt: issue.lastSeenAt,
          encodedIssue: encodedIssue
        )
      ))
    context.insert(
      CoreAgentSwiftDataEngineIssueRecord(
        issueID: issue.id,
        projectID: issue.projectID,
        fingerprint: "tampered",
        statusRawValue: issue.status.rawValue,
        firstSeenAt: issue.firstSeenAt,
        lastSeenAt: issue.lastSeenAt,
        encodedIssue: encodedIssue,
        issueDigest: CoreAgentSwiftDataEngineIssueRecord.integrityDigest(
          issueID: issue.id,
          projectID: issue.projectID,
          fingerprint: "tampered",
          statusRawValue: issue.status.rawValue,
          firstSeenAt: issue.firstSeenAt,
          lastSeenAt: issue.lastSeenAt,
          encodedIssue: encodedIssue
        )
      ))
    try context.save()

    #expect(await store.issues(projectID: "coreagent").isEmpty)
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
  }

  @MainActor
  @Test("SwiftData Engine store preserves subsecond trace dates")
  func swiftDataEngineStorePreservesSubsecondTraceDates() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(742)
    let eventTimestamp = Date(timeIntervalSinceReferenceDate: 987_654_321.123456)
    let run = CoreAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSinceReferenceDate: 987_654_320.654321),
      endedAt: Date(timeIntervalSinceReferenceDate: 987_654_322.987654),
      usage: nil,
      events: [
        CoreAgentEvent(
          id: UUID(),
          runID: runID,
          timestamp: eventTimestamp,
          kind: .runCompleted,
          message: "Run completed.",
          attributes: [:]
        )
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent", threadID: "subsecond")
    let readback = try #require(await store.trace(projectID: "coreagent", runID: runID))

    #expect(readback.run.startedAt == run.startedAt)
    #expect(readback.run.endedAt == run.endedAt)
    #expect(readback.run.events.first?.timestamp == eventTimestamp)
    #expect(readback.ingestedAt == trace.ingestedAt)
  }

  @MainActor
  @Test("SwiftData Engine store works through the portable store protocol")
  func swiftDataEngineStoreWorksThroughThePortableStoreProtocol() async throws {
    let context = try Self.swiftDataEngineContext()
    let store: any CoreAgentEngineStore = CoreAgentSwiftDataEngineStore(modelContext: context)
    let run = Self.engineRun(id: Self.uuid(743))

    try await store.ingest(run, projectID: "coreagent", threadID: "portable")
    let readback = try #require(await store.trace(projectID: "coreagent", runID: run.id))

    #expect(readback.threadID == "portable")
    #expect(readback.receipt.verify())
  }

  @MainActor
  @Test("CoreAgentEnginePlugin persists finalized runs into SwiftData Engine store")
  func coreAgentEnginePluginPersistsFinalizedRunsIntoSwiftDataEngineStore() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
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

    #expect(trace.threadID == "session-thread")
    #expect(trace.run == response.run)
    #expect(trace.receipt.verify())
    #expect(trace.run.events.contains { $0.kind == .runCompleted })
    #expect(trace.run.usage == response.usage)
  }

  @MainActor
  @Test("SwiftData graph checkpointer saves latest history and scoped lookup")
  func swiftDataGraphCheckpointerSavesLatestHistoryAndScopedLookup() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let first = CoreAgentGraphCheckpoint(
      id: "checkpoint-1",
      threadID: "thread-a",
      namespace: "alpha",
      step: 0,
      state: GraphState(log: ["start"]),
      nextNodeIDs: ["plan"],
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let second = CoreAgentGraphCheckpoint(
      id: "checkpoint-2",
      threadID: "thread-a",
      namespace: "alpha",
      parentCheckpointID: first.id,
      step: 1,
      state: GraphState(log: ["start", "plan"]),
      nextNodeIDs: ["act"],
      pendingWrites: [
        CoreAgentGraphPendingWrite(nodeID: "plan", step: 1, update: GraphState(log: ["pending"]))
      ],
      createdAt: Date(timeIntervalSince1970: 101)
    )
    let otherNamespace = CoreAgentGraphCheckpoint(
      id: "checkpoint-3",
      threadID: "thread-a",
      namespace: "beta",
      step: 1,
      state: GraphState(log: ["beta"]),
      nextNodeIDs: [],
      createdAt: Date(timeIntervalSince1970: 102)
    )

    try await checkpointer.save(first)
    try await checkpointer.save(second)
    try await checkpointer.save(otherNamespace)

    #expect(try await checkpointer.latest(threadID: "thread-a", namespace: "alpha") == second)
    #expect(try await checkpointer.checkpoint(id: "checkpoint-1") == first)
    #expect(
      try await checkpointer.history(threadID: "thread-a", namespace: "alpha") == [
        second,
        first,
      ])
    #expect(
      try await checkpointer.latest(threadID: "thread-a", namespace: "beta") == otherNamespace)
  }

  @MainActor
  @Test("SwiftData graph checkpointer works through protocol and fails closed on corrupt rows")
  func swiftDataGraphCheckpointerWorksThroughProtocolAndFailsClosedOnCorruptRows() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let portable: any CoreAgentGraphCheckpointer<GraphState> = checkpointer
    let checkpoint = CoreAgentGraphCheckpoint(
      id: "checkpoint-portable",
      threadID: "thread-b",
      namespace: "alpha",
      step: 2,
      state: GraphState(log: ["portable"]),
      nextNodeIDs: []
    )

    try await portable.save(checkpoint)
    context.insert(
      CoreAgentSwiftDataGraphCheckpointRecord(
        checkpointID: "checkpoint-corrupt",
        threadID: "thread-b",
        namespace: "alpha",
        parentCheckpointID: nil,
        step: 3,
        createdAt: Date(timeIntervalSince1970: 200),
        storedAt: Date(timeIntervalSince1970: 201),
        saveSequence: 1,
        encodedCheckpoint: Data("not-json".utf8),
        checkpointDigest: "sha256:corrupt"
      ))
    try context.save()

    #expect(try await portable.checkpoint(id: "checkpoint-portable") == checkpoint)
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await portable.checkpoint(id: "checkpoint-corrupt")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await portable.latest(threadID: "thread-b", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await portable.history(threadID: "thread-b", namespace: "alpha")
    }
  }

  @MainActor
  @Test("SwiftData graph checkpointer preserves reverse save order")
  func swiftDataGraphCheckpointerPreservesReverseSaveOrder() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let highStep = CoreAgentGraphCheckpoint(
      id: "same-id",
      threadID: "thread-c",
      namespace: "alpha",
      step: 10,
      state: GraphState(log: ["high"]),
      nextNodeIDs: ["later"],
      createdAt: Date(timeIntervalSince1970: 300)
    )
    let lowerStepSavedLast = CoreAgentGraphCheckpoint(
      id: "same-id",
      threadID: "thread-c",
      namespace: "alpha",
      parentCheckpointID: highStep.id,
      step: 3,
      state: GraphState(log: ["low"]),
      nextNodeIDs: ["retry"],
      createdAt: Date(timeIntervalSince1970: 200)
    )

    try await checkpointer.save(highStep)
    try await checkpointer.save(lowerStepSavedLast)

    #expect(try await checkpointer.checkpoint(id: "same-id") == lowerStepSavedLast)
    #expect(
      try await checkpointer.latest(threadID: "thread-c", namespace: "alpha") == lowerStepSavedLast)
    #expect(
      try await checkpointer.history(threadID: "thread-c", namespace: "alpha") == [
        lowerStepSavedLast,
        highStep,
      ])
  }

  @MainActor
  @Test("SwiftData graph checkpointer fails closed on forged scope keys")
  func swiftDataGraphCheckpointerFailsClosedOnForgedScopeKeys() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let checkpoint = CoreAgentGraphCheckpoint(
      id: "checkpoint-stable",
      threadID: "thread-forged",
      namespace: "alpha",
      step: 0,
      state: GraphState(log: ["stable"]),
      nextNodeIDs: []
    )

    try await checkpointer.save(checkpoint)
    context.insert(
      CoreAgentSwiftDataGraphCheckpointRecord(
        checkpointID: "checkpoint-forged",
        threadID: "thread-forged",
        namespace: "alpha",
        parentCheckpointID: nil,
        step: 1,
        createdAt: Date(timeIntervalSince1970: 500),
        storedAt: Date(timeIntervalSince1970: 501),
        saveSequence: 1,
        checkpointScopeKey: "graph-checkpoint-scope-sha256-v1:forged",
        encodedCheckpoint: Data("not-json".utf8),
        checkpointDigest: "sha256:corrupt"
      ))
    try context.save()

    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await checkpointer.latest(threadID: "thread-forged", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await checkpointer.history(threadID: "thread-forged", namespace: "alpha")
    }
  }

  @MainActor
  @Test("SwiftData graph checkpointer latest validates newest candidate only")
  func swiftDataGraphCheckpointerLatestValidatesNewestCandidateOnly() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let checkpoint = CoreAgentGraphCheckpoint(
      id: "checkpoint-newest",
      threadID: "thread-latest",
      namespace: "alpha",
      step: 1,
      state: GraphState(log: ["newest"]),
      nextNodeIDs: []
    )

    context.insert(
      CoreAgentSwiftDataGraphCheckpointRecord(
        checkpointID: "checkpoint-older-corrupt",
        threadID: "thread-latest",
        namespace: "alpha",
        parentCheckpointID: nil,
        step: 0,
        createdAt: Date(timeIntervalSince1970: 600),
        storedAt: Date(timeIntervalSince1970: 601),
        saveSequence: -1,
        encodedCheckpoint: Data("not-json".utf8),
        checkpointDigest: "sha256:corrupt"
      ))
    try context.save()
    try await checkpointer.save(checkpoint)

    #expect(
      try await checkpointer.latest(threadID: "thread-latest", namespace: "alpha") == checkpoint)
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await checkpointer.history(threadID: "thread-latest", namespace: "alpha")
    }
  }

  @MainActor
  @Test("SwiftData graph checkpointer orders tied save sequences deterministically")
  func swiftDataGraphCheckpointerOrdersTiedSaveSequencesDeterministically() async throws {
    let context = try Self.swiftDataGraphContext()
    let checkpointer = CoreAgentSwiftDataGraphCheckpointer<GraphState>(modelContext: context)
    let older = CoreAgentGraphCheckpoint(
      id: "checkpoint-tie-a",
      threadID: "thread-tie",
      namespace: "alpha",
      step: 1,
      state: GraphState(log: ["older"]),
      nextNodeIDs: [],
      createdAt: Date(timeIntervalSince1970: 700)
    )
    let newer = CoreAgentGraphCheckpoint(
      id: "checkpoint-tie-b",
      threadID: "thread-tie",
      namespace: "alpha",
      step: 1,
      state: GraphState(log: ["newer"]),
      nextNodeIDs: [],
      createdAt: Date(timeIntervalSince1970: 701)
    )

    context.insert(
      try CoreAgentSwiftDataGraphCheckpointRecord(
        checkpoint: older,
        saveSequence: 0,
        storedAt: Date(timeIntervalSince1970: 710)
      ))
    context.insert(
      try CoreAgentSwiftDataGraphCheckpointRecord(
        checkpoint: newer,
        saveSequence: 0,
        storedAt: Date(timeIntervalSince1970: 711)
      ))
    try context.save()

    #expect(try await checkpointer.latest(threadID: "thread-tie", namespace: "alpha") == newer)
    #expect(
      try await checkpointer.history(threadID: "thread-tie", namespace: "alpha") == [
        newer,
        older,
      ])
  }

  @Test("SwiftData graph records clamp extreme dates in digests")
  func swiftDataGraphRecordsClampExtremeDatesInDigests() throws {
    let checkpoint = CoreAgentGraphCheckpoint(
      id: "checkpoint-distant",
      threadID: "thread-distant",
      namespace: "alpha",
      step: 0,
      state: GraphState(log: ["distant"]),
      nextNodeIDs: [],
      createdAt: .distantFuture
    )
    let checkpointRecord = try CoreAgentSwiftDataGraphCheckpointRecord(
      checkpoint: checkpoint,
      saveSequence: 0,
      storedAt: .distantFuture
    )
    let storeRecord = try CoreAgentSwiftDataGraphStoreRecord(
      record: CoreAgentGraphStoreRecord(
        namespace: "alpha",
        key: "distant",
        value: GraphValue(label: "future"),
        updatedAt: .distantFuture
      )
    )

    #expect(try checkpointRecord.checkpoint(as: GraphState.self) == checkpoint)
    #expect(try storeRecord.graphRecord(as: GraphValue.self).value == GraphValue(label: "future"))
  }

  @MainActor
  @Test("SwiftData graph store persists values by namespace and key")
  func swiftDataGraphStorePersistsValuesByNamespaceAndKey() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "alpha"), forKey: "profile", namespace: "alpha")
    try await store.put(GraphValue(label: "alpha-updated"), forKey: "profile", namespace: "alpha")
    try await store.put(GraphValue(label: "beta"), forKey: "profile", namespace: "beta")
    try await store.put(GraphValue(label: "first"), forKey: "a", namespace: "alpha")
    let rawRecordsAfterReplacement = try context.fetch(
      FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>()
    )

    #expect(
      try await store.value(forKey: "profile", namespace: "alpha")
        == GraphValue(label: "alpha-updated"))
    #expect(
      try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
    #expect(try await store.keys(namespace: "alpha") == ["a", "profile"])
    #expect(
      rawRecordsAfterReplacement.filter {
        $0.namespace == "alpha" && $0.key == "profile"
      }.count == 1)

    try await store.removeValue(forKey: "profile", namespace: "alpha")

    #expect(try await store.value(forKey: "profile", namespace: "alpha") == nil)
    #expect(
      try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
  }

  @MainActor
  @Test("SwiftData graph store keys validate integrity without decoding payload values")
  func swiftDataGraphStoreKeysValidateIntegrityWithoutDecodingPayloadValues() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "stable"), forKey: "profile", namespace: "alpha")
    context.insert(
      try CoreAgentSwiftDataGraphStoreRecord(
        record: CoreAgentGraphStoreRecord(
          namespace: "alpha",
          key: "foreign",
          value: OtherGraphValue(count: 1)
        )
      ))
    context.insert(
      try CoreAgentSwiftDataGraphStoreRecord(
        record: CoreAgentGraphStoreRecord(
          namespace: "alpha",
          key: "foreign-removable",
          value: OtherGraphValue(count: 2)
        )
      ))
    try context.save()

    #expect(
      try await store.keys(namespace: "alpha") == [
        "foreign",
        "foreign-removable",
        "profile",
      ])
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.value(forKey: "foreign", namespace: "alpha")
    }

    try await store.put(GraphValue(label: "replacement"), forKey: "foreign", namespace: "alpha")
    #expect(
      try await store.value(forKey: "foreign", namespace: "alpha")
        == GraphValue(label: "replacement"))

    try await store.removeValue(forKey: "foreign-removable", namespace: "alpha")
    #expect(try await store.keys(namespace: "alpha") == ["foreign", "profile"])
  }

  @MainActor
  @Test("SwiftData graph store fails closed on corrupt matching rows")
  func swiftDataGraphStoreFailsClosedOnCorruptMatchingRows() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "stable"), forKey: "profile", namespace: "alpha")
    context.insert(
      CoreAgentSwiftDataGraphStoreRecord(
        namespace: "alpha",
        key: "profile",
        updatedAt: Date(timeIntervalSince1970: 4_102_444_800),
        encodedValue: Data("not-json".utf8),
        valueDigest: "sha256:corrupt"
      ))
    try context.save()

    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.record(forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.value(forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.keys(namespace: "alpha")
    }
  }

}
