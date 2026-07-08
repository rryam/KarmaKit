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

    #expect(
      gate.evaluate(
        changedRequest,
        consent: .granted(Self.receipt(id: "intent-replay", requirement: originalRequirement))
      )
        == .denied(
          .consentRequestMismatch(
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
    #expect(
      gate.evaluate(
        executionRequest,
        consent: .granted(Self.receipt(id: "donation-replay", requirement: donationRequirement))
      )
        == .denied(
          .consentCapabilityMismatch(
            expected: .appIntentExecution,
            actual: .appIntentDonation
          )))

    let crossTypeRequirement = CoreAgentAppleConsentRequirement(
      authorityBoundaryID: executionRequirement.authorityBoundaryID,
      policyVersion: executionRequirement.policyVersion,
      capability: .appIntentExecution,
      requestFingerprint: donationRequirement.requestFingerprint
    )
    #expect(
      gate.evaluate(
        executionRequest,
        consent: .granted(
          Self.receipt(id: "execution-cross-type", requirement: crossTypeRequirement))
      )
        == .denied(
          .consentRequestMismatch(
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

    #expect(
      firstRequirement.requestFingerprint
        != gate.consentRequirement(
          for: secondRequest
        ).requestFingerprint)
    #expect(!firstRequirement.requestFingerprint.contains("workflow:daily-review"))
    #expect(!firstRequirement.requestFingerprint.contains("workspace:coreagent"))
    #expect(
      gate.evaluate(
        secondRequest,
        consent: .granted(Self.receipt(id: "record-donation-replay", requirement: firstRequirement))
      )
        == .denied(
          .consentRequestMismatch(
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

    #expect(
      scopeInvalidation.map(\.donationIdentifier) == [
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
    #expect(
      await store.invalidationRecords().map(\.reason) == [
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

    #expect(
      deniedGate.evaluate(
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
    #expect(
      deniedGate.evaluate(
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
    #expect(
      allowedGate.evaluate(
        .swiftDataCheckpointPersistence(checkpointKey: "thread/session"),
        consent: .notRequired
      ).isAllowed)
    #expect(
      allowedGate.evaluate(
        donationRequest,
        consent: .granted(
          Self.receipt(
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
    #expect(
      allowedGate.evaluate(
        .appIntentDonation(descriptor: disabledDonation),
        consent: .granted(
          Self.receipt(
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

    try await store.ingest(
      Self.engineRun(id: Self.uuid(711)), projectID: "coreagent", threadID: "a")
    try await store.ingest(
      Self.engineRun(id: Self.uuid(712)), projectID: "coreagent", threadID: "b")
    try await store.ingest(Self.engineRun(id: Self.uuid(713)), projectID: "other", threadID: "a")

    #expect(
      await store.traces(projectID: "coreagent").map(\.run.id) == [
        Self.uuid(711),
        Self.uuid(712),
      ])
    #expect(
      await store.traces(projectID: "coreagent", threadID: "a").map(\.run.id) == [
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
    #expect(
      await store.issues(projectID: "coreagent", status: .reopened).map(\.id) == [
        first.id
      ])

    try await store.updateIssueStatus(first.id, status: .ignored)
    try await store.ingest(
      Self.engineFailedRun(id: Self.uuid(723), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    let ignoredAfterNewRun = try #require(try await scanner.scan(projectID: "coreagent").first)
    #expect(ignoredAfterNewRun.status == .ignored)
    #expect(
      ignoredAfterNewRun.contributingRunIDs == [
        Self.uuid(721),
        Self.uuid(722),
        Self.uuid(723),
      ])
    #expect(
      await store.issues(projectID: "coreagent", status: .ignored).map(\.id) == [
        first.id
      ])
  }

}
