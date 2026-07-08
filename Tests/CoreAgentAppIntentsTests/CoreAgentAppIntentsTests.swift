import AppIntents
import CoreAgentApplePlatform
import Foundation
import Testing
@testable import CoreAgentAppIntents

@Suite("CoreAgent App Intents bridge", .serialized)
struct CoreAgentAppIntentsTests {
  @Test("Concrete run intent catalog exposes stable validated descriptors and OS policy")
  func concreteRunIntentCatalogExposesStableValidatedDescriptorsAndOSPolicy() throws {
    let entries = try CoreAgentRunAppIntentCatalog.entries

    #expect(entries.map(\.kind) == [.openRun, .pauseRun, .continueRun])
    #expect(entries.map(\.descriptor.identifier) == [
      "CoreAgentOpenRunIntent",
      "CoreAgentPauseRunIntent",
      "CoreAgentContinueRunIntent",
    ])
    #expect(entries.map(\.osPolicy.allowedExecutionTargets) == [.main, .main, .main])
    #expect(entries[0].osPolicy.supportedModes == CoreAgentOpenRunIntent.supportedModes)
    #expect(entries[1].osPolicy.supportedModes == .foreground(.dynamic))
    #expect(entries[2].osPolicy.supportedModes == .foreground(.dynamic))
    #expect(entries[1].osPolicy.supportedModes == CoreAgentPauseRunIntent.supportedModes)
    #expect(entries[2].osPolicy.supportedModes == CoreAgentContinueRunIntent.supportedModes)

    for entry in entries {
      #expect(try entry.descriptor.validatedForAgentExposure() == entry.descriptor)
    }
  }

  @Test("Concrete run intents validate run IDs before delegating to host runtime")
  func concreteRunIntentsValidateRunIDsBeforeDelegatingToHostRuntime() async throws {
    let recorder = RuntimeRecorder()
    let gate = Self.appIntentGate()
    await CoreAgentRunAppIntentRuntime.shared.resetEnvironment()
    await CoreAgentRunAppIntentRuntime.shared.setEnvironment(Self.runtimeEnvironment(
      gate: gate,
      recorder: recorder
    ))

    do {
      _ = try await CoreAgentPauseRunIntent(runID: " ").perform()
      Issue.record("Expected empty run IDs to be rejected before host runtime delegation")
    } catch let error as CoreAgentRunAppIntentRuntimeError {
      #expect(error == .invalidRunID(.pauseRun))
    }
    #expect(await recorder.requests == [])

    do {
      _ = try await CoreAgentContinueRunIntent(runID: " run-1 ").perform()
      Issue.record("Expected whitespace-padded run IDs to be rejected")
    } catch let error as CoreAgentRunAppIntentRuntimeError {
      #expect(error == .invalidRunID(.continueRun))
    }
    #expect(await recorder.requests == [])

    do {
      _ = try await CoreAgentOpenRunIntent(runID: String(repeating: "r", count: 257)).perform()
      Issue.record("Expected oversized run IDs to be rejected")
    } catch let error as CoreAgentRunAppIntentRuntimeError {
      #expect(error == .invalidRunID(.openRun))
    }
    #expect(await recorder.requests == [])

    for invalidRunID in ["../run", ".hidden", "run/1", "run:1", "run\n1", "run🙂"] {
      do {
        _ = try await CoreAgentOpenRunIntent(runID: invalidRunID).perform()
        Issue.record("Expected unsafe run ID to be rejected: \(invalidRunID)")
      } catch let error as CoreAgentRunAppIntentRuntimeError {
        #expect(error == .invalidRunID(.openRun))
      }
    }
    #expect(await recorder.requests == [])

    _ = try await CoreAgentPauseRunIntent(runID: "run-1").perform()
    _ = try await CoreAgentContinueRunIntent(runID: "run-1").perform()
    #expect(await recorder.requests == [
      CoreAgentRunAppIntentRuntimeRequest(kind: .pauseRun, runID: "run-1"),
      CoreAgentRunAppIntentRuntimeRequest(kind: .continueRun, runID: "run-1"),
    ])

    await CoreAgentRunAppIntentRuntime.shared.resetEnvironment()
  }

  @Test("Concrete run intents execute through the CoreAgent bridge before host work")
  func concreteRunIntentsExecuteThroughCoreAgentBridgeBeforeHostWork() async throws {
    let recorder = RuntimeRecorder()
    let gate = Self.appIntentGate()
    await CoreAgentRunAppIntentRuntime.shared.resetEnvironment()
    await CoreAgentRunAppIntentRuntime.shared.setEnvironment(Self.runtimeEnvironment(
      gate: gate,
      recorder: recorder,
      consent: { _ in .notRequired }
    ))

    do {
      _ = try await CoreAgentPauseRunIntent(runID: "run-bridge").perform()
      Issue.record("Expected bridge denial before host work when consent is missing")
    } catch let error as CoreAgentRunAppIntentRuntimeError {
      #expect(error == .denied(.pauseRun, .missingConsent(.appIntentExecution)))
    }
    #expect(await recorder.requests == [])

    await CoreAgentRunAppIntentRuntime.shared.setEnvironment(Self.runtimeEnvironment(
      gate: gate,
      recorder: recorder,
      checkpointKey: { _ in nil }
    ))
    do {
      _ = try await CoreAgentPauseRunIntent(runID: "run-bridge").perform()
      Issue.record("Expected bridge checkpoint enforcement before host work")
    } catch let error as CoreAgentRunAppIntentRuntimeError {
      #expect(error == .missingCheckpoint(.pauseRun))
    }
    #expect(await recorder.requests == [])

    await CoreAgentRunAppIntentRuntime.shared.setEnvironment(Self.runtimeEnvironment(
      gate: gate,
      recorder: recorder
    ))
    _ = try await CoreAgentPauseRunIntent(runID: "run-bridge").perform()
    #expect(await recorder.requests == [
      CoreAgentRunAppIntentRuntimeRequest(kind: .pauseRun, runID: "run-bridge"),
    ])

    await CoreAgentRunAppIntentRuntime.shared.resetEnvironment()
  }

  @Test("Bridge requires checkpoints for mutating intents before host work")
  func bridgeRequiresCheckpointsForMutatingIntentsBeforeHostWork() async throws {
    let recorder = BridgeRecorder()
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(actionGate: gate)
    let descriptor = Self.pauseRunDescriptor(supportedModes: [.app])
    let request = CoreAgentAppIntentBridgeRequest(
      actionID: "pause-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "pause-run-missing-checkpoint",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .app,
          target: .foreground
        ))
      )),
      checkpointKey: nil
    )

    let result = await bridge.perform(request) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(result.status == .missingCheckpoint)
    #expect(await recorder.events == [])
  }

  @Test("Bridge checks cancellation immediately before host work")
  func bridgeChecksCancellationImmediatelyBeforeHostWork() async throws {
    let recorder = BridgeRecorder()
    let cancellation = CancellationProbe()
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(actionGate: gate)
    let descriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadRunIntent",
      title: "Read Run",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    let request = CoreAgentAppIntentBridgeRequest(
      actionID: "read-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "read-run-cancel-before-operation",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .app,
          target: .foreground
        ))
      )),
      checkpointKey: nil,
      isCancelled: { cancellation.cancelAfterFirstCheck() }
    )

    let result = await bridge.perform(request) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(result.status == .cancelled)
    #expect(await recorder.events == [])
  }

  @Test("Bridge maps thrown cancellation to cancelled status")
  func bridgeMapsThrownCancellationToCancelledStatus() async throws {
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(actionGate: gate)
    let descriptor = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadRunIntent",
      title: "Read Run",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    let request = CoreAgentAppIntentBridgeRequest(
      actionID: "read-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "read-run-operation-cancelled",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .app,
          target: .foreground
        ))
      )),
      checkpointKey: nil
    )

    let result = await bridge.perform(request) { _ in
      throw CancellationError()
    }

    #expect(result.status == .cancelled)
  }

  @Test("OS policy mapper does not conflate CoreAgent caller modes and process targets")
  func osPolicyMapperDoesNotConflateCoreAgentCallerModesAndProcessTargets() throws {
    let appAndSiriRead = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadRunIntent",
      title: "Read Run",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground, .background],
      supportedModes: [.app, .siri],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    let spotlightRead = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadRunIntent",
      title: "Read Run",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.background],
      supportedModes: [.spotlight],
      donationPolicy: .doNotDonate,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
    let mutate = CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentPauseRunIntent",
      title: "Pause Run",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app, .siri, .shortcuts],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )

    let readPolicy = try CoreAgentAppIntentOSPolicyMapper.policy(for: appAndSiriRead)
    let spotlightPolicy = try CoreAgentAppIntentOSPolicyMapper.policy(for: spotlightRead)
    let mutatePolicy = try CoreAgentAppIntentOSPolicyMapper.policy(for: mutate)

    #expect(readPolicy.supportedModes == spotlightPolicy.supportedModes)
    #expect(readPolicy.allowedExecutionTargets == .main)
    #expect(spotlightPolicy.allowedExecutionTargets == .main)
    #expect(mutatePolicy.supportedModes == .foreground(.dynamic))
    #expect(mutatePolicy.allowedExecutionTargets == .main)
  }

  @Test("OS donation bridge gates records and donates through backend")
  func osDonationBridgeGatesRecordsAndDonatesThroughBackend() async throws {
    let backend = FakeRunDonationBackend(tokens: [
      FakeRunDonationKey(kind: .pauseRun, runID: "run-1"):
        CoreAgentAppIntentOSDonationToken(encodedIdentifier: Data("os:pause:run-1".utf8))
    ])
    let store = InMemoryCoreAgentAppIntentDonationStore()
    let gate = Self.appIntentDonationGate()
    let bridge = CoreAgentRunAppIntentDonationBridge(
      actionGate: gate,
      backend: backend,
      store: store,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )
    let subject = CoreAgentAppIntentDonationSubject(
      kind: .runOutcome,
      stableIdentifier: "run-1:paused",
      scopeID: "workspace:coreagent"
    )
    let expectedRecord = try CoreAgentAppIntentDonationRecord(
      descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
      subject: subject,
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 27,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
    )
    let requirement = gate.consentRequirement(
      for: .appIntentDonationRecord(record: expectedRecord)
    )

    let result = await bridge.donate(
      CoreAgentRunAppIntentDonationRequest(
        kind: .pauseRun,
        runID: "run-1",
        subject: subject,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27,
        consent: .granted(Self.receipt(id: "pause-donation", requirement: requirement))
      )
    )

    #expect(result.status == .donated(CoreAgentRunAppIntentDonationReceipt(
      record: expectedRecord,
      osDonationToken: CoreAgentAppIntentOSDonationToken(
        encodedIdentifier: Data("os:pause:run-1".utf8)
      ),
      osDonationIdentifierDigest: CoreAgentAppIntentOSDonationToken(
        encodedIdentifier: Data("os:pause:run-1".utf8)
      ).digest,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
    )))
    let requests = await backend.donationRequests
    #expect(requests.count == 1)
    #expect(requests.first?.kind == .pauseRun)
    #expect(requests.first?.runID == "run-1")
    #expect(requests.first?.record == expectedRecord)
    #expect(await store.activeRecords() == [expectedRecord])
  }

  @Test("OS donation bridge denies before backend work")
  func osDonationBridgeDeniesBeforeBackendWork() async throws {
    let backend = FakeRunDonationBackend(tokens: [:])
    let gate = Self.appIntentDonationGate(capabilities: [])
    let bridge = CoreAgentRunAppIntentDonationBridge(
      actionGate: gate,
      backend: backend,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )
    let subject = CoreAgentAppIntentDonationSubject(
      kind: .runOutcome,
      stableIdentifier: "run-1:paused",
      scopeID: "workspace:coreagent"
    )

    let denied = await bridge.donate(
      CoreAgentRunAppIntentDonationRequest(
        kind: .pauseRun,
        runID: "run-1",
        subject: subject,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27,
        consent: .notRequired
      )
    )
    let disabled = await bridge.donate(
      CoreAgentRunAppIntentDonationRequest(
        kind: .openRun,
        runID: "run-1",
        subject: subject,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27,
        consent: .notRequired
      )
    )
    let invalidRun = await bridge.donate(
      CoreAgentRunAppIntentDonationRequest(
        kind: .pauseRun,
        runID: "../run-1",
        subject: subject,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27,
        consent: .notRequired
      )
    )

    #expect(denied.status == .denied(.missingCapability(.appIntentDonation)))
    #expect(disabled.status == .rejected(.invalidDonationRecord(
      .disabledDonation(identifier: "CoreAgentOpenRunIntent")
    )))
    #expect(invalidRun.status == .rejected(.invalidRunID(.pauseRun)))
    #expect(await backend.donationRequests.isEmpty)
  }

  @Test("OS donation bridge rejects subject/run mismatches before backend work")
  func osDonationBridgeRejectsSubjectRunMismatchesBeforeBackendWork() async throws {
    let backend = FakeRunDonationBackend(tokens: [:])
    let gate = Self.appIntentDonationGate()
    let bridge = CoreAgentRunAppIntentDonationBridge(
      actionGate: gate,
      backend: backend,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )
    let mismatchedSubject = CoreAgentAppIntentDonationSubject(
      kind: .runOutcome,
      stableIdentifier: "run-2:paused",
      scopeID: "workspace:coreagent"
    )

    let result = await bridge.donate(
      CoreAgentRunAppIntentDonationRequest(
        kind: .pauseRun,
        runID: "run-1",
        subject: mismatchedSubject,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27,
        consent: .notRequired
      )
    )

    #expect(result.status == .rejected(.subjectRunIDMismatch(
      expectedStableIdentifier: "run-1:paused",
      actualStableIdentifier: "run-2:paused"
    )))
    #expect(await backend.donationRequests.isEmpty)
  }

  @Test("OS donation backend rejects invalid requests before OS work")
  func osDonationBackendRejectsInvalidRequestsBeforeOSWork() async throws {
    let backend = CoreAgentIntentDonationManagerRunBackend()
    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .runOutcome,
        stableIdentifier: "run-1:paused",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 27,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
    )

    #expect(throws: CoreAgentRunAppIntentDonationBackendError.disabledDonation(
      identifier: "CoreAgentOpenRunIntent"
    )) {
      _ = try backend.validate(CoreAgentRunAppIntentDonationBackendRequest(
        kind: .openRun,
        runID: "run-1",
        record: record,
        authorization: CoreAgentRunAppIntentDonationBackendAuthorization(
          record: record,
          runID: "run-1"
        )
      ))
    }
    #expect(throws: CoreAgentRunAppIntentDonationBackendError.invalidRunID(.pauseRun)) {
      _ = try backend.validate(CoreAgentRunAppIntentDonationBackendRequest(
        kind: .pauseRun,
        runID: "../run-1",
        record: record,
        authorization: CoreAgentRunAppIntentDonationBackendAuthorization(
          record: record,
          runID: "../run-1"
        )
      ))
    }
    #expect(throws: CoreAgentRunAppIntentDonationBackendError.unauthorizedRequest) {
      _ = try backend.validate(CoreAgentRunAppIntentDonationBackendRequest(
        kind: .pauseRun,
        runID: "run-1",
        record: record,
        authorization: CoreAgentRunAppIntentDonationBackendAuthorization(
          record: record,
          runID: "run-2"
        )
      ))
    }
  }

  @Test("OS donation bridge invalidates matching donations through backend")
  func osDonationBridgeInvalidatesMatchingDonationsThroughBackend() async throws {
    let token = CoreAgentAppIntentOSDonationToken(
      encodedIdentifier: Data("os:pause:run-1".utf8)
    )
    let backend = FakeRunDonationBackend(tokens: [:], deletedTokens: [token: [token]])
    let store = InMemoryCoreAgentAppIntentDonationStore()
    let gate = Self.appIntentDonationGate()
    let bridge = CoreAgentRunAppIntentDonationBridge(
      actionGate: gate,
      backend: backend,
      store: store,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )
    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .runOutcome,
        stableIdentifier: "run-1:paused",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 27,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
    )
    await store.record(record)
    let receipt = CoreAgentRunAppIntentDonationReceipt(
      record: record,
      osDonationToken: token,
      osDonationIdentifierDigest: token.digest,
      donatedAt: record.donatedAt
    )
    let requirement = gate.consentRequirement(
      for: .appIntentDonationInvalidation(record: record, reason: .erased)
    )

    let result = await bridge.invalidate(
      CoreAgentRunAppIntentDonationInvalidationRequest(
        receipt: receipt,
        request: CoreAgentAppIntentDonationInvalidationRequest(
          donationIdentifier: record.donationIdentifier,
          reason: .erased,
          invalidatedAt: Date(timeIntervalSince1970: 1_800_000_600)
        ),
        consent: .granted(Self.receipt(id: "erase-donation", requirement: requirement))
      )
    )

    #expect(result == CoreAgentRunAppIntentDonationInvalidationResult(
      receipt: receipt,
      deletedOSDonationIdentifierDigests: [token.digest],
      invalidationRecords: [
        CoreAgentAppIntentDonationInvalidationRecord(
          donationIdentifier: record.donationIdentifier,
          descriptorIdentifier: record.descriptorIdentifier,
          subject: record.subject,
          reason: .erased,
          invalidatedAt: Date(timeIntervalSince1970: 1_800_000_600)
        )
      ],
      status: .invalidated
    ))
    #expect(await backend.deletedTokens == [token])
    #expect(await store.activeRecords().isEmpty)
  }

  @Test("OS donation invalidation is gated and matches all provided filters")
  func osDonationInvalidationIsGatedAndMatchesAllProvidedFilters() async throws {
    let token = CoreAgentAppIntentOSDonationToken(
      encodedIdentifier: Data("os:pause:run-1".utf8)
    )
    let backend = FakeRunDonationBackend(tokens: [:], deletedTokens: [token: [token]])
    let store = InMemoryCoreAgentAppIntentDonationStore()
    let gate = Self.appIntentDonationGate()
    let bridge = CoreAgentRunAppIntentDonationBridge(
      actionGate: gate,
      backend: backend,
      store: store,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )
    let record = try CoreAgentAppIntentDonationRecord(
      descriptor: CoreAgentPauseRunIntent.coreAgentDescriptor,
      subject: CoreAgentAppIntentDonationSubject(
        kind: .runOutcome,
        stableIdentifier: "run-1:paused",
        scopeID: "workspace:coreagent"
      ),
      authorityBoundaryID: "workspace:coreagent",
      policyVersion: 27,
      donatedAt: Date(timeIntervalSince1970: 1_800_000_500)
    )
    await store.record(record)
    let receipt = CoreAgentRunAppIntentDonationReceipt(
      record: record,
      osDonationToken: token,
      osDonationIdentifierDigest: token.digest,
      donatedAt: record.donatedAt
    )

    let denied = await bridge.invalidate(
      CoreAgentRunAppIntentDonationInvalidationRequest(
        receipt: receipt,
        request: CoreAgentAppIntentDonationInvalidationRequest(
          donationIdentifier: record.donationIdentifier,
          reason: .erased,
          invalidatedAt: Date(timeIntervalSince1970: 1_800_000_600)
        ),
        consent: .notRequired
      )
    )
    let mismatchedFilter = await bridge.invalidate(
      CoreAgentRunAppIntentDonationInvalidationRequest(
        receipt: receipt,
        request: CoreAgentAppIntentDonationInvalidationRequest(
          donationIdentifier: record.donationIdentifier,
          scopeID: "workspace:other",
          reason: .erased,
          invalidatedAt: Date(timeIntervalSince1970: 1_800_000_600)
        ),
        consent: .notRequired
      )
    )

    #expect(denied.status == .denied(.missingConsent(.appIntentDonation)))
    #expect(mismatchedFilter.status == .skipped)
    #expect(await backend.deletedTokens.isEmpty)
    #expect(await store.activeRecords() == [record])
  }

  @Test("Bridge denies unsupported CoreAgent modes before executing host work")
  func bridgeDeniesUnsupportedCoreAgentModesBeforeExecutingHostWork() async throws {
    let recorder = BridgeRecorder()
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(
      actionGate: gate,
      checkpoint: { request in
        await recorder.record("checkpoint:\(request.checkpointKey ?? "none")")
      }
    )
    let descriptor = Self.pauseRunDescriptor(supportedModes: [.app])
    let request = CoreAgentAppIntentBridgeRequest(
      actionID: "pause-run",
      descriptor: descriptor,
      mode: .siri,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "unsupported-mode-receipt",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .siri,
          target: .foreground
        ))
      )),
      checkpointKey: "run:abc"
    )

    let result = await bridge.perform(request) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(result.status == .denied(.unsupportedAppIntentMode(
      identifier: "CoreAgentPauseRunIntent",
      mode: .siri
    )))
    #expect(await recorder.events == [])
  }

  @Test("Bridge requires CoreAgent consent and checkpoints before host work")
  func bridgeRequiresCoreAgentConsentAndCheckpointsBeforeHostWork() async throws {
    let recorder = BridgeRecorder()
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(
      actionGate: gate,
      checkpoint: { request in
        await recorder.record("checkpoint:\(request.checkpointKey ?? "none")")
      }
    )
    let descriptor = Self.pauseRunDescriptor(supportedModes: [.app])
    let deniedRequest = CoreAgentAppIntentBridgeRequest(
      actionID: "pause-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .notRequired,
      checkpointKey: "run:abc"
    )

    let denied = await bridge.perform(deniedRequest) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(denied.status == .denied(.missingConsent(.appIntentExecution)))
    #expect(await recorder.events == [])

    let allowedRequest = CoreAgentAppIntentBridgeRequest(
      actionID: "pause-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "pause-run-receipt",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .app,
          target: .foreground
        ))
      )),
      checkpointKey: "run:abc"
    )

    let allowed = await bridge.perform(allowedRequest) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(allowed.status == .completed)
    #expect(await recorder.events == [
      "checkpoint:run:abc",
      "operation:pause-run",
    ])
  }

  @Test("Bridge observes cancellation before checkpoint or host work")
  func bridgeObservesCancellationBeforeCheckpointOrHostWork() async throws {
    let recorder = BridgeRecorder()
    let gate = Self.appIntentGate()
    let bridge = CoreAgentAppIntentBridge(
      actionGate: gate,
      checkpoint: { request in
        await recorder.record("checkpoint:\(request.checkpointKey ?? "none")")
      }
    )
    let descriptor = Self.pauseRunDescriptor(supportedModes: [.app])
    let request = CoreAgentAppIntentBridgeRequest(
      actionID: "pause-run",
      descriptor: descriptor,
      mode: .app,
      target: .foreground,
      consent: .granted(Self.receipt(
        id: "cancelled-receipt",
        requirement: gate.consentRequirement(for: .appIntent(
          descriptor: descriptor,
          mode: .app,
          target: .foreground
        ))
      )),
      checkpointKey: "run:abc",
      isCancelled: { true }
    )

    let result = await bridge.perform(request) { request in
      await recorder.record("operation:\(request.actionID)")
      return CoreAgentAppIntentBridgeOperationResult()
    }

    #expect(result.status == .cancelled)
    #expect(await recorder.events == [])
  }

  private static func pauseRunDescriptor(
    supportedModes: Set<CoreAgentAppleAppIntentMode>
  ) -> CoreAgentAppIntentDescriptor {
    CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentPauseRunIntent",
      title: "Pause Run",
      mutability: .mutating,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: supportedModes,
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: true,
      requiresHITLForSensitiveOperations: true
    )
  }

  private static func appIntentGate() -> CoreAgentAppleActionGate {
    CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.appIntentExecution],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27
      ),
      trustedConsentIssuerID: issuerID,
      consentSigningKey: signingKey,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private static func appIntentDonationGate(
    capabilities: Set<CoreAgentAppleExecutionCapability> = [.appIntentDonation]
  ) -> CoreAgentAppleActionGate {
    CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: capabilities,
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent"),
        networkPolicy: .denied,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 27
      ),
      trustedConsentIssuerID: issuerID,
      consentSigningKey: signingKey,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private static func runtimeEnvironment(
    gate: CoreAgentAppleActionGate,
    recorder: RuntimeRecorder,
    mode: @escaping @Sendable (CoreAgentRunAppIntentRuntimeRequest) -> CoreAgentAppleAppIntentMode = {
      _ in .app
    },
    target: @escaping @Sendable (CoreAgentRunAppIntentRuntimeRequest)
      -> CoreAgentAppleAppIntentExecutionTarget = { _ in .foreground },
    consent: (@Sendable (CoreAgentRunAppIntentRuntimeRequest) -> CoreAgentAppleConsent)? = nil,
    checkpointKey: @escaping @Sendable (CoreAgentRunAppIntentRuntimeRequest) -> String? = {
      "run:\($0.runID)"
    }
  ) -> CoreAgentRunAppIntentRuntimeEnvironment {
    CoreAgentRunAppIntentRuntimeEnvironment(
      bridge: CoreAgentAppIntentBridge(actionGate: gate),
      mode: mode,
      target: target,
      consent: consent ?? { request in
        .granted(Self.receipt(
          id: "runtime-\(request.kind.rawValue)-\(request.runID)-\(UUID().uuidString)",
          requirement: gate.consentRequirement(for: .appIntent(
            descriptor: Self.descriptor(for: request.kind),
            mode: mode(request),
            target: target(request)
          ))
        ))
      },
      checkpointKey: checkpointKey,
      operation: { request in
        await recorder.record(request)
      }
    )
  }

  private static func descriptor(
    for kind: CoreAgentRunAppIntentKind
  ) -> CoreAgentAppIntentDescriptor {
    switch kind {
    case .openRun:
      CoreAgentOpenRunIntent.coreAgentDescriptor
    case .pauseRun:
      CoreAgentPauseRunIntent.coreAgentDescriptor
    case .continueRun:
      CoreAgentContinueRunIntent.coreAgentDescriptor
    }
  }

  private static func receipt(
    id: String,
    requirement: CoreAgentAppleConsentRequirement
  ) -> CoreAgentAppleConsentReceipt {
    CoreAgentAppleConsentReceipt.issue(
      id: id,
      issuerID: issuerID,
      requirement: requirement,
      signingKey: signingKey,
      grantedAt: Date(timeIntervalSince1970: 1_799_999_900),
      expiresAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
  }

  private static let issuerID = "coreagent.test.appintents"
  private static let signingKey = CoreAgentAppleConsentSigningKey(
    Data(repeating: 0x41, count: 32)
  )!
}

