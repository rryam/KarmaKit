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
        .prompt(
          .init(segments: [
            .custom(
              ApplePlatformTestCustomSegment(
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

    #expect(
      codeGate.evaluate(
        .codeInterpreter(tier: .deterministicInProcess),
        consent: .notRequired
      ).isAllowed)

    #expect(
      codeGate.evaluate(
        .computerUse(actionID: "click-toolbar-save"),
        consent: .granted(
          Self.receipt(
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

    #expect(
      automationGate.evaluate(
        .computerUse(actionID: "click-toolbar-save"),
        consent: .notRequired
      ) == .denied(.missingConsent(.computerUse)))
    let requirement = automationGate.consentRequirement(
      for: .computerUse(actionID: "click-toolbar-save")
    )
    #expect(
      automationGate.evaluate(
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
    #expect(
      gate.evaluate(request, consent: .granted(wrongCapability))
        == .denied(
          .consentCapabilityMismatch(expected: .computerUse, actual: .remoteCodeInterpreter)
        ))

    let otherActionRequirement = gate.consentRequirement(
      for: .computerUse(actionID: "click-toolbar-open")
    )
    #expect(
      gate.evaluate(
        request,
        consent: .granted(Self.receipt(id: "receipt-2", requirement: otherActionRequirement))
      )
        == .denied(
          .consentRequestMismatch(
            expected: requirement.requestFingerprint,
            actual: otherActionRequirement.requestFingerprint
          )))

    #expect(
      gate.evaluate(
        request,
        consent: .granted(Self.receipt(id: " ", requirement: requirement))
      ) == .denied(.invalidConsentReceipt("empty receipt id")))

    #expect(
      gate.evaluate(
        request,
        consent: .granted(
          Self.receipt(
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
    #expect(
      gate.evaluate(request, consent: .granted(noExpiry))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(receipt))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(futureReceipt))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(wrongAuthority))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(wrongPolicy))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(wrongIssuer))
        == .denied(
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
    #expect(
      gate.evaluate(request, consent: .granted(wrongSignature))
        == .denied(
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
    #expect(
      noVerifierGate.evaluate(
        request,
        consent: .granted(
          Self.receipt(id: "receipt-no-verifier", requirement: noVerifierRequirement))
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
    #expect(
      throws: CoreAgentAppIntentDescriptorError.foregroundExecutionRequired(
        identifier: "CoreAgentDeleteTaskIntent"
      )
    ) {
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
    #expect(
      throws: CoreAgentAppIntentDescriptorError.authorizationRequired(
        identifier: "CoreAgentCreateTaskIntent"
      )
    ) {
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
    #expect(
      throws: CoreAgentAppIntentDescriptorError.agentExposureRequired(
        identifier: "CoreAgentHiddenIntent"
      )
    ) {
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

    #expect(
      gate.evaluate(
        foregroundRequest,
        consent: .granted(Self.receipt(id: "intent-receipt-1", requirement: foregroundRequirement))
      ).isAllowed)

    let backgroundRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .app,
      target: .background
    )
    #expect(
      gate.evaluate(
        backgroundRequest,
        consent: .granted(
          Self.receipt(
            id: "intent-receipt-2",
            requirement: gate.consentRequirement(for: backgroundRequest)
          ))
      )
        == .denied(
          .appIntentExecutionTargetRequiresForeground(
            identifier: "CoreAgentCreateTaskIntent",
            target: .background
          )))

    let unsupportedModeRequest = CoreAgentAppleExecutionRequest.appIntent(
      descriptor: descriptor,
      mode: .siri,
      target: .foreground
    )
    #expect(
      gate.evaluate(
        unsupportedModeRequest,
        consent: .granted(
          Self.receipt(
            id: "intent-receipt-3",
            requirement: gate.consentRequirement(for: unsupportedModeRequest)
          ))
      )
        == .denied(
          .unsupportedAppIntentMode(
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

    #expect(
      gate.evaluate(
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
    let result = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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
    let tooManyInstructions = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
        id: "too-many",
        program: CoreAgentAppleDeterministicProgram(instructions: [
          .set("first", .string("a")),
          .emit(.variable("first")),
        ]),
        limits: .init(maxInstructionCount: 1, maxOutputBytes: 128)
      ))
    let tooMuchOutput = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
        id: "too-much-output",
        program: CoreAgentAppleDeterministicProgram(instructions: [
          .emit(.literal(.string("abcdef")))
        ]),
        limits: .init(maxInstructionCount: 4, maxOutputBytes: 4)
      ))

    #expect(
      tooManyInstructions.status
        == .failed(
          .instructionLimitExceeded(max: 1, actual: 2)
        ))
    #expect(tooManyInstructions.stdout.isEmpty)
    #expect(
      tooMuchOutput.status
        == .failed(
          .outputLimitExceeded(max: 4, actual: 7)
        ))
    #expect(tooMuchOutput.outputs.isEmpty)
  }

}
