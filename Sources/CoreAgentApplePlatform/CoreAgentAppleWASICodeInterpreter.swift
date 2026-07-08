import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public struct CoreAgentAppleWASICodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxModuleBytes: Int
  public let maxStandardInputBytes: Int
  public let maxStdoutBytes: Int
  public let maxStderrBytes: Int
  public let maxOutputBytes: Int
  public let maxOutputCount: Int

  public init(
    maxModuleBytes: Int = 8 * 1024 * 1024,
    maxStandardInputBytes: Int = 64 * 1024,
    maxStdoutBytes: Int = 64 * 1024,
    maxStderrBytes: Int = 64 * 1024,
    maxOutputBytes: Int = 64 * 1024,
    maxOutputCount: Int = 128
  ) {
    self.maxModuleBytes = maxModuleBytes
    self.maxStandardInputBytes = maxStandardInputBytes
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxOutputCount = maxOutputCount
  }
}

public struct CoreAgentAppleWASICodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let moduleURL: URL
  public let entrypoint: String
  public let standardInput: String
  public let limits: CoreAgentAppleWASICodeInterpreterLimits

  public init(
    id: String,
    moduleURL: URL,
    entrypoint: String = "_start",
    standardInput: String = "",
    limits: CoreAgentAppleWASICodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.moduleURL = moduleURL
    self.entrypoint = entrypoint
    self.standardInput = standardInput
    self.limits = limits
  }
}

public struct CoreAgentAppleWASICodeInterpreterPolicy: Equatable, Sendable {
  public let allowedModuleURLs: Set<URL>

  public init(allowedModuleURLs: Set<URL>) {
    self.allowedModuleURLs = Set(
      allowedModuleURLs.map(CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(_:))
    )
  }
}

public struct CoreAgentAppleAuthorizedWASICodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleWASICodeInterpreterRequest
  public let canonicalModuleURL: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleWASICodeInterpreterRequest,
    canonicalModuleURL: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalModuleURL = canonicalModuleURL
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleWASICodeInterpreterBackendResult:
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

public struct CoreAgentAppleWASICodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedWASICodeInterpreterRequest
    ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult

  public init(
    _ run:
      @escaping @Sendable (
        CoreAgentAppleAuthorizedWASICodeInterpreterRequest
      ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedWASICodeInterpreterRequest
  ) async throws -> CoreAgentAppleWASICodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleWASICodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleWASICodeInterpreterPolicy
  public let backend: CoreAgentAppleWASICodeInterpreterBackend?
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleWASICodeInterpreterPolicy,
    backend: CoreAgentAppleWASICodeInterpreterBackend? = nil,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleWASICodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(for: request, actionGate: actionGate)
    return actionGate.consentRequirement(
      for: .codeInterpreterInvocation(
        tier: .wasiWebAssembly,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ))
  }

  public func run(
    _ request: CoreAgentAppleWASICodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalModuleURL = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(
      request.moduleURL
    )
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalModuleURL: canonicalModuleURL
    )

    if let failure = Self.requestFailure(
      request,
      canonicalModuleURL: canonicalModuleURL,
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
        "wasi backend unavailable"
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
        tier: .wasiWebAssembly,
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

    let authorized = CoreAgentAppleAuthorizedWASICodeInterpreterRequest(
      request: request,
      canonicalModuleURL: canonicalModuleURL,
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
        tier: .wasiWebAssembly,
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
    _ request: CoreAgentAppleWASICodeInterpreterRequest,
    canonicalModuleURL: URL,
    policy: CoreAgentAppleWASICodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("request id is empty")
    }
    guard !request.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .invalidRequest("entrypoint is empty")
    }
    guard policy.allowedModuleURLs.contains(canonicalModuleURL) else {
      return .invalidRequest("module not allowed")
    }
    guard isInsideWorkspace(canonicalModuleURL, workspaceRoot: sandbox.workspaceRoot) else {
      return .workingDirectoryOutsideWorkspace(canonicalModuleURL.path)
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
    for request: CoreAgentAppleWASICodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalModuleURL: URL? = nil
  ) -> (programDigest: String, inputDigest: String) {
    let moduleURL =
      canonicalModuleURL
      ?? CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(request.moduleURL)
    let programPayload: [String: String] = [
      "authority_boundary_id": actionGate.sandbox.authorityBoundaryID,
      "entrypoint": request.entrypoint,
      "module_path": moduleURL.path,
      "policy_version": String(actionGate.sandbox.policyVersion),
      "tier": CoreAgentAppleInterpreterTier.wasiWebAssembly.rawValue,
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

  private static func isInsideWorkspace(_ url: URL, workspaceRoot: URL) -> Bool {
    let root = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(workspaceRoot)
    let candidate = CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(url)
    let rootPath = root.path(percentEncoded: false)
    let candidatePath = candidate.path(percentEncoded: false)
    if candidatePath == rootPath { return true }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
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

extension CoreAgentAppleHelperCodeInterpreterPolicy {
  fileprivate static func canonicalFileURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }
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
