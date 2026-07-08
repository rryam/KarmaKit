import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public struct CoreAgentAppleRemoteCodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxStandardInputBytes: Int
  public let maxStandardOutputBytes: Int
  public let maxStandardErrorBytes: Int
  public let maxTypedOutputBytes: Int

  public init(
    maxStandardInputBytes: Int = 65_536,
    maxStandardOutputBytes: Int = 65_536,
    maxStandardErrorBytes: Int = 65_536,
    maxTypedOutputBytes: Int = 65_536
  ) {
    self.maxStandardInputBytes = max(0, maxStandardInputBytes)
    self.maxStandardOutputBytes = max(0, maxStandardOutputBytes)
    self.maxStandardErrorBytes = max(0, maxStandardErrorBytes)
    self.maxTypedOutputBytes = max(0, maxTypedOutputBytes)
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let endpointURL: URL
  public let standardInput: String
  public let limits: CoreAgentAppleRemoteCodeInterpreterLimits

  public init(
    id: String,
    endpointURL: URL,
    standardInput: String = "",
    limits: CoreAgentAppleRemoteCodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.endpointURL = endpointURL
    self.standardInput = standardInput
    self.limits = limits
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterPolicy: Equatable, Sendable {
  public let allowedEndpointURLs: Set<URL>

  public init(allowedEndpointURLs: Set<URL>) {
    self.allowedEndpointURLs = Set(
      allowedEndpointURLs.map { $0.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) }
        .compactMap { URL(string: $0) }
    )
  }
}

public struct CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleRemoteCodeInterpreterRequest
  public let canonicalEndpointURL: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleRemoteCodeInterpreterRequest,
    canonicalEndpointURL: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalEndpointURL = canonicalEndpointURL
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterBackendResult:
  Codable, Equatable, Sendable
{
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String
  public let outputs: [String: CoreAgentAppleCodeValue]

  public init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue] = [:]
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.outputs = outputs
  }
}

public struct CoreAgentAppleRemoteCodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
    ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult

  public init(
    _ run:
      @escaping @Sendable (
        CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
      ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest
  ) async throws -> CoreAgentAppleRemoteCodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleRemoteCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleRemoteCodeInterpreterPolicy
  public let backend: CoreAgentAppleRemoteCodeInterpreterBackend?
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleRemoteCodeInterpreterPolicy,
    backend: CoreAgentAppleRemoteCodeInterpreterBackend? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleRemoteCodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(for: request, actionGate: actionGate)
    return actionGate.consentRequirement(
      for: .codeInterpreterInvocation(
        tier: .remote,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ))
  }

  public func run(
    _ request: CoreAgentAppleRemoteCodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalEndpointURL = request.endpointURL
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalEndpointURL: canonicalEndpointURL
    )

    if let failure = Self.requestFailure(
      request,
      canonicalEndpointURL: canonicalEndpointURL,
      policy: policy,
      sandbox: actionGate.sandbox
    ) {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    guard let backend else {
      let failure = CoreAgentAppleCodeInterpreterFailure.invalidRequest(
        "remote backend unavailable"
      )
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }

    let gateDecision = actionGate.evaluate(
      .codeInterpreterInvocation(
        tier: .remote,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ),
      consent: consent
    )
    if case .denied(let denial) = gateDecision {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .denied(denial),
        stdout: "",
        stderr: "",
        outputs: [:]
      )
    }

    let authorized = CoreAgentAppleAuthorizedRemoteCodeInterpreterRequest(
      request: request,
      canonicalEndpointURL: canonicalEndpointURL,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion,
      workspaceRoot: actionGate.sandbox.workspaceRoot,
      networkPolicy: actionGate.sandbox.networkPolicy,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    )

    do {
      let backendResult = try await backend.run(authorized)
      if backendResult.exitCode != 0 {
        let failure = CoreAgentAppleCodeInterpreterFailure.nonZeroExitStatus(
          backendResult.exitCode
        )
        return result(
          requestID: request.id,
          startedAt: startedAt,
          programDigest: digests.programDigest,
          inputDigest: digests.inputDigest,
          status: .failed(failure),
          stdout: backendResult.stdout,
          stderr: backendResult.stderr,
          outputs: backendResult.outputs
        )
      }
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .succeeded,
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    } catch {
      let failure = CoreAgentAppleCodeInterpreterFailure.backendFailed
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(failure),
        stdout: "",
        stderr: failure.description,
        outputs: [:]
      )
    }
  }

  private func result(
    requestID: String,
    startedAt: Date,
    programDigest: String,
    inputDigest: String,
    status: CoreAgentAppleCodeInterpreterStatus,
    stdout: String,
    stderr: String,
    outputs: [String: CoreAgentAppleCodeValue]
  ) -> CoreAgentAppleCodeInterpreterResult {
    CoreAgentAppleCodeInterpreterResult(
      status: status,
      stdout: stdout,
      stderr: stderr,
      outputs: outputs,
      audit: CoreAgentAppleCodeInterpreterAudit(
        requestID: requestID,
        tier: .remote,
        authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
        policyVersion: actionGate.sandbox.policyVersion,
        workspaceRoot: actionGate.sandbox.workspaceRoot,
        networkPolicy: actionGate.sandbox.networkPolicy,
        startedAt: startedAt,
        endedAt: clock(),
        programDigest: programDigest,
        inputDigest: inputDigest,
        status: status
      )
    )
  }

  private static func requestFailure(
    _ request: CoreAgentAppleRemoteCodeInterpreterRequest,
    canonicalEndpointURL: URL,
    policy: CoreAgentAppleRemoteCodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("request id is empty")
    }
    guard let scheme = canonicalEndpointURL.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      return .invalidRequest("endpoint must use http or https")
    }
    guard policy.allowedEndpointURLs.contains(canonicalEndpointURL) else {
      return .invalidRequest("endpoint not allowed")
    }
    if sandbox.networkPolicy != .allowed {
      return .invalidRequest("remote execution requires allowed network policy")
    }
    guard request.standardInput.utf8.count <= request.limits.maxStandardInputBytes else {
      return .inputLimitExceeded(
        max: request.limits.maxStandardInputBytes,
        actual: request.standardInput.utf8.count
      )
    }
    return nil
  }

  private static func digests(
    for request: CoreAgentAppleRemoteCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalEndpointURL: URL? = nil
  ) -> (programDigest: String, inputDigest: String) {
    let endpointURL = canonicalEndpointURL ?? request.endpointURL
    let programPayload: [String: String] = [
      "authority_boundary_id": actionGate.sandbox.authorityBoundaryID,
      "endpoint": endpointURL.absoluteString,
      "policy_version": String(actionGate.sandbox.policyVersion),
      "tier": CoreAgentAppleInterpreterTier.remote.rawValue,
    ]
    let inputPayload: [String: String] = [
      "request_id": request.id,
      "stdin_digest": sha256Digest(request.standardInput),
    ]
    return (
      programDigest: canonicalJSONDigest(programPayload),
      inputDigest: canonicalJSONDigest(inputPayload)
    )
  }

  private static func sha256Digest(_ value: String) -> String {
    "sha256:" + sha256Hex(Data(value.utf8))
  }

  private static func canonicalJSONDigest(_ payload: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(payload)
    return "sha256:" + sha256Hex(data)
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension CoreAgentAppleCodeInterpreterFailure {
  fileprivate var description: String {
    switch self {
    case .cancelled:
      "cancelled"
    case .backendFailed:
      "backend failed"
    case .instructionLimitExceeded(let max, let actual):
      "instruction limit exceeded: max=\(max) actual=\(actual)"
    case .outputLimitExceeded(let max, let actual):
      "output limit exceeded: max=\(max) actual=\(actual)"
    case .inputLimitExceeded(let max, let actual):
      "input limit exceeded: max=\(max) actual=\(actual)"
    case .stateLimitExceeded(let max, let actual):
      "state limit exceeded: max=\(max) actual=\(actual)"
    case .valueLimitExceeded(let max, let actual):
      "value limit exceeded: max=\(max) actual=\(actual)"
    case .operandLimitExceeded(let max, let actual):
      "operand limit exceeded: max=\(max) actual=\(actual)"
    case .variableLimitExceeded(let max, let actual):
      "variable limit exceeded: max=\(max) actual=\(actual)"
    case .undefinedValue(let name):
      "undefined value: \(name)"
    case .typeMismatch(let operation):
      "type mismatch for operation: \(operation)"
    case .invalidIdentifier(let name):
      "invalid identifier: \(name)"
    case .invalidOutputName(let name):
      "invalid output name: \(name)"
    case .duplicateOutputName(let name):
      "duplicate output name: \(name)"
    case .nonFiniteNumber(let name):
      "non-finite number: \(name)"
    case .invalidRequest(let reason):
      "invalid request: \(reason)"
    case .executableNotAllowed(let path):
      "executable not allowed: \(path)"
    case .blockedExecutableName(let name):
      "blocked executable name: \(name)"
    case .workingDirectoryOutsideWorkspace(let path):
      "working directory outside workspace: \(path)"
    case .networkAccessDenied(let requested, let policy):
      "network access denied: requested=\(requested.rawValue) policy=\(policy.rawValue)"
    case .stdoutLimitExceeded(let max, let actual):
      "stdout limit exceeded: max=\(max) actual=\(actual)"
    case .stderrLimitExceeded(let max, let actual):
      "stderr limit exceeded: max=\(max) actual=\(actual)"
    case .nonZeroExitStatus(let exitCode):
      "non-zero exit status: \(exitCode)"
    }
  }
}
