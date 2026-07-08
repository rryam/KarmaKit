import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CryptoKit
import Foundation
import Observation
import SwiftData

public struct CoreAgentAppleHelperCodeInterpreterLimits:
  Codable, Equatable, Sendable
{
  public let maxArgumentCount: Int
  public let maxArgumentBytes: Int
  public let maxEnvironmentEntryCount: Int
  public let maxEnvironmentBytes: Int
  public let maxStandardInputBytes: Int
  public let maxStdoutBytes: Int
  public let maxStderrBytes: Int
  public let maxOutputBytes: Int
  public let maxOutputCount: Int
  public let maxValueBytes: Int

  public init(
    maxArgumentCount: Int = 32,
    maxArgumentBytes: Int = 16 * 1024,
    maxEnvironmentEntryCount: Int = 64,
    maxEnvironmentBytes: Int = 16 * 1024,
    maxStandardInputBytes: Int = 64 * 1024,
    maxStdoutBytes: Int = 64 * 1024,
    maxStderrBytes: Int = 64 * 1024,
    maxOutputBytes: Int = 64 * 1024,
    maxOutputCount: Int = 128,
    maxValueBytes: Int = 16 * 1024
  ) {
    self.maxArgumentCount = maxArgumentCount
    self.maxArgumentBytes = maxArgumentBytes
    self.maxEnvironmentEntryCount = maxEnvironmentEntryCount
    self.maxEnvironmentBytes = maxEnvironmentBytes
    self.maxStandardInputBytes = maxStandardInputBytes
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxOutputCount = maxOutputCount
    self.maxValueBytes = maxValueBytes
  }
}

public struct CoreAgentAppleHelperCodeInterpreterRequest:
  Codable, Equatable, Sendable
{
  public let id: String
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectory: URL?
  public let standardInput: String
  public let networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess
  public let limits: CoreAgentAppleHelperCodeInterpreterLimits

  public init(
    id: String,
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    workingDirectory: URL? = nil,
    standardInput: String = "",
    networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess = .none,
    limits: CoreAgentAppleHelperCodeInterpreterLimits = .init()
  ) {
    self.id = id
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.standardInput = standardInput
    self.networkAccess = networkAccess
    self.limits = limits
  }
}

public struct CoreAgentAppleHelperCodeInterpreterPolicy: Equatable, Sendable {
  public static let defaultBlockedExecutableNames: Set<String> = [
    "bash",
    "csh",
    "fish",
    "sh",
    "tcsh",
    "zsh",
  ]

  public let allowedExecutableURLs: Set<URL>
  public let blockedExecutableNames: Set<String>

  public init(
    allowedExecutableURLs: Set<URL>,
    blockedExecutableNames: Set<String> = Self.defaultBlockedExecutableNames
  ) {
    self.allowedExecutableURLs = Set(
      allowedExecutableURLs.map(Self.canonicalFileURL(_:))
    )
    self.blockedExecutableNames = Set(blockedExecutableNames.map { $0.lowercased() })
  }

  fileprivate static func canonicalFileURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }
}

public struct CoreAgentAppleAuthorizedHelperCodeInterpreterRequest:
  Equatable, Sendable
{
  public let request: CoreAgentAppleHelperCodeInterpreterRequest
  public let canonicalExecutableURL: URL
  public let canonicalWorkingDirectory: URL
  public let authorityBoundaryID: String
  public let policyVersion: Int
  public let workspaceRoot: URL
  public let networkPolicy: CoreAgentAppleNetworkPolicy
  public let programDigest: String
  public let inputDigest: String

  public init(
    request: CoreAgentAppleHelperCodeInterpreterRequest,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL,
    authorityBoundaryID: String,
    policyVersion: Int,
    workspaceRoot: URL,
    networkPolicy: CoreAgentAppleNetworkPolicy,
    programDigest: String,
    inputDigest: String
  ) {
    self.request = request
    self.canonicalExecutableURL = canonicalExecutableURL
    self.canonicalWorkingDirectory = canonicalWorkingDirectory
    self.authorityBoundaryID = authorityBoundaryID
    self.policyVersion = policyVersion
    self.workspaceRoot = workspaceRoot
    self.networkPolicy = networkPolicy
    self.programDigest = programDigest
    self.inputDigest = inputDigest
  }
}

