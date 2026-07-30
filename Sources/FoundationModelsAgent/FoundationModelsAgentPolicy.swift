import CryptoKit
import Foundation
import FoundationModels

public enum FoundationModelsAgentPolicyError: Error, LocalizedError, Sendable {
  case denied(toolName: String, reason: String)
  case untrustedManifest(toolName: String, digest: String)

  public var errorDescription: String? {
    switch self {
    case .denied(let toolName, let reason):
      "Tool '\(toolName)' was denied: \(reason)"
    case .untrustedManifest(let toolName, let digest):
      "Tool '\(toolName)' has an untrusted manifest digest: \(digest)"
    }
  }
}

public struct FoundationModelsAgentToolManifest: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let description: String
  public let schemaJSON: String
  public let includesSchemaInInstructions: Bool
  public let digest: String

  public init(
    name: String,
    description: String,
    schemaJSON: String,
    includesSchemaInInstructions: Bool = true
  ) {
    self.name = name
    self.description = description
    self.schemaJSON = schemaJSON
    self.includesSchemaInInstructions = includesSchemaInInstructions
    self.digest = Self.digest(
      name: name,
      description: description,
      schemaJSON: schemaJSON,
      includesSchemaInInstructions: includesSchemaInInstructions
    )
  }

  public init(tool: some Tool) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let schemaData = try encoder.encode(tool.parameters)
    self.init(
      name: tool.name,
      description: tool.description,
      schemaJSON: String(decoding: schemaData, as: UTF8.self),
      includesSchemaInInstructions: tool.includesSchemaInInstructions
    )
  }

  private static func digest(
    name: String,
    description: String,
    schemaJSON: String,
    includesSchemaInInstructions: Bool
  ) -> String {
    let data = Data(
      "\(name)\u{0}\(description)\u{0}\(schemaJSON)\u{0}\(includesSchemaInInstructions)".utf8
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct FoundationModelsAgentToolRequest: Sendable {
  public let runID: UUID
  public let invocationID: UUID
  public let manifest: FoundationModelsAgentToolManifest
  public let arguments: GeneratedContent

  public init(
    runID: UUID,
    invocationID: UUID,
    manifest: FoundationModelsAgentToolManifest,
    arguments: GeneratedContent
  ) {
    self.runID = runID
    self.invocationID = invocationID
    self.manifest = manifest
    self.arguments = arguments
  }

  public var argumentsJSON: String {
    arguments.jsonString
  }
}

public protocol FoundationModelsAgentToolPolicy: Sendable {
  func authorize(_ request: FoundationModelsAgentToolRequest) async throws
}

public struct AllowAllFoundationModelsAgentToolPolicy: FoundationModelsAgentToolPolicy {
  public init() {}
  public func authorize(_ request: FoundationModelsAgentToolRequest) async throws {}
}

public struct CompositeFoundationModelsAgentToolPolicy: FoundationModelsAgentToolPolicy {
  private let policies: [any FoundationModelsAgentToolPolicy]

  public init(_ policies: [any FoundationModelsAgentToolPolicy]) {
    self.policies = policies
  }

  public func authorize(_ request: FoundationModelsAgentToolRequest) async throws {
    for policy in policies {
      try await policy.authorize(request)
    }
  }
}

public struct ToolNameAllowlistPolicy: FoundationModelsAgentToolPolicy {
  private let allowedNames: Set<String>

  public init(_ allowedNames: Set<String>) {
    self.allowedNames = allowedNames
  }

  public func authorize(_ request: FoundationModelsAgentToolRequest) async throws {
    guard allowedNames.contains(request.manifest.name) else {
      throw FoundationModelsAgentPolicyError.denied(
        toolName: request.manifest.name,
        reason: "The tool is not in the configured allowlist."
      )
    }
  }
}

public struct TrustedToolManifestPolicy: FoundationModelsAgentToolPolicy {
  private let approvedDigests: Set<String>

  public init(approvedDigests: Set<String>) {
    self.approvedDigests = approvedDigests
  }

  public init(approvedManifests: [FoundationModelsAgentToolManifest]) {
    self.approvedDigests = Set(approvedManifests.map(\.digest))
  }

  public func authorize(_ request: FoundationModelsAgentToolRequest) async throws {
    guard approvedDigests.contains(request.manifest.digest) else {
      throw FoundationModelsAgentPolicyError.untrustedManifest(
        toolName: request.manifest.name,
        digest: request.manifest.digest
      )
    }
  }
}

public enum FoundationModelsAgentApprovalDecision: Equatable, Sendable {
  case approve
  case deny(reason: String)
}

public protocol FoundationModelsAgentApprovalProvider: Sendable {
  func decision(for request: FoundationModelsAgentToolRequest) async throws
    -> FoundationModelsAgentApprovalDecision
}

public struct ClosureFoundationModelsAgentApprovalProvider: FoundationModelsAgentApprovalProvider {
  private let handler:
    @Sendable (FoundationModelsAgentToolRequest) async throws ->
      FoundationModelsAgentApprovalDecision

  public init(
    _ handler:
      @escaping @Sendable (FoundationModelsAgentToolRequest) async throws ->
      FoundationModelsAgentApprovalDecision
  ) {
    self.handler = handler
  }

  public func decision(for request: FoundationModelsAgentToolRequest) async throws
    -> FoundationModelsAgentApprovalDecision
  {
    try await handler(request)
  }
}

public struct ApprovalRequiredToolPolicy: FoundationModelsAgentToolPolicy {
  private let requiredNames: Set<String>?
  private let provider: any FoundationModelsAgentApprovalProvider

  public init(
    requiredNames: Set<String>? = nil,
    provider: any FoundationModelsAgentApprovalProvider
  ) {
    self.requiredNames = requiredNames
    self.provider = provider
  }

  public func authorize(_ request: FoundationModelsAgentToolRequest) async throws {
    if let requiredNames, !requiredNames.contains(request.manifest.name) {
      return
    }
    switch try await provider.decision(for: request) {
    case .approve:
      return
    case .deny(let reason):
      throw FoundationModelsAgentPolicyError.denied(toolName: request.manifest.name, reason: reason)
    }
  }
}

public struct FoundationModelsAgentToolConfiguration: Sendable {
  public var policy: any FoundationModelsAgentToolPolicy
  public var executionTimeout: Duration?
  public var maximumCallsPerRun: Int?

  public init(
    policy: any FoundationModelsAgentToolPolicy = AllowAllFoundationModelsAgentToolPolicy(),
    executionTimeout: Duration? = nil,
    maximumCallsPerRun: Int? = nil
  ) {
    self.policy = policy
    self.executionTimeout = executionTimeout
    self.maximumCallsPerRun = maximumCallsPerRun
  }

  public static let `default` = FoundationModelsAgentToolConfiguration()
}

actor FoundationModelsAgentToolRuntime {
  private var currentRunID: UUID?
  private var callCount = 0
  private var beganToolInvocation = false
  private let maximumCallsPerRun: Int?

  init(maximumCallsPerRun: Int?) {
    self.maximumCallsPerRun = maximumCallsPerRun
  }

  func begin(runID: UUID) {
    currentRunID = runID
    callCount = 0
    beganToolInvocation = false
  }

  func finish(runID: UUID) {
    guard currentRunID == runID else { return }
    currentRunID = nil
    callCount = 0
    beganToolInvocation = false
  }

  func reserveCall() throws -> UUID {
    guard let currentRunID else {
      throw FoundationModelsAgentError.noActiveRun
    }
    if let maximumCallsPerRun, callCount >= maximumCallsPerRun {
      throw FoundationModelsAgentError.toolCallBudgetExceeded(maximum: maximumCallsPerRun)
    }
    callCount += 1
    beganToolInvocation = true
    return currentRunID
  }

  func hasStartedToolInvocation(runID: UUID) -> Bool {
    currentRunID == runID && beganToolInvocation
  }

  func activeRunID() -> UUID? {
    currentRunID
  }
}

struct FoundationModelsAgentGovernedTool: Tool {
  typealias Arguments = GeneratedContent
  typealias Output = Prompt

  let base: FoundationModelsAgentAnyTool
  let manifest: FoundationModelsAgentToolManifest
  let configuration: FoundationModelsAgentToolConfiguration
  let runtime: FoundationModelsAgentToolRuntime
  let recorder: FoundationModelsAgentEventRecorder

  var name: String { base.name }
  var description: String { base.description }
  var parameters: GenerationSchema { base.parameters }
  var includesSchemaInInstructions: Bool { manifest.includesSchemaInInstructions }

  @concurrent
  func call(arguments: GeneratedContent) async throws -> Prompt {
    let runID = try await runtime.reserveCall()
    let invocationID = UUID()
    let request = FoundationModelsAgentToolRequest(
      runID: runID,
      invocationID: invocationID,
      manifest: manifest,
      arguments: arguments
    )
    let attributes = [
      "tool": name,
      "invocation_id": invocationID.uuidString.lowercased(),
      "manifest_digest": manifest.digest,
    ]

    await recorder.record(
      runID: runID,
      kind: .toolAuthorizationStarted,
      message: "Authorizing native tool call.",
      attributes: attributes
    )
    do {
      try await configuration.policy.authorize(request)
      try Task.checkCancellation()
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationSucceeded,
        message: "Native tool call authorized.",
        attributes: attributes
      )
    } catch is CancellationError {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationCancelled,
        message: "Native tool authorization was cancelled.",
        attributes: attributes
      )
      throw CancellationError()
    } catch let error as FoundationModelsAgentPolicyError {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationDenied,
        message: String(describing: error),
        attributes: attributes
      )
      throw error
    } catch {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationFailed,
        message: String(describing: error),
        attributes: attributes
      )
      throw error
    }

    let clock = ContinuousClock()
    let started = clock.now
    await recorder.record(
      runID: runID,
      kind: .toolExecutionStarted,
      message: "Native tool execution started.",
      attributes: attributes
    )

    do {
      let output: Prompt
      if let timeout = configuration.executionTimeout {
        do {
          output = try await withFoundationModelsAgentTimeout(timeout) {
            try Task.checkCancellation()
            return try await base.call(arguments: arguments)
          }
        } catch is FoundationModelsAgentTimeoutMarker {
          throw FoundationModelsAgentError.toolExecutionTimedOut(toolName: name)
        }
      } else {
        try Task.checkCancellation()
        output = try await base.call(arguments: arguments)
      }
      let duration = started.duration(to: clock.now)
      await recorder.record(
        runID: runID,
        kind: .toolExecutionCompleted,
        message: "Native tool execution completed.",
        attributes: attributes.merging(["duration": String(describing: duration)]) { _, new in new }
      )
      return output
    } catch {
      let duration = started.duration(to: clock.now)
      await recorder.record(
        runID: runID,
        kind: .toolExecutionFailed,
        message: String(describing: error),
        attributes: attributes.merging(["duration": String(describing: duration)]) { _, new in new }
      )
      throw error
    }
  }
}

struct FoundationModelsAgentAnyTool: Sendable {
  let name: String
  let description: String
  let parameters: GenerationSchema
  private let callImplementation: @Sendable (GeneratedContent) async throws -> Prompt

  init<ToolType: Tool>(_ tool: ToolType) {
    self.name = tool.name
    self.description = tool.description
    self.parameters = tool.parameters
    self.callImplementation = { content in
      let arguments = try ToolType.Arguments(content)
      let output = try await tool.call(arguments: arguments)
      return Prompt(output)
    }
  }

  func call(arguments: GeneratedContent) async throws -> Prompt {
    try await callImplementation(arguments)
  }
}

struct FoundationModelsAgentTimeoutMarker: Error, Sendable {}

func withFoundationModelsAgentTimeout<Value: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw FoundationModelsAgentTimeoutMarker()
    }
    guard let result = try await group.next() else {
      throw FoundationModelsAgentTimeoutMarker()
    }
    group.cancelAll()
    return result
  }
}
