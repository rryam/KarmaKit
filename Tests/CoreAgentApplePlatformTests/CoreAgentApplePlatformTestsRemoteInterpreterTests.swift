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