private actor BridgeRecorder {
  private var recordedEvents: [String] = []

  var events: [String] {
    recordedEvents
  }

  func record(_ event: String) {
    recordedEvents.append(event)
  }
}

private actor RuntimeRecorder {
  private var recordedRequests: [CoreAgentRunAppIntentRuntimeRequest] = []

  var requests: [CoreAgentRunAppIntentRuntimeRequest] {
    recordedRequests
  }

  func record(_ request: CoreAgentRunAppIntentRuntimeRequest) {
    recordedRequests.append(request)
  }
}

private final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var checks = 0

  func cancelAfterFirstCheck() -> Bool {
    lock.withLock {
      checks += 1
      return checks > 1
    }
  }
}

private struct FakeRunDonationKey: Hashable, Sendable {
  let kind: CoreAgentRunAppIntentKind
  let runID: String
}

private actor FakeRunDonationBackend: CoreAgentRunAppIntentDonationBackend {
  private let tokens: [FakeRunDonationKey: CoreAgentAppIntentOSDonationToken]
  private let deletedTokenResults: [CoreAgentAppIntentOSDonationToken:
    [CoreAgentAppIntentOSDonationToken]]
  private var recordedDonationRequests: [CoreAgentRunAppIntentDonationBackendRequest] = []
  private var recordedDeletedTokens: [CoreAgentAppIntentOSDonationToken] = []

  init(
    tokens: [FakeRunDonationKey: CoreAgentAppIntentOSDonationToken],
    deletedTokens: [CoreAgentAppIntentOSDonationToken: [CoreAgentAppIntentOSDonationToken]] = [:]
  ) {
    self.tokens = tokens
    self.deletedTokenResults = deletedTokens
  }

  var donationRequests: [CoreAgentRunAppIntentDonationBackendRequest] {
    recordedDonationRequests
  }

  var deletedTokens: [CoreAgentAppIntentOSDonationToken] {
    recordedDeletedTokens
  }

  func donate(
    _ request: CoreAgentRunAppIntentDonationBackendRequest
  ) async throws -> CoreAgentAppIntentOSDonationToken {
    recordedDonationRequests.append(request)
    return tokens[FakeRunDonationKey(kind: request.kind, runID: request.runID)]
      ?? CoreAgentAppIntentOSDonationToken(
      encodedIdentifier: Data("os:\(request.kind.rawValue):\(request.runID)".utf8)
    )
  }

  func deleteDonation(
    _ token: CoreAgentAppIntentOSDonationToken
  ) async throws -> [CoreAgentAppIntentOSDonationToken] {
    recordedDeletedTokens.append(token)
    return deletedTokenResults[token] ?? [token]
  }
}
