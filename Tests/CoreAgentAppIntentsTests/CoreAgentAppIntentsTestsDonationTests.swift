import AppIntents
import CoreAgentApplePlatform
import Foundation
import Testing

@testable import CoreAgentAppIntents

extension CoreAgentAppIntentsTests {
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
      consent: .granted(
        Self.receipt(
          id: "unsupported-mode-receipt",
          requirement: gate.consentRequirement(
            for: .appIntent(
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

    #expect(
      result.status
        == .denied(
          .unsupportedAppIntentMode(
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
      consent: .granted(
        Self.receipt(
          id: "pause-run-receipt",
          requirement: gate.consentRequirement(
            for: .appIntent(
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
    #expect(
      await recorder.events == [
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
      consent: .granted(
        Self.receipt(
          id: "cancelled-receipt",
          requirement: gate.consentRequirement(
            for: .appIntent(
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

  static func pauseRunDescriptor(
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

  static func appIntentGate() -> CoreAgentAppleActionGate {
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

  static func appIntentDonationGate(
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

  static func runtimeEnvironment(
    gate: CoreAgentAppleActionGate,
    recorder: RuntimeRecorder,
    mode: @escaping @Sendable (CoreAgentRunAppIntentRuntimeRequest) -> CoreAgentAppleAppIntentMode =
      {
        _ in .app
      },
    target:
      @escaping @Sendable (CoreAgentRunAppIntentRuntimeRequest)
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
        .granted(
          Self.receipt(
            id: "runtime-\(request.kind.rawValue)-\(request.runID)-\(UUID().uuidString)",
            requirement: gate.consentRequirement(
              for: .appIntent(
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

  static func descriptor(
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

  static func receipt(
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

  static let issuerID = "coreagent.test.appintents"
  static let signingKey = CoreAgentAppleConsentSigningKey(
    Data(repeating: 0x41, count: 32)
  )!
}