public struct CoreAgentAppleHelperCodeInterpreterBackendResult:
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

public struct CoreAgentAppleHelperCodeInterpreterBackend: Sendable {
  private let runHandler:
    @Sendable (
      CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
    ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult

  public init(
    _ run:
      @escaping @Sendable (
        CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
      ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult
  ) {
    self.runHandler = run
  }

  public func run(
    _ request: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
  ) async throws -> CoreAgentAppleHelperCodeInterpreterBackendResult {
    try await runHandler(request)
  }
}

public struct CoreAgentAppleHelperCodeInterpreter: Sendable {
  public let actionGate: CoreAgentAppleActionGate
  public let policy: CoreAgentAppleHelperCodeInterpreterPolicy
  public let backend: CoreAgentAppleHelperCodeInterpreterBackend
  private let clock: @Sendable () -> Date

  public init(
    actionGate: CoreAgentAppleActionGate,
    policy: CoreAgentAppleHelperCodeInterpreterPolicy,
    backend: CoreAgentAppleHelperCodeInterpreterBackend,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.actionGate = actionGate
    self.policy = policy
    self.backend = backend
    self.clock = clock
  }

  public func consentRequirement(
    for request: CoreAgentAppleHelperCodeInterpreterRequest
  ) -> CoreAgentAppleConsentRequirement {
    let digests = Self.digests(
      for: request,
      actionGate: actionGate
    )
    return actionGate.consentRequirement(
      for: .codeInterpreterInvocation(
        tier: .helperProcess,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest
      ))
  }

  public func run(
    _ request: CoreAgentAppleHelperCodeInterpreterRequest,
    consent: CoreAgentAppleConsent
  ) async -> CoreAgentAppleCodeInterpreterResult {
    let startedAt = clock()
    let canonicalExecutableURL = Self.canonicalFileURL(request.executableURL)
    let canonicalWorkingDirectory = Self.canonicalFileURL(
      request.workingDirectory ?? actionGate.sandbox.workspaceRoot
    )
    let digests = Self.digests(
      for: request,
      actionGate: actionGate,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory
    )

    if let failure = Self.requestFailure(
      request,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory,
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

    let gateDecision = actionGate.evaluate(
      .codeInterpreterInvocation(
        tier: .helperProcess,
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
    if Task.isCancelled {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
        outputs: [:]
      )
    }

    let authorizedRequest = CoreAgentAppleAuthorizedHelperCodeInterpreterRequest(
      request: request,
      canonicalExecutableURL: canonicalExecutableURL,
      canonicalWorkingDirectory: canonicalWorkingDirectory,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion,
      workspaceRoot: actionGate.sandbox.workspaceRoot,
      networkPolicy: actionGate.sandbox.networkPolicy,
      programDigest: digests.programDigest,
      inputDigest: digests.inputDigest
    )

    let backendResult: CoreAgentAppleHelperCodeInterpreterBackendResult
    do {
      backendResult = try await backend.run(authorizedRequest)
    } catch is CancellationError {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
        outputs: [:]
      )
    } catch {
      if Task.isCancelled {
        return result(
          requestID: request.id,
          startedAt: startedAt,
          programDigest: digests.programDigest,
          inputDigest: digests.inputDigest,
          status: .failed(.cancelled),
          stdout: "",
          stderr: CoreAgentAppleCodeInterpreterFailure.cancelled.description,
          outputs: [:]
        )
      }
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.backendFailed),
        stdout: "",
        stderr: CoreAgentAppleCodeInterpreterFailure.backendFailed.description,
        outputs: [:]
      )
    }

    if Task.isCancelled {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.cancelled),
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    }
    if backendResult.exitCode != 0 {
      return result(
        requestID: request.id,
        startedAt: startedAt,
        programDigest: digests.programDigest,
        inputDigest: digests.inputDigest,
        status: .failed(.nonZeroExitStatus(backendResult.exitCode)),
        stdout: backendResult.stdout,
        stderr: backendResult.stderr,
        outputs: backendResult.outputs
      )
    }
    if let failure = Self.backendOutputFailure(backendResult, limits: request.limits) {
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
        tier: .helperProcess,
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
    _ request: CoreAgentAppleHelperCodeInterpreterRequest,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL,
    policy: CoreAgentAppleHelperCodeInterpreterPolicy,
    sandbox: CoreAgentAppleSandboxProfile
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    guard isBoundedNonEmpty(request.id, maxBytes: 128) else {
      return .invalidRequest("request id")
    }
    guard request.executableURL.isFileURL, !canonicalExecutableURL.path.isEmpty else {
      return .invalidRequest("executable url")
    }
    let executableName = canonicalExecutableURL.lastPathComponent.lowercased()
    guard !policy.blockedExecutableNames.contains(executableName) else {
      return .blockedExecutableName(executableName)
    }
    guard policy.allowedExecutableURLs.contains(canonicalExecutableURL) else {
      return .executableNotAllowed(canonicalExecutableURL.path)
    }
    guard canonicalWorkingDirectory.isFileURL else {
      return .invalidRequest("working directory")
    }
    guard isInsideWorkspace(canonicalWorkingDirectory, workspaceRoot: sandbox.workspaceRoot) else {
      return .workingDirectoryOutsideWorkspace(canonicalWorkingDirectory.path)
    }
    if let failure = networkFailure(request.networkAccess, policy: sandbox.networkPolicy) {
      return failure
    }
    guard request.arguments.count <= request.limits.maxArgumentCount else {
      return .invalidRequest("argument count")
    }
    let argumentBytes = request.arguments.reduce(0) { $0 + $1.utf8.count }
    guard argumentBytes <= request.limits.maxArgumentBytes else {
      return .invalidRequest("arguments")
    }
    guard request.environment.count <= request.limits.maxEnvironmentEntryCount else {
      return .invalidRequest("environment entry count")
    }
    var environmentBytes = 0
    for (key, value) in request.environment {
      guard isEnvironmentKey(key) else {
        return .invalidRequest("environment key")
      }
      environmentBytes += key.utf8.count + value.utf8.count
    }
    guard environmentBytes <= request.limits.maxEnvironmentBytes else {
      return .invalidRequest("environment")
    }
    guard request.standardInput.utf8.count <= request.limits.maxStandardInputBytes else {
      return .inputLimitExceeded(
        max: request.limits.maxStandardInputBytes,
        actual: request.standardInput.utf8.count
      )
    }
    return nil
  }

  private static func backendOutputFailure(
    _ result: CoreAgentAppleHelperCodeInterpreterBackendResult,
    limits: CoreAgentAppleHelperCodeInterpreterLimits
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    let stdoutBytes = result.stdout.utf8.count
    guard stdoutBytes <= limits.maxStdoutBytes else {
      return .stdoutLimitExceeded(max: limits.maxStdoutBytes, actual: stdoutBytes)
    }
    let stderrBytes = result.stderr.utf8.count
    guard stderrBytes <= limits.maxStderrBytes else {
      return .stderrLimitExceeded(max: limits.maxStderrBytes, actual: stderrBytes)
    }
    guard result.outputs.count <= limits.maxOutputCount else {
      return .outputLimitExceeded(max: limits.maxOutputCount, actual: result.outputs.count)
    }
    var outputBytes = stdoutBytes + stderrBytes
    for (name, value) in result.outputs {
      guard isValidOutputName(name) else {
        return .invalidOutputName(name)
      }
      guard !value.isNonFiniteNumber else {
        return .nonFiniteNumber(name)
      }
      let valueBytes = value.description.utf8.count
      guard valueBytes <= limits.maxValueBytes else {
        return .valueLimitExceeded(max: limits.maxValueBytes, actual: valueBytes)
      }
      outputBytes += name.utf8.count + valueBytes
    }
    guard outputBytes <= limits.maxOutputBytes else {
      return .outputLimitExceeded(max: limits.maxOutputBytes, actual: outputBytes)
    }
    return nil
  }

  private static func digests(
    for request: CoreAgentAppleHelperCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate
  ) -> (programDigest: String, inputDigest: String) {
    digests(
      for: request,
      actionGate: actionGate,
      canonicalExecutableURL: canonicalFileURL(request.executableURL),
      canonicalWorkingDirectory: canonicalFileURL(
        request.workingDirectory ?? actionGate.sandbox.workspaceRoot
      )
    )
  }

  private static func digests(
    for request: CoreAgentAppleHelperCodeInterpreterRequest,
    actionGate: CoreAgentAppleActionGate,
    canonicalExecutableURL: URL,
    canonicalWorkingDirectory: URL
  ) -> (programDigest: String, inputDigest: String) {
    let program = ProgramDigestInput(
      executablePath: canonicalExecutableURL.path,
      arguments: request.arguments,
      environment: request.environment,
      workingDirectoryPath: canonicalWorkingDirectory.path,
      networkAccess: request.networkAccess,
      authorityBoundaryID: actionGate.sandbox.authorityBoundaryID,
      policyVersion: actionGate.sandbox.policyVersion
    )
    return (
      digest(program),
      digest(InputDigestInput(standardInput: request.standardInput))
    )
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    CoreAgentAppleHelperCodeInterpreterPolicy.canonicalFileURL(url)
  }

  private static func networkFailure(
    _ access: CoreAgentAppleHelperCodeInterpreterNetworkAccess,
    policy: CoreAgentAppleNetworkPolicy
  ) -> CoreAgentAppleCodeInterpreterFailure? {
    switch (access, policy) {
    case (.none, _):
      nil
    case (.localOnly, .localOnly), (.localOnly, .allowed):
      nil
    case (.remote, .allowed):
      nil
    case (.localOnly, _), (.remote, _):
      .networkAccessDenied(requested: access, policy: policy)
    }
  }

  private static func isInsideWorkspace(
    _ candidate: URL,
    workspaceRoot: URL
  ) -> Bool {
    let rootPath = canonicalFileURL(workspaceRoot).path
    let candidatePath = canonicalFileURL(candidate).path
    if rootPath == "/" {
      return true
    }
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private static func isEnvironmentKey(_ key: String) -> Bool {
    guard isBoundedNonEmpty(key, maxBytes: 128), !key.contains("=") else {
      return false
    }
    return key.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || ("a"..."z").contains(scalar)
        || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
  }

  private static func isBoundedNonEmpty(_ value: String, maxBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !value.isEmpty && value.utf8.count <= maxBytes
  }

  private static func isValidOutputName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == name, !name.isEmpty, name.utf8.count <= 128,
      name != ".", name != ".."
    else {
      return false
    }
    guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
      return false
    }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar == "_" || scalar == "-" || scalar == "."
        || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar)
    }
  }

  private static func digest(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    let data = try! encoder.encode(value)
    return "sha256:" + sha256Hex(data)
  }

  private struct ProgramDigestInput: Encodable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String
    let networkAccess: CoreAgentAppleHelperCodeInterpreterNetworkAccess
    let authorityBoundaryID: String
    let policyVersion: Int
  }

  private struct InputDigestInput: Encodable {
    let standardInput: String
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension CoreAgentAppleCodeValue {
  fileprivate var isNonFiniteNumber: Bool {
    if case .number(let value) = self {
      return !value.isFinite
    }
    return false
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
