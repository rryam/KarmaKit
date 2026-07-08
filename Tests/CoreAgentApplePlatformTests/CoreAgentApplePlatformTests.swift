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

    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.authorityBoundaryMismatch(
      expected: "user:basit/device:mac",
      actual: "user:other/device:mac"
    )) {
      _ = try snapshot.decodeCheckpoint(
        expectedAuthorityBoundaryID: "user:basit/device:mac",
        expectedPolicyVersion: 4
      )
    }

    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.policyVersionMismatch(
      expected: 9,
      actual: 4
    )) {
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

    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.formatVersionMismatch(
      expected: 999,
      actual: CoreAgentCheckpoint.currentFormatVersion
    )) {
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

    #expect(throws: CoreAgentSwiftDataCheckpointAccessError.savedAtMismatch(
      expected: sidecarSavedAt,
      actual: snapshot.savedAt
    )) {
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

    let fetched = try #require(try context.fetch(
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
    context.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: try CoreAgentSwiftDataCheckpointSnapshot(
      checkpointKey: "thread/session",
      checkpoint: older,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )))
    context.insert(CoreAgentSwiftDataCheckpointRecord(snapshot: try CoreAgentSwiftDataCheckpointSnapshot(
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
    #expect(try scopedRecords.first?.snapshot.decodeCheckpoint(
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

    #expect(try await scopedStore.loadCheckpoint(for: "thread/session")?.savedAt == checkpoint.savedAt)
    #expect(try await otherAuthorityStore.loadCheckpoint(for: "thread/session")?.savedAt
      == Date(timeIntervalSince1970: 1_700_000_200))
    #expect(try await otherPolicyStore.loadCheckpoint(for: "thread/session")?.savedAt
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

    #expect(try await scopedStore.loadCheckpoint(for: "thread/session")?.savedAt == checkpoint.savedAt)

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
    #expect(restoredRequest.contains { entry in
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

  @MainActor
  @Test("SwiftData checkpoint store rejects custom transcript segments before inserting rows")
  func swiftDataCheckpointStoreRejectsCustomTranscriptSegmentsBeforeInsertingRows() async throws {
    let context = try Self.swiftDataContext()
    let store = CoreAgentSwiftDataCheckpointStore(
      modelContext: context,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 4
    )
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: "revision-a",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [
          .custom(ApplePlatformTestCustomSegment(
            id: "video",
            content: .init(value: "provider-specific")
          ))
        ]))
      ])
    )

    await #expect(throws: CoreAgentCheckpointStoreError.self) {
      try await store.saveCheckpoint(checkpoint, for: "custom")
    }
    #expect(try context.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>()).isEmpty)
  }

  @Test("Apple action gate separates code sandboxing from computer-use consent")
  func appleActionGateSeparatesCodeSandboxingFromComputerUseConsent() {
    let codeSandbox = CoreAgentAppleSandboxProfile(
      capabilities: [.deterministicCodeInterpreter],
      workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
      networkPolicy: .denied
    )
    let codeGate = CoreAgentAppleActionGate(sandbox: codeSandbox)

    #expect(codeGate.evaluate(
      .codeInterpreter(tier: .deterministicInProcess),
      consent: .notRequired
    ).isAllowed)

    #expect(codeGate.evaluate(
      .computerUse(actionID: "click-toolbar-save"),
      consent: .granted(Self.receipt(
        id: "receipt-1",
        requirement: CoreAgentAppleConsentRequirement(
          authorityBoundaryID: "default",
          policyVersion: 1,
          capability: .computerUse,
          requestFingerprint: "computer-use"
        )
      ))
    ) == .denied(.missingCapability(.computerUse)))

    let automationGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )

    #expect(automationGate.evaluate(
      .computerUse(actionID: "click-toolbar-save"),
      consent: .notRequired
    ) == .denied(.missingConsent(.computerUse)))
    let requirement = automationGate.consentRequirement(
      for: .computerUse(actionID: "click-toolbar-save")
    )
    #expect(automationGate.evaluate(
      .computerUse(actionID: "click-toolbar-save"),
      consent: .granted(Self.receipt(id: "receipt-2", requirement: requirement))
    ).isAllowed)
  }

  @Test("Action gate rejects reused empty or expired consent receipts")
  func actionGateRejectsReusedEmptyOrExpiredConsentReceipts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse, .remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .allowed,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 3
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let request = CoreAgentAppleExecutionRequest.computerUse(actionID: "click-toolbar-save")
    let requirement = gate.consentRequirement(for: request)

    let wrongCapabilityRequirement = CoreAgentAppleConsentRequirement(
      authorityBoundaryID: requirement.authorityBoundaryID,
      policyVersion: requirement.policyVersion,
      capability: .remoteCodeInterpreter,
      requestFingerprint: requirement.requestFingerprint
    )
    let wrongCapability = Self.receipt(id: "receipt-1", requirement: wrongCapabilityRequirement)
    #expect(gate.evaluate(request, consent: .granted(wrongCapability)) == .denied(
      .consentCapabilityMismatch(expected: .computerUse, actual: .remoteCodeInterpreter)
    ))

    let otherActionRequirement = gate.consentRequirement(
      for: .computerUse(actionID: "click-toolbar-open")
    )
    #expect(gate.evaluate(
      request,
      consent: .granted(Self.receipt(id: "receipt-2", requirement: otherActionRequirement))
    ) == .denied(.consentRequestMismatch(
      expected: requirement.requestFingerprint,
      actual: otherActionRequirement.requestFingerprint
    )))

    #expect(gate.evaluate(
      request,
      consent: .granted(Self.receipt(id: " ", requirement: requirement))
    ) == .denied(.invalidConsentReceipt("empty receipt id")))

    #expect(gate.evaluate(
      request,
      consent: .granted(Self.receipt(
        id: "receipt-3",
        requirement: requirement,
        expiresAt: now.addingTimeInterval(-1)
      ))
    ) == .denied(.expiredConsentReceipt("receipt-3")))

    let noExpiry = CoreAgentAppleConsentReceipt(
      id: "receipt-4",
      issuerID: Self.issuerID,
      authorityBoundaryID: requirement.authorityBoundaryID,
      policyVersion: requirement.policyVersion,
      capability: requirement.capability,
      requestFingerprint: requirement.requestFingerprint,
      grantedAt: Self.grantedAt,
      expiresAt: nil,
      signature: "legacy-unsigned-receipt"
    )
    #expect(gate.evaluate(request, consent: .granted(noExpiry)) == .denied(
      .missingConsentExpiry("receipt-4")
    ))
  }

  @Test("Action gate consumes receipts once and rejects future grants")
  func actionGateConsumesReceiptsOnceAndRejectsFutureGrants() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 3
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let request = CoreAgentAppleExecutionRequest.computerUse(actionID: "click-toolbar-save")
    let requirement = gate.consentRequirement(for: request)
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "receipt-once",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )

    #expect(gate.evaluate(request, consent: .granted(receipt)).isAllowed)
    #expect(gate.evaluate(request, consent: .granted(receipt)) == .denied(
      .reusedConsentReceipt("receipt-once")
    ))

    let futureReceipt = CoreAgentAppleConsentReceipt.issue(
      id: "receipt-future",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(60),
      expiresAt: now.addingTimeInterval(120)
    )
    #expect(gate.evaluate(request, consent: .granted(futureReceipt)) == .denied(
      .notYetValidConsentReceipt("receipt-future")
    ))
  }

  @Test("Consent signing keys reject weak material")
  func consentSigningKeysRejectWeakMaterial() {
    #expect(CoreAgentAppleConsentSigningKey(Data()) == nil)
    #expect(CoreAgentAppleConsentSigningKey(Data(repeating: 0x41, count: 31)) == nil)
    #expect(CoreAgentAppleConsentSigningKey(Data(repeating: 0x41, count: 32)) != nil)
  }

  @Test("Action gate rejects authority policy issuer and signature mismatches")
  func actionGateRejectsAuthorityPolicyIssuerAndSignatureMismatches() {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 5
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let request = CoreAgentAppleExecutionRequest.computerUse(actionID: "click-toolbar-save")
    let requirement = gate.consentRequirement(for: request)

    let wrongAuthority = Self.receipt(
      id: "receipt-authority",
      requirement: CoreAgentAppleConsentRequirement(
        authorityBoundaryID: "workspace:other",
        policyVersion: requirement.policyVersion,
        capability: requirement.capability,
        requestFingerprint: requirement.requestFingerprint
      )
    )
    #expect(gate.evaluate(request, consent: .granted(wrongAuthority)) == .denied(
      .consentAuthorityBoundaryMismatch(
        expected: "workspace:coreagent",
        actual: "workspace:other"
      )
    ))

    let wrongPolicy = Self.receipt(
      id: "receipt-policy",
      requirement: CoreAgentAppleConsentRequirement(
        authorityBoundaryID: requirement.authorityBoundaryID,
        policyVersion: 4,
        capability: requirement.capability,
        requestFingerprint: requirement.requestFingerprint
      )
    )
    #expect(gate.evaluate(request, consent: .granted(wrongPolicy)) == .denied(
      .consentPolicyVersionMismatch(expected: 5, actual: 4)
    ))

    let wrongIssuer = CoreAgentAppleConsentReceipt.issue(
      id: "receipt-issuer",
      issuerID: "other-issuer",
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: Self.grantedAt,
      expiresAt: .distantFuture
    )
    #expect(gate.evaluate(request, consent: .granted(wrongIssuer)) == .denied(
      .untrustedConsentIssuer(expected: Self.issuerID, actual: "other-issuer")
    ))

    let wrongSignature = CoreAgentAppleConsentReceipt.issue(
      id: "receipt-signature",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: CoreAgentAppleConsentSigningKey(Data(repeating: 0x42, count: 32))!,
      grantedAt: Self.grantedAt,
      expiresAt: .distantFuture
    )
    #expect(gate.evaluate(request, consent: .granted(wrongSignature)) == .denied(
      .invalidConsentSignature("receipt-signature")
    ))

    let noVerifierGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 5
      ),
      trustedConsentIssuerID: Self.issuerID
    )
    let noVerifierRequirement = noVerifierGate.consentRequirement(for: request)
    #expect(noVerifierGate.evaluate(
      request,
      consent: .granted(Self.receipt(id: "receipt-no-verifier", requirement: noVerifierRequirement))
    ) == .denied(.consentVerifierUnavailable(.computerUse)))
  }

  @Test("App Intent descriptors cannot bypass authorization HITL or foreground execution")
  func appIntentDescriptorsCannotBypassAuthorizationHITLOrForegroundExecution() throws {
    let descriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Task",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app, .siri],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )

    #expect(try descriptor.validatedForAgentExposure().identifier == descriptor.identifier)

    let backgroundMutation = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentDeleteTaskIntent",
      title: "Delete Task",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.background],
      supportedModes: [.siri],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
    #expect(throws: CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(
      identifier: "CoreAgentDeleteTaskIntent"
    )) {
      _ = try backgroundMutation.validatedForAgentExposure()
    }

    let missingAuthorization = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Task",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: true
    )
    #expect(throws: CoreAgentAppIntentDescriptorError.authorizationRequired(
      identifier: "CoreAgentCreateTaskIntent"
    )) {
      _ = try missingAuthorization.validatedForAgentExposure()
    }

    let notExposed = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentHiddenIntent",
      title: "Hidden",
      mutability: .readOnly,
      allowsAgentExecution: false,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    #expect(throws: CoreAgentAppIntentDescriptorError.agentExposureRequired(
      identifier: "CoreAgentHiddenIntent"
    )) {
      _ = try notExposed.validatedForAgentExposure()
    }
  }

  @Test("Action gate validates App Intent descriptor mode and execution target")
  func actionGateValidatesAppIntentDescriptorModeAndExecutionTarget() {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.appIntentExecution],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let descriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Task",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground, .background],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
    let foregroundRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .app,
      target: .foreground
    )
    let foregroundRequirement = gate.consentRequirement(for: foregroundRequest)

    #expect(gate.evaluate(
      foregroundRequest,
      consent: .granted(Self.receipt(id: "intent-receipt-1", requirement: foregroundRequirement))
    ).isAllowed)

    let backgroundRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .app,
      target: .background
    )
    #expect(gate.evaluate(
      backgroundRequest,
      consent: .granted(Self.receipt(
        id: "intent-receipt-2",
        requirement: gate.consentRequirement(for: backgroundRequest)
      ))
    ) == .denied(.appIntentExecutionTargetRequiresForeground(
      identifier: "CoreAgentCreateTaskIntent",
      target: .background
    )))

    let unsupportedModeRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .siri,
      target: .foreground
    )
    #expect(gate.evaluate(
      unsupportedModeRequest,
      consent: .granted(Self.receipt(
        id: "intent-receipt-3",
        requirement: gate.consentRequirement(for: unsupportedModeRequest)
      ))
    ) == .denied(.unsupportedAppIntentMode(
      identifier: "CoreAgentCreateTaskIntent",
      mode: .siri
    )))
  }

  @Test("Action gate rejects remote code when network policy is not allowed")
  func actionGateRejectsRemoteCodeWhenNetworkPolicyIsNotAllowed() {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .localOnly
      )
    )

    #expect(gate.evaluate(
      .codeInterpreter(tier: .remote),
      consent: .notRequired
    ) == .denied(.remoteExecutionRequiresNetworkPolicy))
  }

  @Test("Deterministic code interpreter executes typed programs under action gate")
  func deterministicCodeInterpreterExecutesTypedProgramsUnderActionGate() async {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 7
      ),
      now: { now }
    )
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: gate, clock: { now })
    let request = CoreAgentAppleDeterministicCodeRequest(
      id: "calc-1",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .add("sum", .input("lhs"), .input("rhs")),
        .concatenate("message", [.literal(.string("sum=")), .variable("sum")]),
        .emit(.variable("message")),
        .output("sum", .variable("sum")),
      ]),
      inputs: [
        "lhs": .number(2.5),
        "rhs": .number(3.25),
      ],
      limits: .init(maxInstructionCount: 8, maxOutputBytes: 256)
    )

    let result = await interpreter.run(request)

    #expect(result.status == .succeeded)
    #expect(result.stdout == "sum=5.75\n")
    #expect(result.outputs == ["sum": .number(5.75)])
    #expect(result.audit.requestID == "calc-1")
    #expect(result.audit.tier == .deterministicInProcess)
    #expect(result.audit.authorityBoundaryID == "workspace:coreagent")
    #expect(result.audit.policyVersion == 7)
    #expect(result.audit.networkPolicy == .denied)
    #expect(result.audit.status == .succeeded)
    #expect(result.audit.programDigest.hasPrefix("sha256:"))
    #expect(result.audit.inputDigest.hasPrefix("sha256:"))
  }

  @Test("Deterministic code interpreter requires sandbox capability")
  func deterministicCodeInterpreterRequiresSandboxCapability() async {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    )
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: gate)
    let result = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "denied",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .emit(.literal(.string("should not run")))
      ]),
      limits: .init(maxInstructionCount: 4, maxOutputBytes: 128)
    ))

    #expect(result.status == .denied(.missingCapability(.deterministicCodeInterpreter)))
    #expect(result.stdout.isEmpty)
    #expect(result.outputs.isEmpty)
    #expect(result.audit.status == result.status)
  }

  @Test("Deterministic code interpreter enforces instruction and output bounds")
  func deterministicCodeInterpreterEnforcesInstructionAndOutputBounds() async {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    )
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: gate)
    let tooManyInstructions = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "too-many",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .set("first", .string("a")),
        .emit(.variable("first")),
      ]),
      limits: .init(maxInstructionCount: 1, maxOutputBytes: 128)
    ))
    let tooMuchOutput = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "too-much-output",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .emit(.literal(.string("abcdef")))
      ]),
      limits: .init(maxInstructionCount: 4, maxOutputBytes: 4)
    ))

    #expect(tooManyInstructions.status == .failed(
      .instructionLimitExceeded(max: 1, actual: 2)
    ))
    #expect(tooManyInstructions.stdout.isEmpty)
    #expect(tooMuchOutput.status == .failed(
      .outputLimitExceeded(max: 4, actual: 7)
    ))
    #expect(tooMuchOutput.outputs.isEmpty)
  }

  @Test("Deterministic code interpreter enforces intermediate state bounds")
  func deterministicCodeInterpreterEnforcesIntermediateStateBounds() async {
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    ))
    let oversizedLiteral = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "oversized-literal",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .set("value", .string("abcdef"))
      ]),
      limits: .init(
        maxInstructionCount: 4,
        maxOutputBytes: 128,
        maxStateBytes: 128,
        maxValueBytes: 4
      )
    ))
    let intermediateGrowth = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "intermediate-growth",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .set("chunk", .string("abcd")),
        .concatenate("expanded", [.variable("chunk"), .variable("chunk"), .variable("chunk")]),
      ]),
      limits: .init(
        maxInstructionCount: 4,
        maxOutputBytes: 128,
        maxStateBytes: 12,
        maxValueBytes: 64
      )
    ))

    #expect(oversizedLiteral.status == .failed(
      .valueLimitExceeded(max: 4, actual: 6)
    ))
    #expect(oversizedLiteral.stdout.isEmpty)
    #expect(intermediateGrowth.status == .failed(
      .stateLimitExceeded(max: 12, actual: 29)
    ))
    #expect(intermediateGrowth.stdout.isEmpty)
  }

  @Test("Deterministic code interpreter rejects path-shaped output names")
  func deterministicCodeInterpreterRejectsPathShapedOutputNames() async {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    )
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: gate)
    let result = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "path-output",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .output("../secret", .literal(.string("leak")))
      ]),
      limits: .init(maxInstructionCount: 4, maxOutputBytes: 128)
    ))

    #expect(result.status == .failed(.invalidOutputName("../secret")))
    #expect(result.outputs.isEmpty)
  }

  @Test("Deterministic code interpreter rejects non-finite inputs and literals")
  func deterministicCodeInterpreterRejectsNonFiniteInputsAndLiterals() async {
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    ))
    let nonFiniteInput = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "non-finite-input",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .emit(.input("bad"))
      ]),
      inputs: ["bad": .number(.nan)]
    ))
    let nonFiniteLiteral = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "non-finite-literal",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .output("value", .literal(.number(.infinity)))
      ])
    ))

    #expect(nonFiniteInput.status == .failed(.nonFiniteNumber("input:bad")))
    #expect(nonFiniteInput.stdout.isEmpty)
    #expect(nonFiniteLiteral.status == .failed(.nonFiniteNumber("literal")))
    #expect(nonFiniteLiteral.outputs.isEmpty)
  }

  @Test("Deterministic code interpreter honors cancellation and rejects unsafe identifiers")
  func deterministicCodeInterpreterHonorsCancellationAndRejectsUnsafeIdentifiers() async {
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(actionGate: CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.deterministicCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
        networkPolicy: .denied
      )
    ))
    let cancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
        id: "cancelled",
        program: CoreAgentAppleDeterministicProgram(instructions: [
          .set("value", .string("should not run"))
        ])
      ))
    }.value
    let invalidVariable = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "invalid-variable",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .set("bad/name", .string("value"))
      ])
    ))
    let duplicateOutput = await interpreter.run(CoreAgentAppleDeterministicCodeRequest(
      id: "duplicate-output",
      program: CoreAgentAppleDeterministicProgram(instructions: [
        .output("result", .literal(.string("first"))),
        .output("result", .literal(.string("second"))),
      ])
    ))

    #expect(cancelled.status == .failed(.cancelled))
    #expect(cancelled.stdout.isEmpty)
    #expect(invalidVariable.status == .failed(.invalidIdentifier("bad/name")))
    #expect(duplicateOutput.status == .failed(.duplicateOutputName("result")))
    #expect(duplicateOutput.outputs == ["result": .string("first")])
  }

  @Test("Helper code interpreter requires capability and request-bound consent")
  func helperCodeInterpreterRequiresCapabilityAndRequestBoundConsent() async {
    let now = Date(timeIntervalSince1970: 1_800_000_150)
    let helperURL = URL(fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-helper")
    let request = CoreAgentAppleHelperCodeInterpreterRequest(
      id: "helper-run-1",
      executableURL: helperURL,
      arguments: ["--mode", "python"],
      workingDirectory: workspace,
      standardInput: "print('ok')"
    )
    let recorder = HelperCodeRecorder()
    let deniedInterpreter = CoreAgentAppleHelperCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [],
          workspaceRoot: workspace,
          networkPolicy: .denied,
          authorityBoundaryID: "workspace:coreagent",
          policyVersion: 9
        )
      ),
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: Self.helperCodeBackend(recorder: recorder, stdout: "ok\n"),
      clock: { now }
    )
    let denied = await deniedInterpreter.run(request, consent: .notRequired)
    #expect(denied.status == .denied(.missingCapability(.helperCodeInterpreter)))
    #expect(await recorder.runCount == 0)

    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.helperCodeInterpreter],
        workspaceRoot: workspace,
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 9
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let interpreter = CoreAgentAppleHelperCodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: Self.helperCodeBackend(recorder: recorder, stdout: "ok\n"),
      clock: { now }
    )

    let missingConsent = await interpreter.run(request, consent: .notRequired)
    #expect(missingConsent.status == .denied(.missingConsent(.helperCodeInterpreter)))
    #expect(await recorder.runCount == 0)

    let broadRequirement = gate.consentRequirement(for: .codeInterpreter(tier: .helperProcess))
    let broadReceipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-broad-consent",
      issuerID: Self.issuerID,
      requirement: broadRequirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let broadConsent = await interpreter.run(request, consent: .granted(broadReceipt))
    let requestRequirement = interpreter.consentRequirement(for: request)
    #expect(broadConsent.status == .denied(.consentRequestMismatch(
      expected: requestRequirement.requestFingerprint,
      actual: broadRequirement.requestFingerprint
    )))
    #expect(await recorder.runCount == 0)

    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-run-consent",
      issuerID: Self.issuerID,
      requirement: requestRequirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let allowed = await interpreter.run(request, consent: .granted(receipt))

    #expect(allowed.status == .succeeded)
    #expect(allowed.stdout == "ok\n")
    #expect(allowed.outputs == ["result": .string("ok")])
    #expect(allowed.audit.requestID == "helper-run-1")
    #expect(allowed.audit.tier == .helperProcess)
    #expect(allowed.audit.authorityBoundaryID == "workspace:coreagent")
    #expect(allowed.audit.policyVersion == 9)
    #expect(allowed.audit.programDigest.hasPrefix("sha256:"))
    #expect(allowed.audit.inputDigest.hasPrefix("sha256:"))
    #expect(await recorder.runCount == 1)
    let authorized = await recorder.lastRequest
    #expect(authorized?.canonicalExecutableURL == Self.canonicalTestURL(helperURL))
    #expect(authorized?.canonicalWorkingDirectory == Self.canonicalTestURL(workspace))
    #expect(authorized?.programDigest == allowed.audit.programDigest)
    #expect(authorized?.inputDigest == allowed.audit.inputDigest)
  }

  @Test("Helper code interpreter validates executable allowlist and workspace")
  func helperCodeInterpreterValidatesExecutableAllowlistAndWorkspace() async {
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-helper")
    let helperURL = URL(fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
    let recorder = HelperCodeRecorder()
    let interpreter = CoreAgentAppleHelperCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.helperCodeInterpreter],
          workspaceRoot: workspace,
          networkPolicy: .denied
        ),
        trustedConsentIssuerID: Self.issuerID,
        consentSigningKey: Self.signingKey
      ),
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: Self.helperCodeBackend(recorder: recorder, stdout: "should not run\n")
    )

    let shellRequest = CoreAgentAppleHelperCodeInterpreterRequest(
      id: "shell",
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      workingDirectory: workspace,
      standardInput: "echo unsafe"
    )
    let shell = await interpreter.run(
      shellRequest,
      consent: .granted(Self.receipt(
        id: "helper-shell-consent",
        requirement: interpreter.consentRequirement(for: shellRequest)
      ))
    )
    let notAllowed = await interpreter.run(
      CoreAgentAppleHelperCodeInterpreterRequest(
        id: "not-allowed",
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        workingDirectory: workspace,
        standardInput: "print('not allowed')"
      ),
      consent: .notRequired
    )
    let outsideWorkspace = await interpreter.run(
      CoreAgentAppleHelperCodeInterpreterRequest(
        id: "outside-workspace",
        executableURL: helperURL,
        workingDirectory: URL(fileURLWithPath: "/tmp/other-workspace"),
        standardInput: "print('outside')"
      ),
      consent: .notRequired
    )

    #expect(shell.status == .failed(.blockedExecutableName("sh")))
    #expect(notAllowed.status == .failed(.executableNotAllowed(
      Self.canonicalTestURL(URL(fileURLWithPath: "/usr/bin/python3")).path
    )))
    #expect(outsideWorkspace.status == .failed(.workingDirectoryOutsideWorkspace(
      Self.canonicalTestURL(URL(fileURLWithPath: "/tmp/other-workspace")).path
    )))
    #expect(await recorder.runCount == 0)
  }

  @Test("Helper code interpreter enforces request and backend output bounds")
  func helperCodeInterpreterEnforcesRequestAndBackendOutputBounds() async {
    let now = Date(timeIntervalSince1970: 1_800_000_150)
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-helper")
    let helperURL = URL(fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.helperCodeInterpreter],
        workspaceRoot: workspace,
        networkPolicy: .denied
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let oversizedOutput = CoreAgentAppleHelperCodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: CoreAgentAppleHelperCodeInterpreterBackend { _ in
        CoreAgentAppleHelperCodeInterpreterBackendResult(
          exitCode: 0,
          stdout: "abcdef",
          stderr: "",
          outputs: [:]
        )
      },
      clock: { now }
    )
    let pathOutput = CoreAgentAppleHelperCodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: CoreAgentAppleHelperCodeInterpreterBackend { _ in
        CoreAgentAppleHelperCodeInterpreterBackendResult(
          exitCode: 0,
          stdout: "",
          stderr: "",
          outputs: ["../secret": .string("leak")]
        )
      },
      clock: { now }
    )
    let invalidRequest = await oversizedOutput.run(
      CoreAgentAppleHelperCodeInterpreterRequest(
        id: " ",
        executableURL: helperURL,
        workingDirectory: workspace
      ),
      consent: .notRequired
    )
    let request = CoreAgentAppleHelperCodeInterpreterRequest(
      id: "bounded-output",
      executableURL: helperURL,
      workingDirectory: workspace,
      limits: CoreAgentAppleHelperCodeInterpreterLimits(
        maxStdoutBytes: 4,
        maxOutputBytes: 64
      )
    )
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-bounds-consent",
      issuerID: Self.issuerID,
      requirement: oversizedOutput.consentRequirement(for: request),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let stdoutLimited = await oversizedOutput.run(request, consent: .granted(receipt))
    let pathReceipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-path-output-consent",
      issuerID: Self.issuerID,
      requirement: pathOutput.consentRequirement(for: request),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let invalidOutput = await pathOutput.run(request, consent: .granted(pathReceipt))

    #expect(invalidRequest.status == .failed(.invalidRequest("request id")))
    #expect(stdoutLimited.status == .failed(.stdoutLimitExceeded(max: 4, actual: 6)))
    #expect(stdoutLimited.stdout.isEmpty)
    #expect(invalidOutput.status == .failed(.invalidOutputName("../secret")))
    #expect(invalidOutput.outputs.isEmpty)
  }

  @Test("Helper code interpreter denies undeclared network and honors cancellation")
  func helperCodeInterpreterDeniesUndeclaredNetworkAndHonorsCancellation() async {
    let now = Date(timeIntervalSince1970: 1_800_000_150)
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-helper")
    let helperURL = URL(fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
    let localOnlyInterpreter = CoreAgentAppleHelperCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.helperCodeInterpreter],
          workspaceRoot: workspace,
          networkPolicy: .localOnly
        ),
        trustedConsentIssuerID: Self.issuerID,
        consentSigningKey: Self.signingKey,
        now: { now }
      ),
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: CoreAgentAppleHelperCodeInterpreterBackend { _ in
        CoreAgentAppleHelperCodeInterpreterBackendResult(
          exitCode: 0,
          stdout: "should not run\n",
          stderr: "",
          outputs: [:]
        )
      },
      clock: { now }
    )
    let remoteRequest = CoreAgentAppleHelperCodeInterpreterRequest(
      id: "remote-network",
      executableURL: helperURL,
      workingDirectory: workspace,
      networkAccess: .remote
    )
    let deniedNetwork = await localOnlyInterpreter.run(remoteRequest, consent: .notRequired)

    let recorder = HelperCodeRecorder()
    let cancellableInterpreter = CoreAgentAppleHelperCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.helperCodeInterpreter],
          workspaceRoot: workspace,
          networkPolicy: .denied
        ),
        trustedConsentIssuerID: Self.issuerID,
        consentSigningKey: Self.signingKey,
        now: { now }
      ),
      policy: CoreAgentAppleHelperCodeInterpreterPolicy(
        allowedExecutableURLs: [helperURL]
      ),
      backend: CoreAgentAppleHelperCodeInterpreterBackend { request in
        _ = await recorder.record(request)
        throw CancellationError()
      },
      clock: { now }
    )
    let cancellableRequest = CoreAgentAppleHelperCodeInterpreterRequest(
      id: "cancelled",
      executableURL: helperURL,
      workingDirectory: workspace
    )
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-cancel-consent",
      issuerID: Self.issuerID,
      requirement: cancellableInterpreter.consentRequirement(for: cancellableRequest),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let preCancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await cancellableInterpreter.run(cancellableRequest, consent: .granted(receipt))
    }.value
    let cancellationReceipt = CoreAgentAppleConsentReceipt.issue(
      id: "helper-backend-cancel-consent",
      issuerID: Self.issuerID,
      requirement: cancellableInterpreter.consentRequirement(for: cancellableRequest),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let backendCancelled = await cancellableInterpreter.run(
      cancellableRequest,
      consent: .granted(cancellationReceipt)
    )

    #expect(deniedNetwork.status == .failed(.networkAccessDenied(
      requested: .remote,
      policy: .localOnly
    )))
    #expect(preCancelled.status == .failed(.cancelled))
    #expect(backendCancelled.status == .failed(.cancelled))
    #expect(await recorder.runCount == 1)
  }


  @Test("WASI code interpreter fails closed without backend and enforces policy")
  func wasiCodeInterpreterFailsClosedWithoutBackendAndEnforcesPolicy() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_160)
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-wasi")
    let moduleURL = workspace.appending(path: "module.wasm")
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.wasiCodeInterpreter],
        workspaceRoot: workspace,
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 10
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let interpreter = CoreAgentAppleWASICodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleWASICodeInterpreterPolicy(
        allowedModuleURLs: [moduleURL]
      ),
      clock: { now }
    )
    let request = CoreAgentAppleWASICodeInterpreterRequest(
      id: "wasi-1",
      moduleURL: moduleURL
    )
    let requirement = interpreter.consentRequirement(for: request)
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "wasi-receipt",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let denied = await interpreter.run(request, consent: .granted(receipt))
    let outside = await interpreter.run(
      CoreAgentAppleWASICodeInterpreterRequest(
        id: "wasi-2",
        moduleURL: URL(fileURLWithPath: "/etc/passwd")
      ),
      consent: .granted(receipt)
    )

    #expect(denied.status == .failed(.invalidRequest("wasi backend unavailable")))
    #expect(outside.status == .failed(.invalidRequest("module not allowed")))
  }

  @Test("WASI code interpreter runs through authorized backend")
  func wasiCodeInterpreterRunsThroughAuthorizedBackend() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_161)
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-wasi-run")
    let moduleURL = workspace.appending(path: "module.wasm")
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.wasiCodeInterpreter],
        workspaceRoot: workspace,
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 10
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let backend = CoreAgentAppleWASICodeInterpreterBackend { authorized in
      #expect(authorized.canonicalModuleURL == moduleURL.standardizedFileURL)
      return CoreAgentAppleWASICodeInterpreterBackendResult(
        exitCode: 0,
        stdout: "ok",
        stderr: ""
      )
    }
    let interpreter = CoreAgentAppleWASICodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleWASICodeInterpreterPolicy(allowedModuleURLs: [moduleURL]),
      backend: backend,
      clock: { now }
    )
    let request = CoreAgentAppleWASICodeInterpreterRequest(
      id: "wasi-run-1",
      moduleURL: moduleURL,
      standardInput: "input"
    )
    let requirement = interpreter.consentRequirement(for: request)
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "wasi-run-receipt",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let result = await interpreter.run(request, consent: .granted(receipt))

    #expect(result.status == CoreAgentAppleCodeInterpreterStatus.succeeded)
    #expect(result.stdout == "ok")
    #expect(result.audit.tier == CoreAgentAppleInterpreterTier.wasiWebAssembly)
  }

  @Test("Computer use dry run produces a plan without consent or side effects")
  func computerUseDryRunProducesPlanWithoutConsentOrSideEffects() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let recorder = ComputerUseRecorder()
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      now: { now }
    )
    let executor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: Self.computerUseBackend(recorder: recorder),
      clock: { now }
    )
    let request = CoreAgentAppleComputerUseRequest(
      id: "dry-run-1",
      actionID: "click-toolbar-save",
      mode: .dryRun
    )

    let result = await executor.run(request, consent: .notRequired)

    #expect(result.status == .planned)
    #expect(result.plan?.steps.map(\.id) == ["inspect", "click"])
    #expect(result.plan?.requiredEvidence == [.screenshotDigest])
    #expect(result.evidence.isEmpty)
    #expect(await recorder.planCount == 1)
    #expect(await recorder.executeCount == 0)
    #expect(result.audit.requestID == "dry-run-1")
    #expect(result.audit.actionID == "click-toolbar-save")
    #expect(result.audit.mode == .dryRun)
    #expect(result.audit.authorityBoundaryID == "workspace:coreagent")
    #expect(result.audit.policyVersion == 12)
    #expect(result.audit.status == .planned)
    #expect(result.audit.planDigest?.hasPrefix("sha256:") == true)
    #expect(result.audit.evidenceDigest == nil)
  }

  @Test("Computer use execution requires consent and records evidence")
  func computerUseExecutionRequiresConsentAndRecordsEvidence() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let recorder = ComputerUseRecorder()
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let executor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: Self.computerUseBackend(recorder: recorder),
      clock: { now }
    )
    let request = CoreAgentAppleComputerUseRequest(
      id: "execute-1",
      actionID: "click-toolbar-save",
      mode: .dryRun
    )
    let dryRun = await executor.run(request, consent: .notRequired)
    let approvedPlan = try #require(dryRun.plan)
    let approvedPlanDigest = try #require(dryRun.audit.planDigest)
    let executeRequest = CoreAgentAppleComputerUseRequest(
      id: "execute-1",
      actionID: "click-toolbar-save",
      mode: .execute,
      approvedPlan: approvedPlan,
      approvedPlanDigest: approvedPlanDigest
    )

    let denied = await executor.run(executeRequest, consent: .notRequired)
    #expect(denied.status == .denied(.missingConsent(.computerUse)))
    #expect(await recorder.planCount == 1)
    #expect(await recorder.executeCount == 0)

    let requirement = gate.consentRequirement(for: .computerUseExecution(
      actionID: executeRequest.actionID,
      approvedPlanDigest: approvedPlanDigest
    ))
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "computer-use-receipt",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let executed = await executor.run(executeRequest, consent: .granted(receipt))

    #expect(executed.status == .executed)
    #expect(executed.plan?.steps.count == 2)
    #expect(executed.evidence == [
      CoreAgentAppleComputerUseEvidence(
        kind: .screenshotDigest,
        digest: Self.screenshotDigest,
        capturedAt: now
      )
    ])
    #expect(await recorder.planCount == 1)
    #expect(await recorder.executeCount == 1)
    #expect(executed.audit.status == .executed)
    #expect(executed.audit.planDigest == approvedPlanDigest)
    #expect(executed.audit.evidenceDigest?.hasPrefix("sha256:") == true)
  }

  @Test("Computer use execution binds consent to the approved plan digest")
  func computerUseExecutionBindsConsentToTheApprovedPlanDigest() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let recorder = ComputerUseRecorder()
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let executor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: Self.computerUseBackend(recorder: recorder),
      clock: { now }
    )
    let dryRun = await executor.run(CoreAgentAppleComputerUseRequest(
      id: "dry-run-binding",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)
    let approvedPlan = try #require(dryRun.plan)
    let approvedPlanDigest = try #require(dryRun.audit.planDigest)
    let tamperedPlan = CoreAgentAppleComputerUsePlan(
      steps: [
        .init(id: "inspect", summary: "Inspect target state."),
        .init(id: "delete", summary: "Perform a different action."),
      ],
      requiredEvidence: [.screenshotDigest]
    )
    let tamperedRequest = CoreAgentAppleComputerUseRequest(
      id: "execute-tampered",
      actionID: "click-toolbar-save",
      mode: .execute,
      approvedPlan: tamperedPlan,
      approvedPlanDigest: approvedPlanDigest
    )

    let tampered = await executor.run(tamperedRequest, consent: .notRequired)

    #expect(tampered.status == .failed(.approvedPlanDigestMismatch))
    #expect(await recorder.executeCount == 0)

    let requirement = gate.consentRequirement(for: .computerUseExecution(
      actionID: "click-toolbar-save",
      approvedPlanDigest: approvedPlanDigest
    ))
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "computer-use-plan-bound",
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let unboundRequirement = gate.consentRequirement(for: .computerUse(actionID: "click-toolbar-save"))
    let unboundReceipt = CoreAgentAppleConsentReceipt.issue(
      id: "computer-use-unbound",
      issuerID: Self.issuerID,
      requirement: unboundRequirement,
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let approvedRequest = CoreAgentAppleComputerUseRequest(
      id: "execute-approved",
      actionID: "click-toolbar-save",
      mode: .execute,
      approvedPlan: approvedPlan,
      approvedPlanDigest: approvedPlanDigest
    )
    let unbound = await executor.run(approvedRequest, consent: .granted(unboundReceipt))
    let approved = await executor.run(approvedRequest, consent: .granted(receipt))

    #expect(unbound.status == .denied(.consentRequestMismatch(
      expected: requirement.requestFingerprint,
      actual: unboundRequirement.requestFingerprint
    )))
    #expect(approved.status == .executed)
  }

  @Test("Computer use executor denies missing capability and honors cancellation")
  func computerUseExecutorDeniesMissingCapabilityAndHonorsCancellation() async {
    let recorder = ComputerUseRecorder()
    let deniedExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: Self.computerUseBackend(recorder: recorder)
    )
    let request = CoreAgentAppleComputerUseRequest(
      id: "denied",
      actionID: "click-toolbar-save",
      mode: .dryRun
    )

    let denied = await deniedExecutor.run(request, consent: .notRequired)
    #expect(denied.status == .denied(.missingCapability(.computerUse)))
    #expect(await recorder.planCount == 0)
    #expect(await recorder.executeCount == 0)

    let allowedExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.computerUse],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: Self.computerUseBackend(recorder: recorder)
    )
    let cancelled = await Task {
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await allowedExecutor.run(request, consent: .notRequired)
    }.value
    let planningCancellationExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.computerUse],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in throw CancellationError() },
        execute: { _, _ in [] }
      )
    )
    let planningCancelled = await planningCancellationExecutor.run(
      request,
      consent: .notRequired
    )

    #expect(cancelled.status == .failed(.cancelled))
    #expect(planningCancelled.status == .failed(.cancelled))
    #expect(await recorder.planCount == 0)
    #expect(await recorder.executeCount == 0)
  }

  @Test("Computer use execution fails closed on missing or malformed evidence")
  func computerUseExecutionFailsClosedOnMissingOrMalformedEvidence() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let plan = CoreAgentAppleComputerUsePlan(
      steps: [.init(id: "inspect", summary: "Inspect target.")],
      requiredEvidence: [.screenshotDigest]
    )
    let missingEvidenceExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in plan },
        execute: { _, _ in [] }
      ),
      clock: { now }
    )
    let malformedEvidenceExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in plan },
        execute: { _, _ in [
          CoreAgentAppleComputerUseEvidence(
            kind: .screenshotDigest,
            digest: "sha256:not-hex",
            capturedAt: now
          )
        ] }
      ),
      clock: { now }
    )
    _ = await missingEvidenceExecutor.run(CoreAgentAppleComputerUseRequest(
      id: "dry-run-missing-evidence",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)
    _ = await malformedEvidenceExecutor.run(CoreAgentAppleComputerUseRequest(
      id: "dry-run-malformed-evidence",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)
    let request = CoreAgentAppleComputerUseRequest(
      id: "execute-evidence",
      actionID: "click-toolbar-save",
      mode: .execute,
      approvedPlan: plan,
      approvedPlanDigest: plan.digest
    )
    let requirement = gate.consentRequirement(for: .computerUseExecution(
      actionID: request.actionID,
      approvedPlanDigest: plan.digest
    ))
    let missing = await missingEvidenceExecutor.run(
      request,
      consent: .granted(CoreAgentAppleConsentReceipt.issue(
        id: "computer-use-missing-evidence",
        issuerID: Self.issuerID,
        requirement: requirement,
        signingKey: Self.signingKey,
        grantedAt: now.addingTimeInterval(-10),
        expiresAt: now.addingTimeInterval(60)
      ))
    )
    let malformed = await malformedEvidenceExecutor.run(
      request,
      consent: .granted(CoreAgentAppleConsentReceipt.issue(
        id: "computer-use-malformed-evidence",
        issuerID: Self.issuerID,
        requirement: requirement,
        signingKey: Self.signingKey,
        grantedAt: now.addingTimeInterval(-10),
        expiresAt: now.addingTimeInterval(60)
      ))
    )

    #expect(missing.status == .failed(.missingEvidence(kind: .screenshotDigest)))
    #expect(missing.evidence.isEmpty)
    #expect(malformed.status == .failed(.invalidEvidenceDigest(kind: .screenshotDigest)))
    #expect(malformed.evidence.count == 1)
  }

  @Test("Computer use executor validates request and plan structure")
  func computerUseExecutorValidatesRequestAndPlanStructure() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let recorder = ComputerUseRecorder()
    let executor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.computerUse],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: Self.computerUseBackend(recorder: recorder),
      clock: { now }
    )
    let invalidRequest = await executor.run(CoreAgentAppleComputerUseRequest(
      id: " ",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)
    let invalidPlanExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.computerUse],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in
          CoreAgentAppleComputerUsePlan(
            steps: [
              .init(id: "same", summary: "First."),
              .init(id: "same", summary: "Duplicate."),
            ],
            requiredEvidence: [.screenshotDigest]
          )
        },
        execute: { _, _ in [] }
      ),
      clock: { now }
    )
    let invalidPlan = await invalidPlanExecutor.run(CoreAgentAppleComputerUseRequest(
      id: "invalid-plan",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)
    let missingBaselineExecutor = CoreAgentAppleComputerUseExecutor(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.computerUse],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
          networkPolicy: .denied
        )
      ),
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in
          CoreAgentAppleComputerUsePlan(
            steps: [.init(id: "inspect", summary: "Inspect target.")],
            requiredEvidence: []
          )
        },
        execute: { _, _ in [] }
      ),
      minimumRequiredEvidence: [],
      clock: { now }
    )
    let missingBaseline = await missingBaselineExecutor.run(CoreAgentAppleComputerUseRequest(
      id: "missing-baseline",
      actionID: "click-toolbar-save",
      mode: .dryRun
    ), consent: .notRequired)

    #expect(invalidRequest.status == .failed(.invalidRequest("request id")))
    #expect(await recorder.planCount == 0)
    #expect(invalidPlan.status == .failed(.invalidPlan("duplicate step id")))
    #expect(missingBaseline.status == .failed(.invalidPlan("missing baseline evidence")))
  }

  @Test("Computer use executor records cancellation during backend execution")
  func computerUseExecutorRecordsCancellationDuringBackendExecution() async {
    let now = Date(timeIntervalSince1970: 1_800_000_200)
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.computerUse],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-computer-use"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let plan = CoreAgentAppleComputerUsePlan(
      steps: [.init(id: "inspect", summary: "Inspect target.")],
      requiredEvidence: [.screenshotDigest]
    )
    let executionStarted = AsyncTestSignal()
    let executor = CoreAgentAppleComputerUseExecutor(
      actionGate: gate,
      backend: CoreAgentAppleComputerUseBackend(
        plan: { _ in plan },
        execute: { _, _ in
          await executionStarted.signal()
          try? await Task.sleep(nanoseconds: 50_000_000)
          return [
            CoreAgentAppleComputerUseEvidence(
              kind: .screenshotDigest,
              digest: Self.screenshotDigest,
              capturedAt: now
            )
          ]
        }
      ),
      clock: { now }
    )
    let request = CoreAgentAppleComputerUseRequest(
      id: "execute-cancelled",
      actionID: "click-toolbar-save",
      mode: .dryRun
    )
    _ = await executor.run(request, consent: .notRequired)
    let executeRequest = CoreAgentAppleComputerUseRequest(
      id: "execute-cancelled",
      actionID: "click-toolbar-save",
      mode: .execute,
      approvedPlan: plan
    )
    let requirement = gate.consentRequirement(for: .computerUseExecution(
      actionID: executeRequest.actionID,
      approvedPlanDigest: plan.digest
    ))
    let receipt = CoreAgentAppleConsentReceipt.issue(
        id: "computer-use-cancelled-during-execute",
        issuerID: Self.issuerID,
        requirement: requirement,
        signingKey: Self.signingKey,
        grantedAt: now.addingTimeInterval(-10),
        expiresAt: now.addingTimeInterval(60)
    )
    let task = Task {
      await executor.run(executeRequest, consent: .granted(receipt))
    }
    await executionStarted.wait()
    task.cancel()
    let result = await task.value

    #expect(result.status == .failed(.cancelled))
    #expect(result.evidence.count == 1)
  }

  @Test("Action gate binds App Intent receipts to descriptor exposure")
  func actionGateBindsAppIntentReceiptsToDescriptorExposure() {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.appIntentExecution],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let original = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Task",
      mutability: .mutating,
      exposureRevision: "1",
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
    let changed = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Priority Task",
      mutability: .mutating,
      exposureRevision: "2",
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
    let originalRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: original,
      mode: .app,
      target: .foreground
    )
    let changedRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: changed,
      mode: .app,
      target: .foreground
    )
    let originalRequirement = gate.consentRequirement(for: originalRequest)

    #expect(gate.evaluate(
      changedRequest,
      consent: .granted(Self.receipt(id: "intent-replay", requirement: originalRequirement))
    ) == .denied(.consentRequestMismatch(
      expected: gate.consentRequirement(for: changedRequest).requestFingerprint,
      actual: originalRequirement.requestFingerprint
    )))
  }

  @Test("Action gate does not replay App Intent donation receipts for execution")
  func actionGateDoesNotReplayAppIntentDonationReceiptsForExecution() {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.appIntentDonation, .appIntentExecution],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let descriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadTaskIntent",
      title: "Read Task",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    let donationRequest = CoreAgentAppleExecutionRequest.appIntentDonation(
      descriptor: descriptor
    )
    let executionRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .app,
      target: .foreground
    )
    let donationRequirement = gate.consentRequirement(for: donationRequest)
    let executionRequirement = gate.consentRequirement(for: executionRequest)

    #expect(donationRequirement.requestFingerprint != executionRequirement.requestFingerprint)
    #expect(gate.evaluate(
      executionRequest,
      consent: .granted(Self.receipt(id: "donation-replay", requirement: donationRequirement))
    ) == .denied(.consentCapabilityMismatch(
      expected: .appIntentExecution,
      actual: .appIntentDonation
    )))

    let crossTypeRequirement = CoreAgentAppleConsentRequirement(
      authorityBoundaryID: executionRequirement.authorityBoundaryID,
      policyVersion: executionRequirement.policyVersion,
      capability: .appIntentExecution,
      requestFingerprint: donationRequirement.requestFingerprint
    )
    #expect(gate.evaluate(
      executionRequest,
      consent: .granted(Self.receipt(id: "execution-cross-type", requirement: crossTypeRequirement))
    ) == .denied(.consentRequestMismatch(
      expected: executionRequirement.requestFingerprint,
      actual: donationRequirement.requestFingerprint
    )))
  }

  @Test("App Intent donation records use stable non-sensitive identity")
  func appIntentDonationRecordsUseStableNonSensitiveIdentity() throws {
    let descriptor = Self.readTaskDonationDescriptor()
    let subject = CoreAgentAppIntentDonationSubject(
      kind: .workflowOutcome,
      stableIdentifier: "workflow:daily-review/outcome:completed",
      scopeID: "workspace:coreagent"
    )

    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: descriptor,
      subject: subject,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 7,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_200)
    )

    #expect(record.descriptorIdentifier == "CoreAgentReadTaskIntent")
    #expect(record.subject == subject)
    #expect(record.donationIdentifier.hasPrefix("coreagent-app-intent-donation-sha256-v1:"))
    #expect(!record.donationIdentifier.contains(descriptor.identifier))
    #expect(!record.donationIdentifier.contains(subject.stableIdentifier))
  }

  @Test("App Intent donation records reject prompt text tool arguments and transient calls")
  func appIntentDonationRecordsRejectPromptTextToolArgumentsAndTransientCalls() throws {
    let descriptor = Self.readTaskDonationDescriptor()

    for kind in [
      CoreAgentAppIntentDonationSubjectKind.promptText,
      .toolArguments,
      .transientToolCall,
    ] {
      let subject = CoreAgentAppIntentDonationSubject(
        kind: kind,
        stableIdentifier: "user asked to delete everything",
        scopeID: "workspace:coreagent"
      )
      #expect(throws: CoreAgentAppIntentDonationError.disallowedSubjectKind(kind)) {
        _ = try CoreAgentAppIntentDonationRecord(
          descriptor: descriptor,
          subject: subject,
          authorityBoundaryID: "workspace:coreagent",
          policyVersion: 7,
          donatedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
      }
    }
  }

  @Test("Action gate binds App Intent donation receipts to donation record identity")
  func actionGateBindsAppIntentDonationReceiptsToDonationRecordIdentity() throws {
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.appIntentDonation],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let descriptor = Self.readTaskDonationDescriptor()
    let first = try CoreAgentAppIntentDonationRecord(
      descriptor: descriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .workflowOutcome,
        stableIdentifier: "workflow:daily-review/outcome:completed",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 11
    )
    let second = try CoreAgentAppIntentDonationRecord(
      descriptor: descriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .workflowOutcome,
        stableIdentifier: "workflow:weekly-review/outcome:completed",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 11
    )
    let firstRequest = CoreAgentAppleExecutionRequest.appIntentDonationRecord(record: first)
    let secondRequest = CoreAgentAppleExecutionRequest.appIntentDonationRecord(record: second)
    let firstRequirement = gate.consentRequirement(for: firstRequest)

    #expect(firstRequirement.requestFingerprint != gate.consentRequirement(
      for: secondRequest
    ).requestFingerprint)
    #expect(!firstRequirement.requestFingerprint.contains("workflow:daily-review"))
    #expect(!firstRequirement.requestFingerprint.contains("workspace:coreagent"))
    #expect(gate.evaluate(
      secondRequest,
      consent: .granted(Self.receipt(id: "record-donation-replay", requirement: firstRequirement))
    ) == .denied(.consentRequestMismatch(
      expected: gate.consentRequirement(for: secondRequest).requestFingerprint,
      actual: firstRequirement.requestFingerprint
    )))
  }

  @Test("App Intent donation store invalidates after erasure and scope changes")
  func appIntentDonationStoreInvalidatesAfterErasureAndScopeChanges() async throws {
    let store = InMemoryCoreAgentAppIntentDonationStore()
    let descriptor = Self.readTaskDonationDescriptor()
    let workspaceRecord = try CoreAgentAppIntentDonationRecord(
      descriptor: descriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .workflowOutcome,
        stableIdentifier: "workflow:daily-review/outcome:completed",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 7
    )
    let otherRecord = try CoreAgentAppIntentDonationRecord(
      descriptor: descriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .stableEntity,
        stableIdentifier: "task:visible-summary",
        scopeID: "workspace:other"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 7
    )

    await store.record(workspaceRecord)
    await store.record(otherRecord)
    let scopeInvalidation = await store.invalidate(
      CoreAgentAppIntentDonationInvalidationRequest(
        scopeID: "workspace:coreagent",
        reason: .accessScopeChanged,
        invalidatedAt: Date(timeIntervalSince1970: 1_800_000_300)
      )
    )

    #expect(scopeInvalidation.map(\.donationIdentifier) == [
      workspaceRecord.donationIdentifier
    ])
    #expect(await store.activeRecords() == [otherRecord])

    let eraseInvalidation = await store.invalidate(
      CoreAgentAppIntentDonationInvalidationRequest(
        donationIdentifier: otherRecord.donationIdentifier,
        reason: .erased,
        invalidatedAt: Date(timeIntervalSince1970: 1_800_000_400)
      )
    )

    #expect(eraseInvalidation.map(\.donationIdentifier) == [otherRecord.donationIdentifier])
    #expect(await store.activeRecords().isEmpty)
    #expect(await store.invalidationRecords().map(\.reason) == [
      .accessScopeChanged,
      .erased,
    ])
    #expect(await store.record(workspaceRecord) == false)
    #expect(await store.record(otherRecord) == false)
    #expect(await store.activeRecords().isEmpty)
  }

  @Test("App Intent donation store requires all provided invalidation filters to match")
  func appIntentDonationStoreRequiresAllProvidedInvalidationFiltersToMatch() async throws {
    let store = InMemoryCoreAgentAppIntentDonationStore()
    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: Self.readTaskDonationDescriptor(),
      subject: CoreAgentAppIntentDonationSubject(
        kind: .workflowOutcome,
        stableIdentifier: "workflow:daily-review/outcome:completed",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 7
    )

    await store.record(record)
    let mismatched = await store.invalidate(
      CoreAgentAppIntentDonationInvalidationRequest(
        donationIdentifier: record.donationIdentifier,
        scopeID: "workspace:other",
        reason: .erased,
        invalidatedAt: Date(timeIntervalSince1970: 1_800_000_450)
      )
    )
    let empty = await store.invalidate(
      CoreAgentAppIntentDonationInvalidationRequest(
        reason: .erased,
        invalidatedAt: Date(timeIntervalSince1970: 1_800_000_451)
      )
    )

    #expect(mismatched.isEmpty)
    #expect(empty.isEmpty)
    #expect(await store.activeRecords() == [record])
    #expect(await store.invalidationRecords().isEmpty)
  }

  @Test("App Intent donation record decoding revalidates subject and digest")
  func appIntentDonationRecordDecodingRevalidatesSubjectAndDigest() throws {
    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: Self.readTaskDonationDescriptor(),
      subject: CoreAgentAppIntentDonationSubject(
        kind: .workflowOutcome,
        stableIdentifier: "workflow:daily-review/outcome:completed",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 7
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let encoded = try encoder.encode(record)
    #expect(try decoder.decode(CoreAgentAppIntentDonationRecord.self, from: encoded) == record)

    var tamperedID = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    tamperedID["donationIdentifier"] = "raw-prompt-text"
    let tamperedIDData = try JSONSerialization.data(withJSONObject: tamperedID)
    #expect(throws: CoreAgentAppIntentDonationError.self) {
      _ = try decoder.decode(CoreAgentAppIntentDonationRecord.self, from: tamperedIDData)
    }

    var tamperedDescriptor = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    tamperedDescriptor["descriptorIdentifier"] = "CoreAgentOtherIntent"
    let tamperedDescriptorData = try JSONSerialization.data(withJSONObject: tamperedDescriptor)
    #expect(throws: CoreAgentAppIntentDonationError.self) {
      _ = try decoder.decode(
        CoreAgentAppIntentDonationRecord.self,
        from: tamperedDescriptorData
      )
    }

    var tamperedSubject = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var subject = try #require(tamperedSubject["subject"] as? [String: Any])
    subject["kind"] = CoreAgentAppIntentDonationSubjectKind.promptText.rawValue
    tamperedSubject["subject"] = subject
    let tamperedSubjectData = try JSONSerialization.data(withJSONObject: tamperedSubject)
    #expect(throws: CoreAgentAppIntentDonationError.disallowedSubjectKind(.promptText)) {
      _ = try decoder.decode(CoreAgentAppIntentDonationRecord.self, from: tamperedSubjectData)
    }
  }

  @Test("Action gate enforces checkpoint persistence and App Intent donation capabilities")
  func actionGateEnforcesCheckpointPersistenceAndAppIntentDonationCapabilities() {
    let deniedGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied
      )
    )

    #expect(deniedGate.evaluate(
      .swiftDataCheckpointPersistence(checkpointKey: "thread/session"),
      consent: .notRequired
    ) == .denied(.missingCapability(.swiftDataCheckpointPersistence)))
    let donationDescriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentCreateTaskIntent",
      title: "Create Task",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
    #expect(deniedGate.evaluate(
      .appIntentDonation(descriptor: donationDescriptor),
      consent: .notRequired
    ) == .denied(.missingCapability(.appIntentDonation)))

    let allowedGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.swiftDataCheckpointPersistence, .appIntentDonation],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 1
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey
    )
    let donationRequest = CoreAgentAppleExecutionRequest.appIntentDonation(
      descriptor: donationDescriptor
    )
    #expect(allowedGate.evaluate(
      .swiftDataCheckpointPersistence(checkpointKey: "thread/session"),
      consent: .notRequired
    ).isAllowed)
    #expect(allowedGate.evaluate(
      donationRequest,
      consent: .granted(Self.receipt(
        id: "donation-receipt",
        requirement: allowedGate.consentRequirement(for: donationRequest)
      ))
    ).isAllowed)

    let disabledDonation = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadTaskIntent",
      title: "Read Task",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    #expect(allowedGate.evaluate(
      .appIntentDonation(descriptor: disabledDonation),
      consent: .granted(Self.receipt(
        id: "disabled-donation-receipt",
        requirement: allowedGate.consentRequirement(
          for: .appIntentDonation(descriptor: disabledDonation)
        )
      ))
    ) == .denied(.appIntentDonationDisabled(identifier: "CoreAgentReadTaskIntent")))
  }

  @MainActor
  @Test("SwiftData Engine store ingests redacted verified traces")
  func swiftDataEngineStoreIngestsRedactedVerifiedTraces() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(701)
    let run = Self.engineRun(
      id: runID,
      events: [
        Self.event(
          runID: runID,
          kind: .toolExecutionFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: ["api_key": "canary-not-a-token-regex", "tool": "search"]
        ),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: ["api_key": "canary-not-a-token-regex", "tool": "search"]
        ),
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent", threadID: "thread-a")
    let readback = try #require(await store.trace(projectID: "coreagent", runID: runID))

    #expect(trace.run.events.first?.message == "Failed with token=[REDACTED]")
    #expect(readback.run.events.first?.attributes["api_key"] == "[REDACTED]")
    #expect(readback.run.events.first?.attributes["tool"] == "search")
    #expect(readback.projectID == "coreagent")
    #expect(readback.threadID == "thread-a")
    #expect(readback.receipt.verify())
  }

  @MainActor
  @Test("SwiftData Engine store queries traces by project and thread")
  func swiftDataEngineStoreQueriesTracesByProjectAndThread() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)

    try await store.ingest(Self.engineRun(id: Self.uuid(711)), projectID: "coreagent", threadID: "a")
    try await store.ingest(Self.engineRun(id: Self.uuid(712)), projectID: "coreagent", threadID: "b")
    try await store.ingest(Self.engineRun(id: Self.uuid(713)), projectID: "other", threadID: "a")

    #expect(await store.traces(projectID: "coreagent").map(\.run.id) == [
      Self.uuid(711),
      Self.uuid(712),
    ])
    #expect(await store.traces(projectID: "coreagent", threadID: "a").map(\.run.id) == [
      Self.uuid(711)
    ])
  }

  @MainActor
  @Test("SwiftData Engine store persists issue lifecycle and reopening")
  func swiftDataEngineStorePersistsIssueLifecycleAndReopening() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let scanner = CoreAgentEngineIssueScanner(store: store)

    try await store.ingest(
      Self.engineFailedRun(id: Self.uuid(721), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    let first = try #require(try await scanner.scan(projectID: "coreagent").first)
    try await store.updateIssueStatus(first.id, status: .resolved)

    let stillResolved = try #require(try await scanner.scan(projectID: "coreagent").first)
    #expect(stillResolved.status == .resolved)

    try await store.ingest(
      Self.engineFailedRun(id: Self.uuid(722), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )

    let rescanned = try #require(try await scanner.scan(projectID: "coreagent").first)

    #expect(rescanned.status == .reopened)
    #expect(rescanned.contributingRunIDs == [Self.uuid(721), Self.uuid(722)])
    #expect(await store.issues(projectID: "coreagent", status: .reopened).map(\.id) == [
      first.id
    ])

    try await store.updateIssueStatus(first.id, status: .ignored)
    try await store.ingest(
      Self.engineFailedRun(id: Self.uuid(723), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    let ignoredAfterNewRun = try #require(try await scanner.scan(projectID: "coreagent").first)
    #expect(ignoredAfterNewRun.status == .ignored)
    #expect(ignoredAfterNewRun.contributingRunIDs == [
      Self.uuid(721),
      Self.uuid(722),
      Self.uuid(723),
    ])
    #expect(await store.issues(projectID: "coreagent", status: .ignored).map(\.id) == [
      first.id
    ])
  }

  @MainActor
  @Test("SwiftData Engine store fails closed on corrupted trace payloads")
  func swiftDataEngineStoreFailsClosedOnCorruptedTracePayloads() async throws {
    let context = try Self.swiftDataEngineContext()
    let store = CoreAgentSwiftDataEngineStore(modelContext: context)
    let runID = Self.uuid(731)
    context.insert(CoreAgentSwiftDataEngineTraceRecord(
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
    let redactedRun = CoreAgentEngineRedactionPolicy.standard.redacted(run: Self.engineRun(
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
    context.insert(CoreAgentSwiftDataEngineTraceRecord(
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
    context.insert(CoreAgentSwiftDataEngineTraceRecord(
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
    let run = CoreAgentEngineRedactionPolicy.standard.redacted(run: Self.engineRun(
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
    context.insert(try Self.engineTraceRecord(
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

    context.insert(CoreAgentSwiftDataEngineTraceRecord(
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
    context.insert(CoreAgentSwiftDataEngineTraceRecord(
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
    context.insert(try Self.engineTraceRecord(
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
    try await store.ingest(Self.engineRun(id: secondRunID), projectID: "coreagent", threadID: "middle")
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
    #expect(await store.traces(projectID: "coreagent").map(\.run.id) == [
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

    let merged = try await store.upsertIssue(CoreAgentEngineIssue(
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

    await #expect(throws: CoreAgentEngineStoreError.issueIdentityMismatch(
      issueID: "issue-partial-swiftdata",
      existingProjectID: "coreagent",
      incomingProjectID: "other",
      existingFingerprint: "fingerprint",
      incomingFingerprint: "other-fingerprint"
    )) {
      _ = try await store.upsertIssue(CoreAgentEngineIssue(
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
    #expect(await store.issues(projectID: "coreagent", status: .reopened).map(\.id) == [
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
    #expect(issuesBeforeUpsert.first?.contributingRunIDs == [
      Self.uuid(748),
      Self.uuid(749),
    ])
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
    #expect(await store.issues(projectID: "coreagent", status: .resolved).map(\.id) == [
      issueID
    ])

    let collapsed = try await store.upsertIssue(CoreAgentEngineIssue(
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
    context.insert(CoreAgentSwiftDataEngineIssueRecord(
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
    context.insert(CoreAgentSwiftDataEngineIssueRecord(
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
    #expect(try await checkpointer.history(threadID: "thread-a", namespace: "alpha") == [
      second,
      first,
    ])
    #expect(try await checkpointer.latest(threadID: "thread-a", namespace: "beta") == otherNamespace)
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
    context.insert(CoreAgentSwiftDataGraphCheckpointRecord(
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
    #expect(try await checkpointer.latest(threadID: "thread-c", namespace: "alpha") == lowerStepSavedLast)
    #expect(try await checkpointer.history(threadID: "thread-c", namespace: "alpha") == [
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
    context.insert(CoreAgentSwiftDataGraphCheckpointRecord(
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

    context.insert(CoreAgentSwiftDataGraphCheckpointRecord(
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

    #expect(try await checkpointer.latest(threadID: "thread-latest", namespace: "alpha") == checkpoint)
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

    context.insert(try CoreAgentSwiftDataGraphCheckpointRecord(
      checkpoint: older,
      saveSequence: 0,
      storedAt: Date(timeIntervalSince1970: 710)
    ))
    context.insert(try CoreAgentSwiftDataGraphCheckpointRecord(
      checkpoint: newer,
      saveSequence: 0,
      storedAt: Date(timeIntervalSince1970: 711)
    ))
    try context.save()

    #expect(try await checkpointer.latest(threadID: "thread-tie", namespace: "alpha") == newer)
    #expect(try await checkpointer.history(threadID: "thread-tie", namespace: "alpha") == [
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

    #expect(try await store.value(forKey: "profile", namespace: "alpha") == GraphValue(label: "alpha-updated"))
    #expect(try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
    #expect(try await store.keys(namespace: "alpha") == ["a", "profile"])
    #expect(rawRecordsAfterReplacement.filter {
      $0.namespace == "alpha" && $0.key == "profile"
    }.count == 1)

    try await store.removeValue(forKey: "profile", namespace: "alpha")

    #expect(try await store.value(forKey: "profile", namespace: "alpha") == nil)
    #expect(try await store.value(forKey: "profile", namespace: "beta") == GraphValue(label: "beta"))
  }

  @MainActor
  @Test("SwiftData graph store keys validate integrity without decoding payload values")
  func swiftDataGraphStoreKeysValidateIntegrityWithoutDecodingPayloadValues() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "stable"), forKey: "profile", namespace: "alpha")
    context.insert(try CoreAgentSwiftDataGraphStoreRecord(
      record: CoreAgentGraphStoreRecord(
        namespace: "alpha",
        key: "foreign",
        value: OtherGraphValue(count: 1)
      )
    ))
    context.insert(try CoreAgentSwiftDataGraphStoreRecord(
      record: CoreAgentGraphStoreRecord(
        namespace: "alpha",
        key: "foreign-removable",
        value: OtherGraphValue(count: 2)
      )
    ))
    try context.save()

    #expect(try await store.keys(namespace: "alpha") == [
      "foreign",
      "foreign-removable",
      "profile",
    ])
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.value(forKey: "foreign", namespace: "alpha")
    }

    try await store.put(GraphValue(label: "replacement"), forKey: "foreign", namespace: "alpha")
    #expect(try await store.value(forKey: "foreign", namespace: "alpha") == GraphValue(label: "replacement"))

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
    context.insert(CoreAgentSwiftDataGraphStoreRecord(
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

  @MainActor
  @Test("SwiftData graph store fails closed on forged scope keys before read or mutation")
  func swiftDataGraphStoreFailsClosedOnForgedScopeKeysBeforeReadOrMutation() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "stable"), forKey: "profile", namespace: "alpha")
    context.insert(CoreAgentSwiftDataGraphStoreRecord(
      namespace: "alpha",
      key: "profile",
      updatedAt: Date(timeIntervalSince1970: 4_102_444_800),
      storeScopeKey: "graph-store-scope-sha256-v1:forged",
      encodedValue: Data("not-json".utf8),
      valueDigest: "sha256:corrupt"
    ))
    try context.save()

    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.record(forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.keys(namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      try await store.put(GraphValue(label: "replacement"), forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      try await store.removeValue(forKey: "profile", namespace: "alpha")
    }
  }

  @MainActor
  @Test("SwiftUI projection store summarizes run state without raw event payloads")
  func swiftUIProjectionStoreSummarizesRunStateWithoutRawEventPayloads() throws {
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let run = CoreAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      endedAt: Date(timeIntervalSince1970: 1_800_000_003),
      usage: nil,
      events: [
        Self.event(runID: runID, kind: .runStarted, message: "contains token=secret"),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "failed with token=secret",
          attributes: ["api_key": "secret", "tool": "write_file"]
        ),
      ]
    )
    let trace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: run,
      receipt: CoreAgentRunReceipt(run: run),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_004)
    )

    let store = CoreAgentRunProjectionStore()
    store.apply(traces: [trace, trace])
    let projection = try #require(store.projections.first)

    #expect(store.projections.count == 1)
    #expect(projection.runID == runID)
    #expect(projection.projectID == "coreagent")
    #expect(projection.threadID == "thread-a")
    #expect(projection.status == .failed)
    #expect(projection.lastEventKind == .runFailed)
    #expect(projection.eventCounts[.runStarted] == 1)
    #expect(projection.eventCounts[.runFailed] == 1)
    #expect(projection.duration == 3)

    let secondRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    let secondRun = CoreAgentRun(
      id: secondRunID,
      startedAt: Date(timeIntervalSince1970: 1_800_000_010),
      endedAt: Date(timeIntervalSince1970: 1_800_000_010),
      usage: nil,
      events: [Self.event(runID: secondRunID, kind: .runStarted, message: "started")]
    )
    let secondTrace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-b",
      run: secondRun,
      receipt: CoreAgentRunReceipt(run: secondRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_011)
    )

    store.apply(traces: [secondTrace])

    #expect(store.projections.map(\.runID) == [runID, secondRunID])
    #expect(store.projections.last?.status == .running)
  }

  private static func checkpoint(
    savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> CoreAgentCheckpoint {
    CoreAgentCheckpoint(
      savedAt: savedAt,
      compatibilityRevision: "revision-a",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
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
      timestamp: Date(timeIntervalSince1970: 1_800_000_000),
      kind: kind,
      message: message,
      attributes: attributes
    )
  }

  private static func engineRun(
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

  private static func engineTraceData(_ trace: CoreAgentEngineTrace) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(trace)
  }

  private static func engineIssueData(_ issue: CoreAgentEngineIssue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(issue)
  }

  private static func engineTraceRecord(
    _ trace: CoreAgentEngineTrace,
    sequence: Int = 0,
    traceScopeKey: String? = nil,
    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier
  ) throws -> CoreAgentSwiftDataEngineTraceRecord {
    let encodedTrace = try engineTraceData(trace)
    return CoreAgentSwiftDataEngineTraceRecord(
      projectID: trace.projectID,
      threadID: trace.threadID,
      runID: trace.run.id,
      startedAt: trace.run.startedAt,
      endedAt: trace.run.endedAt,
      ingestedAt: trace.ingestedAt,
      sequence: sequence,
      traceScopeKey: traceScopeKey,
      redactionPolicyIdentifier: redactionPolicyIdentifier,
      encodedTrace: encodedTrace,
      traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
        traceScopeKey: traceScopeKey,
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

  private static func engineIssueRecord(
    _ issue: CoreAgentEngineIssue,
    fingerprint: String? = nil,
    statusRawValue: String? = nil,
    issueDigest: String? = nil
  ) throws -> CoreAgentSwiftDataEngineIssueRecord {
    let encodedIssue = try engineIssueData(issue)
    let sidecarFingerprint = fingerprint ?? issue.fingerprint
    let sidecarStatus = statusRawValue ?? issue.status.rawValue
    let digest = issueDigest ?? CoreAgentSwiftDataEngineIssueRecord.integrityDigest(
      issueID: issue.id,
      projectID: issue.projectID,
      fingerprint: sidecarFingerprint,
      statusRawValue: sidecarStatus,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt,
      encodedIssue: encodedIssue
    )
    return CoreAgentSwiftDataEngineIssueRecord(
      issueID: issue.id,
      projectID: issue.projectID,
      fingerprint: sidecarFingerprint,
      statusRawValue: sidecarStatus,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt,
      encodedIssue: encodedIssue,
      issueDigest: digest
    )
  }

  private static func engineFailedRun(
    id: UUID,
    errorType: String,
    tool: String
  ) -> CoreAgentRun {
    engineRun(
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

  private static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }

  private struct ApplePlatformTestCustomSegment: Transcript.CustomSegment {
    struct Content: Codable, Equatable, Sendable {
      let value: String
    }

    let id: String
    let content: Content
  }

  private struct GraphState: Codable, Equatable, Sendable {
    var log: [String] = []
  }

  private struct GraphValue: Codable, Equatable, Sendable {
    var label: String
  }

  private struct OtherGraphValue: Codable, Equatable, Sendable {
    var count: Int
  }

  private actor AsyncTestSignal {
    private var hasSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if hasSignaled {
        return
      }
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
      }
    }

    func signal() {
      hasSignaled = true
      let pending = continuations
      continuations.removeAll()
      for continuation in pending {
        continuation.resume()
      }
    }
  }

  private actor ComputerUseRecorder {
    private(set) var planCount = 0
    private(set) var executeCount = 0

    func plan(
      _ request: CoreAgentAppleComputerUseRequest
    ) -> CoreAgentAppleComputerUsePlan {
      planCount += 1
      return CoreAgentAppleComputerUsePlan(
        steps: [
          .init(id: "inspect", summary: "Inspect target state for \(request.actionID)."),
          .init(id: "click", summary: "Perform requested action \(request.actionID)."),
        ],
        requiredEvidence: [.screenshotDigest]
      )
    }

    func execute(
      _ request: CoreAgentAppleComputerUseRequest,
      plan: CoreAgentAppleComputerUsePlan,
      capturedAt: Date
    ) -> [CoreAgentAppleComputerUseEvidence] {
      executeCount += 1
      return [
        CoreAgentAppleComputerUseEvidence(
          kind: .screenshotDigest,
          digest: CoreAgentApplePlatformTests.screenshotDigest,
          capturedAt: capturedAt
        )
      ]
    }
  }

  private actor HelperCodeRecorder {
    private(set) var runCount = 0
    private(set) var lastRequest: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest?

    func record(
      _ request: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
    ) -> Int {
      runCount += 1
      lastRequest = request
      return runCount
    }
  }

  private static func computerUseBackend(
    recorder: ComputerUseRecorder
  ) -> CoreAgentAppleComputerUseBackend {
    CoreAgentAppleComputerUseBackend(
      plan: { request in
        await recorder.plan(request)
      },
      execute: { request, plan in
        await recorder.execute(
          request,
          plan: plan,
          capturedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
      }
    )
  }

  private static func helperCodeBackend(
    recorder: HelperCodeRecorder,
    stdout: String
  ) -> CoreAgentAppleHelperCodeInterpreterBackend {
    CoreAgentAppleHelperCodeInterpreterBackend { request in
      _ = await recorder.record(request)
      return CoreAgentAppleHelperCodeInterpreterBackendResult(
        exitCode: 0,
        stdout: stdout,
        stderr: "",
        outputs: ["result": .string(stdout.trimmingCharacters(in: .whitespacesAndNewlines))]
      )
    }
  }

  private static func readTaskDonationDescriptor() -> CoreAgentAppIntentDescriptor {
    CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadTaskIntent",
      title: "Read Task",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
  }

  private static func canonicalTestURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }

  @MainActor
  private static func swiftDataContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataCheckpointRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  @MainActor
  private static func swiftDataEngineContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataEngineTraceRecord.self,
      CoreAgentSwiftDataEngineIssueRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  @MainActor
  private static func swiftDataGraphContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataGraphCheckpointRecord.self,
      CoreAgentSwiftDataGraphStoreRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  private static func receipt(
    id: String,
    requirement: CoreAgentAppleConsentRequirement,
    expiresAt: Date? = nil
  ) -> CoreAgentAppleConsentReceipt {
    CoreAgentAppleConsentReceipt.issue(
      id: id,
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: Self.grantedAt,
      expiresAt: expiresAt ?? .distantFuture
    )
  }

  private static let issuerID = "coreagent.test.consent"
  private static let signingKey = CoreAgentAppleConsentSigningKey(
    Data("coreagent-apple-platform-test-signing-key".utf8)
  )!
  private static let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
  private static let screenshotDigest = "sha256:" + String(repeating: "a", count: 64)

  @Test("Remote code interpreter fails closed without backend and enforces policy")
  func remoteCodeInterpreterFailsClosedWithoutBackendAndEnforcesPolicy() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_170)
    let endpoint = URL(string: "https://interpreter.example/run")!
    let allowedNetworkGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-remote"),
        networkPolicy: .allowed,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let backendMissingInterpreter = CoreAgentAppleRemoteCodeInterpreter(
      actionGate: allowedNetworkGate,
      policy: CoreAgentAppleRemoteCodeInterpreterPolicy(allowedEndpointURLs: [endpoint]),
      clock: { now }
    )
    let request = CoreAgentAppleRemoteCodeInterpreterRequest(
      id: "remote-1",
      endpointURL: endpoint
    )
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "remote-receipt",
      issuerID: Self.issuerID,
      requirement: backendMissingInterpreter.consentRequirement(for: request),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )

    let denied = await backendMissingInterpreter.run(request, consent: .granted(receipt))

    let localOnlyGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-remote"),
        networkPolicy: .localOnly,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let networkDeniedInterpreter = CoreAgentAppleRemoteCodeInterpreter(
      actionGate: localOnlyGate,
      policy: CoreAgentAppleRemoteCodeInterpreterPolicy(allowedEndpointURLs: [endpoint]),
      clock: { now }
    )
    let networkDenied = await networkDeniedInterpreter.run(
      CoreAgentAppleRemoteCodeInterpreterRequest(
        id: "remote-2",
        endpointURL: endpoint
      ),
      consent: .granted(receipt)
    )

    #expect(denied.status == .failed(.invalidRequest("remote backend unavailable")))
    #expect(
      networkDenied.status
        == .failed(.invalidRequest("remote execution requires allowed network policy"))
    )
  }

  @Test("Remote code interpreter runs through authorized backend")
  func remoteCodeInterpreterRunsThroughAuthorizedBackend() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_171)
    let endpoint = URL(string: "https://interpreter.example/run")!
    let gate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-remote-run"),
        networkPolicy: .allowed,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 12
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let backend = CoreAgentAppleRemoteCodeInterpreterBackend { authorized in
      #expect(authorized.canonicalEndpointURL == endpoint)
      return CoreAgentAppleRemoteCodeInterpreterBackendResult(
        exitCode: 0,
        stdout: "remote-ok",
        stderr: ""
      )
    }
    let interpreter = CoreAgentAppleRemoteCodeInterpreter(
      actionGate: gate,
      policy: CoreAgentAppleRemoteCodeInterpreterPolicy(allowedEndpointURLs: [endpoint]),
      backend: backend,
      clock: { now }
    )
    let request = CoreAgentAppleRemoteCodeInterpreterRequest(
      id: "remote-3",
      endpointURL: endpoint,
      standardInput: "input"
    )
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "remote-run-receipt",
      issuerID: Self.issuerID,
      requirement: interpreter.consentRequirement(for: request),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )
    let result = await interpreter.run(request, consent: .granted(receipt))

    #expect(result.status == CoreAgentAppleCodeInterpreterStatus.succeeded)
    #expect(result.stdout == "remote-ok")
    #expect(result.audit.tier == CoreAgentAppleInterpreterTier.remote)
  }


}
