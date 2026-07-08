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
  @Test("Deterministic code interpreter enforces intermediate state bounds")
  func deterministicCodeInterpreterEnforcesIntermediateStateBounds() async {
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.deterministicCodeInterpreter],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
          networkPolicy: .denied
        )
      ))
    let oversizedLiteral = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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
    let intermediateGrowth = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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

    #expect(
      oversizedLiteral.status
        == .failed(
          .valueLimitExceeded(max: 4, actual: 6)
        ))
    #expect(oversizedLiteral.stdout.isEmpty)
    #expect(
      intermediateGrowth.status
        == .failed(
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
    let result = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
        sandbox: CoreAgentAppleSandboxProfile(
          capabilities: [.deterministicCodeInterpreter],
          workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-sandbox"),
          networkPolicy: .denied
        )
      ))
    let nonFiniteInput = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
        id: "non-finite-input",
        program: CoreAgentAppleDeterministicProgram(instructions: [
          .emit(.input("bad"))
        ]),
        inputs: ["bad": .number(.nan)]
      ))
    let nonFiniteLiteral = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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
    let interpreter = CoreAgentAppleDeterministicCodeInterpreter(
      actionGate: CoreAgentAppleActionGate(
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
      return await interpreter.run(
        CoreAgentAppleDeterministicCodeRequest(
          id: "cancelled",
          program: CoreAgentAppleDeterministicProgram(instructions: [
            .set("value", .string("should not run"))
          ])
        ))
    }.value
    let invalidVariable = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
        id: "invalid-variable",
        program: CoreAgentAppleDeterministicProgram(instructions: [
          .set("bad/name", .string("value"))
        ])
      ))
    let duplicateOutput = await interpreter.run(
      CoreAgentAppleDeterministicCodeRequest(
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
    let helperURL = URL(
      fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
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
    #expect(
      broadConsent.status
        == .denied(
          .consentRequestMismatch(
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
    let helperURL = URL(
      fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
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
      consent: .granted(
        Self.receipt(
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
    #expect(
      notAllowed.status
        == .failed(
          .executableNotAllowed(
            Self.canonicalTestURL(URL(fileURLWithPath: "/usr/bin/python3")).path
          )))
    #expect(
      outsideWorkspace.status
        == .failed(
          .workingDirectoryOutsideWorkspace(
            Self.canonicalTestURL(URL(fileURLWithPath: "/tmp/other-workspace")).path
          )))
    #expect(await recorder.runCount == 0)
  }

  @Test("Helper code interpreter enforces request and backend output bounds")
  func helperCodeInterpreterEnforcesRequestAndBackendOutputBounds() async {
    let now = Date(timeIntervalSince1970: 1_800_000_150)
    let workspace = URL(fileURLWithPath: "/tmp/coreagent-helper")
    let helperURL = URL(
      fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
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
    let helperURL = URL(
      fileURLWithPath: "/Applications/CoreAgentHelper.app/Contents/MacOS/CoreAgentHelper")
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

    #expect(
      deniedNetwork.status
        == .failed(
          .networkAccessDenied(
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

}
