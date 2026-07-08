import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentTestSupport
import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import CoreAgentApplePlatform

@Suite("CoreAgent Apple platform adapters")
struct CoreAgentApplePlatformTests {
  @Test("SwiftData checkpoint snapshots preserve canonical bytes and policy metadata")
  func swiftDataCheckpointSnapshotsPreserveCanonicalBytesAndPolicyMetadata() throws {
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))
    let storedAt = Date(timeIntervalSince1970: 1_800_000_000)

    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: checkpoint,
      authorityBoundaryID: "user:basit/device:mac",
      policyVersion: 7,
      storedAt: storedAt
    )

    let restored = try snapshot.decodeCheckpoint(
      expectedAuthorityBoundaryID: "user:basit/device:mac",
      expectedPolicyVersion: 7
    )

    #expect(snapshot.checkpointKey == "thread/session")
    #expect(snapshot.checkpointFormatVersion == CoreAgentCheckpoint.currentFormatVersion)
    #expect(snapshot.compatibilityRevision == "revision-a")
    #expect(snapshot.authorityBoundaryID == "user:basit/device:mac")
    #expect(snapshot.policyVersion == 7)
    #expect(snapshot.storedAt == storedAt)
    #expect(snapshot.canonicalCheckpointData.count > 0)
    #expect(snapshot.checkpointDigest.hasPrefix("sha256:"))
    #expect(restored.savedAt == checkpoint.savedAt)
    #expect(restored.compatibilityRevision == checkpoint.compatibilityRevision)
    #expect(restored.transcript == checkpoint.transcript)
  }

  @Test("SwiftData checkpoint snapshots preserve subsecond Date precision")
  func swiftDataCheckpointSnapshotsPreserveSubsecondDatePrecision() throws {
    let savedAt = Date(timeIntervalSinceReferenceDate: 987_654_321.987654)
    let checkpoint = Self.checkpoint(savedAt: savedAt)
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/subsecond",
      checkpoint: checkpoint,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 1
    )

    let restored = try snapshot.decodeCheckpoint(
      expectedAuthorityBoundaryID: "workspace:coreagent",
      expectedPolicyVersion: 1
    )

    #expect(restored.savedAt == savedAt)
  }

  @Test("SwiftData checkpoint snapshots enforce read barriers before decode")
  func swiftDataCheckpointSnapshotsEnforceReadBarriersBeforeDecode() throws {
    let snapshot = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      checkpointKey: "thread/session",
      authorityBoundaryID: "user:other/device:mac",
      policyVersion: 4,
      checkpointFormatVersion: CoreAgentCheckpoint.currentFormatVersion,
      compatibilityRevision: "revision-a",
      savedAt: Date(timeIntervalSince1970: 1_700_000_000),
      storedAt: Date(timeIntervalSince1970: 1_800_000_000),
      canonicalCheckpointData: Data("not-json".utf8),
      checkpointDigest: "sha256:not-a-real-digest"
    )

    #expect(
      throws: CoreAgentSwiftDataCheckpointAccessError.authorityBoundaryMismatch(
        expected: "user:basit/device:mac",
        actual: "user:other/device:mac"
      )
    ) {
      _ = try snapshot.decodeCheckpoint(
        expectedAuthorityBoundaryID: "user:basit/device:mac",
        expectedPolicyVersion: 4
      )
    }

    #expect(
      throws: CoreAgentSwiftDataCheckpointAccessError.policyVersionMismatch(
        expected: 9,
        actual: 4
      )
    ) {
      _ = try snapshot.decodeCheckpoint(
        expectedAuthorityBoundaryID: "user:other/device:mac",
        expectedPolicyVersion: 9
      )
    }
  }

  @Test("SwiftData checkpoint snapshots bind sidecar metadata into the digest")
  func swiftDataCheckpointSnapshotsBindSidecarMetadataIntoDigest() throws {
    let original = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: Self.checkpoint(),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 2
    )
    let tampered = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: original.checkpointID,
      checkpointKey: original.checkpointKey,
      authorityBoundaryID: "workspace:other",
      policyVersion: original.policyVersion,
      checkpointFormatVersion: original.checkpointFormatVersion,
      compatibilityRevision: original.compatibilityRevision,
      savedAt: original.savedAt,
      storedAt: original.storedAt,
      canonicalCheckpointData: original.canonicalCheckpointData,
      checkpointDigest: original.checkpointDigest
    )

    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.self) {
      _ = try tampered.decodeCheckpoint(
        expectedAuthorityBoundaryID: "workspace:other",
        expectedPolicyVersion: 2
      )
    }

    let replayedID = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!,
      checkpointKey: original.checkpointKey,
      authorityBoundaryID: original.authorityBoundaryID,
      policyVersion: original.policyVersion,
      checkpointFormatVersion: original.checkpointFormatVersion,
      compatibilityRevision: original.compatibilityRevision,
      savedAt: original.savedAt,
      storedAt: original.storedAt,
      canonicalCheckpointData: original.canonicalCheckpointData,
      checkpointDigest: original.checkpointDigest
    )
    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.self) {
      _ = try replayedID.decodeCheckpoint(
        expectedAuthorityBoundaryID: "workspace:coreagent",
        expectedPolicyVersion: 2
      )
    }
  }

  @Test("SwiftData checkpoint snapshots reject payload metadata mismatches")
  func swiftDataCheckpointSnapshotsRejectPayloadMetadataMismatches() throws {
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: Self.checkpoint(),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 2
    )
    let formatDigest = CoreAgentSwiftDataCheckpointSnapshot.digest(
      checkpointID: snapshot.checkpointID,
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion,
      checkpointFormatVersion: 999,
      compatibilityRevision: snapshot.compatibilityRevision,
      savedAt: snapshot.savedAt,
      canonicalCheckpointData: snapshot.canonicalCheckpointData
    )
    let formatMismatch = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: snapshot.checkpointID,
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion,
      checkpointFormatVersion: 999,
      compatibilityRevision: snapshot.compatibilityRevision,
      savedAt: snapshot.savedAt,
      storedAt: snapshot.storedAt,
      canonicalCheckpointData: snapshot.canonicalCheckpointData,
      checkpointDigest: formatDigest
    )

    #expect(
      throws: CoreAgentSwiftDataCheckpointAccessError.formatVersionMismatch(
        expected: 999,
        actual: CoreAgentCheckpoint.currentFormatVersion
      )
    ) {
      _ = try formatMismatch.decodeCheckpoint(
        expectedAuthorityBoundaryID: "workspace:coreagent",
        expectedPolicyVersion: 2
      )
    }

    let sidecarSavedAt = snapshot.savedAt.addingTimeInterval(60)
    let savedAtDigest = CoreAgentSwiftDataCheckpointSnapshot.digest(
      checkpointID: snapshot.checkpointID,
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion,
      checkpointFormatVersion: snapshot.checkpointFormatVersion,
      compatibilityRevision: snapshot.compatibilityRevision,
      savedAt: sidecarSavedAt,
      canonicalCheckpointData: snapshot.canonicalCheckpointData
    )
    let savedAtMismatch = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: snapshot.checkpointID,
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion,
      checkpointFormatVersion: snapshot.checkpointFormatVersion,
      compatibilityRevision: snapshot.compatibilityRevision,
      savedAt: sidecarSavedAt,
      storedAt: snapshot.storedAt,
      canonicalCheckpointData: snapshot.canonicalCheckpointData,
      checkpointDigest: savedAtDigest
    )

    #expect(
      throws: CoreAgentSwiftDataCheckpointAccessError.savedAtMismatch(
        expected: sidecarSavedAt,
        actual: snapshot.savedAt
      )
    ) {
      _ = try savedAtMismatch.decodeCheckpoint(
        expectedAuthorityBoundaryID: "workspace:coreagent",
        expectedPolicyVersion: 2
      )
    }
  }

  @Test("SwiftData checkpoint records expose indexed metadata without rebuilding canonical data")
  func swiftDataCheckpointRecordsExposeIndexedMetadataWithoutRebuildingCanonicalData() throws {
    let checkpoint = Self.checkpoint()
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: checkpoint,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 2,
      storedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let record = CoreAgentSwiftDataCheckpointRecord(snapshot: snapshot)
    let restored = try record.snapshot.decodeCheckpoint(
      expectedAuthorityBoundaryID: "workspace:coreagent",
      expectedPolicyVersion: 2
    )

    #expect(record.checkpointKey == "thread/session")
    #expect(record.authorityBoundaryID == "workspace:coreagent")
    #expect(record.policyVersion == 2)
    #expect(record.checkpointDigest == snapshot.checkpointDigest)
    #expect(record.encodedCheckpoint == snapshot.canonicalCheckpointData)
    #expect(restored.transcript == checkpoint.transcript)
  }

  @MainActor
  @Test("SwiftData checkpoint records round trip through an in-memory ModelContext")
  func swiftDataCheckpointRecordsRoundTripThroughInMemoryModelContext() throws {
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/model-context",
      checkpoint: checkpoint,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let container = try ModelContainer(
      for: CoreAgentSwiftDataCheckpointRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)

    context.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: snapshot))
    try context.save()

    let fetched = try #require(
      try context.fetch(
        FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>()
      ).first)
    let restored = try fetched.snapshot.decodeCheckpoint(
      expectedAuthorityBoundaryID: "workspace:coreagent",
      expectedPolicyVersion: 4
    )

    #expect(fetched.checkpointID == snapshot.checkpointID)
    #expect(restored.savedAt == checkpoint.savedAt)
    #expect(restored.transcript == checkpoint.transcript)
  }

  @MainActor
  @Test("SwiftData checkpoint store saves loads and removes scoped checkpoints")
  func swiftDataCheckpointStoreSavesLoadsAndRemovesScopedCheckpoints() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100))

    try await store.saveCheckpoint(checkpoint, for: "thread/session")
    let restored = try #require(try await store.loadCheckpoint(for: "thread/session"))

    #expect(restored.savedAt == checkpoint.savedAt)
    #expect(restored.transcript == checkpoint.transcript)

    try await store.removeCheckpoint(for: "thread/session")
    #expect(try await store.loadCheckpoint(for: "thread/session") == nil)
    #expect(try context.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>()).isEmpty)
  }

  @MainActor
  @Test("SwiftData checkpoint store replaces the latest checkpoint for a scoped key")
  func swiftDataCheckpointStoreReplacesLatestCheckpointForScopedKey() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )

    try await store.saveCheckpoint(
      Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100)),
      for: "thread/session"
    )
    let latest = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_200))
    try await store.saveCheckpoint(latest, for: "thread/session")

    let restored = try #require(try await store.loadCheckpoint(for: "thread/session"))
    let records = try context.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>())
    let scopeKey = CoreAgentSwiftDataCheckpointRecord.scopeKey(
      checkpointKey: "thread/session",
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )

    #expect(restored.savedAt == latest.savedAt)
    #expect(records.filter { $0.scopeKey == scopeKey }.count == 1)
  }

  @MainActor
  @Test("SwiftData checkpoint store collapses duplicate scoped rows deterministically")
  func swiftDataCheckpointStoreCollapsesDuplicateScopedRowsDeterministically() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let older = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let latest = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_200))
    context.insert(
      CoreAgentSwiftDataCheckpointRecord(
        snapshot: try CoreAgentSwiftDataCheckpointSnapshot(
          checkpointKey: "thread/session",
          checkpoint: older,
          authorityBoundaryID: "workspace:coreagent",
          policyVersion: 4
        )))
    context.insert(
      CoreAgentSwiftDataCheckpointRecord(
        snapshot: try CoreAgentSwiftDataCheckpointSnapshot(
          checkpointKey: "thread/session",
          checkpoint: latest,
          authorityBoundaryID: "workspace:coreagent",
          policyVersion: 4
        )))
    try context.save()

    let restored = try #require(try await store.loadCheckpoint(for: "thread/session"))
    #expect(restored.savedAt == latest.savedAt)

    let replacement = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_300))
    try await store.saveCheckpoint(replacement, for: "thread/session")
    let scopeKey = CoreAgentSwiftDataCheckpointRecord.scopeKey(
      checkpointKey: "thread/session",
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let scopedRecords = try context.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>())
      .filter { $0.scopeKey == scopeKey }

    #expect(scopedRecords.count == 1)
    #expect(
      try scopedRecords.first?.snapshot.decodeCheckpoint(
        expectedAuthorityBoundaryID: "workspace:coreagent",
        expectedPolicyVersion: 4
      ).savedAt == replacement.savedAt)
  }

  @MainActor
  @Test("SwiftData checkpoint store scopes load and remove by authority policy")
  func swiftDataCheckpointStoreScopesLoadAndRemoveByAuthorityPolicy() async throws {
    let context = try Self.swiftDataContext()
    let scopedStore = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let otherAuthorityStore = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:other",
      policyVersion: 4
    )
    let otherPolicyStore = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 5
    )
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100))

    try await scopedStore.saveCheckpoint(checkpoint, for: "thread/session")
    try await otherAuthorityStore.saveCheckpoint(
      Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_200)),
      for: "thread/session"
    )
    try await otherPolicyStore.saveCheckpoint(
      Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_300)),
      for: "thread/session"
    )

    #expect(
      try await scopedStore.loadCheckpoint(for: "thread/session")?.savedAt == checkpoint.savedAt)
    #expect(
      try await otherAuthorityStore.loadCheckpoint(for: "thread/session")?.savedAt
        == Date(timeIntervalSince1970: 1_700_000_200))
    #expect(
      try await otherPolicyStore.loadCheckpoint(for: "thread/session")?.savedAt
        == Date(timeIntervalSince1970: 1_700_000_300))

    let crossScopeSnapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_400)),
      authorityBoundaryID: "workspace:other",
      policyVersion: 5
    )
    let corruptedCrossScope = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: crossScopeSnapshot.checkpointID,
      checkpointKey: crossScopeSnapshot.checkpointKey,
      authorityBoundaryID: crossScopeSnapshot.authorityBoundaryID,
      policyVersion: crossScopeSnapshot.policyVersion,
      checkpointFormatVersion: crossScopeSnapshot.checkpointFormatVersion,
      compatibilityRevision: crossScopeSnapshot.compatibilityRevision,
      savedAt: crossScopeSnapshot.savedAt,
      storedAt: crossScopeSnapshot.storedAt,
      canonicalCheckpointData: crossScopeSnapshot.canonicalCheckpointData,
      checkpointDigest: "sha256:cross-scope-corruption"
    )
    context.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: corruptedCrossScope))
    try context.save()

    #expect(
      try await scopedStore.loadCheckpoint(for: "thread/session")?.savedAt == checkpoint.savedAt)

    try await otherAuthorityStore.removeCheckpoint(for: "thread/session")
    let restored = try #require(try await scopedStore.loadCheckpoint(for: "thread/session"))
    #expect(restored.savedAt == checkpoint.savedAt)
  }

  @MainActor
  @Test("SwiftData checkpoint store fails closed on corrupted scoped records")
  func swiftDataCheckpointStoreFailsClosedOnCorruptedScopedRecords() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let snapshot = try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: checkpoint,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let corrupted = CoreAgentSwiftDataCheckpointSnapshot(
      checkpointID: snapshot.checkpointID,
      checkpointKey: snapshot.checkpointKey,
      authorityBoundaryID: snapshot.authorityBoundaryID,
      policyVersion: snapshot.policyVersion,
      checkpointFormatVersion: snapshot.checkpointFormatVersion,
      compatibilityRevision: snapshot.compatibilityRevision,
      savedAt: snapshot.savedAt,
      storedAt: snapshot.storedAt,
      canonicalCheckpointData: snapshot.canonicalCheckpointData,
      checkpointDigest: "sha256:corrupted"
    )

    context.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: corrupted))
    try context.save()

    await #expect(throws: CoreAgentSwiftDataCheckpointAccessError.self) {
      _ = try await store.loadCheckpoint(for: "thread/session")
    }
  }

  @Test("SwiftData checkpoint store works through the portable checkpoint store protocol")
  func swiftDataCheckpointStoreWorksThroughPortableCheckpointStoreProtocol() async throws {
    let store: any CoreAgentCheckpointStore = try await MainActor.run {
      let context = try Self.swiftDataContext()
      return CoreAgentSwiftDataCheckpointStore(
        modelContext: context,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 4
      )
    }
    let checkpoint = Self.checkpoint(savedAt: Date(timeIntervalSince1970: 1_700_000_100))

    try await store.saveCheckpoint(checkpoint, for: "thread/session")
    let restored = try #require(try await store.loadCheckpoint(for: "thread/session"))

    #expect(restored.savedAt == checkpoint.savedAt)
  }

  @MainActor
  @Test("CoreAgentSession restores native transcript history from SwiftData checkpoint store")
  func coreAgentSessionRestoresNativeTranscriptHistoryFromSwiftDataCheckpointStore() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let firstModel = RecordedLanguageModel(steps: [.response(text: "first")])
    let firstSession = try CoreAgentSession(
      model: firstModel,
      instructions: Instructions("Persist this instruction."),
      checkpointStore: store,
      checkpointKey: "thread/session"
    )

    _ = try await firstSession.respond(to: "One")

    let recordsAfterFirstRun = try context.fetch(
      FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>()
    )
    #expect(recordsAfterFirstRun.count == 1)

    let secondModel = RecordedLanguageModel(steps: [.response(text: "second")])
    let secondSession = try CoreAgentSession(
      model: secondModel,
      checkpointStore: store,
      checkpointKey: "thread/session"
    )

    _ = try await secondSession.respond(to: "Two")

    let restoredRequest = try #require(secondModel.recorder.capturedTranscripts().first)
    #expect(restoredRequest.history.count >= 3)
    #expect(
      restoredRequest.contains { entry in
        if case .instructions = entry { return true }
        return false
      })
  }

  @MainActor
  @Test("SwiftData checkpoint store rejects lossy typed metadata before inserting rows")
  func swiftDataCheckpointStoreRejectsLossyTypedMetadataBeforeInsertingRows() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: "revision-a",
      transcript: Transcript(entries: [
        .prompt(
          .init(
            metadata: ["provider_flag": true],
            segments: [.text(.init(content: "typed metadata"))]
          )
        )
      ])
    )

    await #expect(throws: CoreAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "lossy")
    }
    #expect(try context.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>()).isEmpty)
  }

}
