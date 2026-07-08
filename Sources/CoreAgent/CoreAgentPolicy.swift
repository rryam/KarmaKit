import CryptoKit
import Foundation
import FoundationModels

public enum CoreAgentPolicyError: Error, LocalizedError, Sendable {
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

public struct CoreAgentToolManifest: Codable, Equatable, Hashable, Sendable {
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

public struct CoreAgentToolRequest: Sendable {
  public let runID: UUID
  public let invocationID: UUID
  public let manifest: CoreAgentToolManifest
  public let arguments: GeneratedContent

  public init(
    runID: UUID,
    invocationID: UUID,
    manifest: CoreAgentToolManifest,
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

public protocol CoreAgentToolPolicy: Sendable {
  func authorize(_ request: CoreAgentToolRequest) async throws
}

public enum CoreAgentToolInterventionDecision: Sendable {
  case approve
  case edit(arguments: GeneratedContent)
  case reject(Prompt)
  case respond(Prompt)
}

public protocol CoreAgentToolInterventionPolicy: Sendable {
  func shouldIntervene(_ request: CoreAgentToolRequest) async throws -> Bool
  func decide(_ request: CoreAgentToolRequest) async throws -> CoreAgentToolInterventionDecision
}

public protocol CoreAgentRunLifecycleTool: Sendable {
  func coreAgentRunDidFinish(_ runID: UUID) async
}

extension CoreAgentToolInterventionPolicy {
  public func shouldIntervene(_ request: CoreAgentToolRequest) async throws -> Bool {
    true
  }
}

public struct AllowAllCoreAgentToolPolicy: CoreAgentToolPolicy {
  public init() {}
  public func authorize(_ request: CoreAgentToolRequest) async throws {}
}

public struct CompositeCoreAgentToolPolicy: CoreAgentToolPolicy {
  private let policies: [any CoreAgentToolPolicy]

  public init(_ policies: [any CoreAgentToolPolicy]) {
    self.policies = policies
  }

  public func authorize(_ request: CoreAgentToolRequest) async throws {
    for policy in policies {
      try await policy.authorize(request)
    }
  }
}

public struct ToolNameAllowlistPolicy: CoreAgentToolPolicy {
  private let allowedNames: Set<String>

  public init(_ allowedNames: Set<String>) {
    self.allowedNames = allowedNames
  }

  public func authorize(_ request: CoreAgentToolRequest) async throws {
    guard allowedNames.contains(request.manifest.name) else {
      throw CoreAgentPolicyError.denied(
        toolName: request.manifest.name,
        reason: "The tool is not in the configured allowlist."
      )
    }
  }
}

public struct TrustedToolManifestPolicy: CoreAgentToolPolicy {
  private let approvedDigests: Set<String>

  public init(approvedDigests: Set<String>) {
    self.approvedDigests = approvedDigests
  }

  public init(approvedManifests: [CoreAgentToolManifest]) {
    self.approvedDigests = Set(approvedManifests.map(\.digest))
  }

  public func authorize(_ request: CoreAgentToolRequest) async throws {
    guard approvedDigests.contains(request.manifest.digest) else {
      throw CoreAgentPolicyError.untrustedManifest(
        toolName: request.manifest.name,
        digest: request.manifest.digest
      )
    }
  }
}

public enum CoreAgentApprovalDecision: Equatable, Sendable {
  case approve
  case deny(reason: String)
}

public protocol CoreAgentApprovalProvider: Sendable {
  func decision(for request: CoreAgentToolRequest) async throws -> CoreAgentApprovalDecision
}

public struct ClosureCoreAgentApprovalProvider: CoreAgentApprovalProvider {
  private let handler: @Sendable (CoreAgentToolRequest) async throws -> CoreAgentApprovalDecision

  public init(
    _ handler: @escaping @Sendable (CoreAgentToolRequest) async throws -> CoreAgentApprovalDecision
  ) {
    self.handler = handler
  }

  public func decision(for request: CoreAgentToolRequest) async throws -> CoreAgentApprovalDecision
  {
    try await handler(request)
  }
}

public struct ApprovalRequiredToolPolicy: CoreAgentToolPolicy {
  private let requiredNames: Set<String>?
  private let provider: any CoreAgentApprovalProvider

  public init(
    requiredNames: Set<String>? = nil,
    provider: any CoreAgentApprovalProvider
  ) {
    self.requiredNames = requiredNames
    self.provider = provider
  }

  public func authorize(_ request: CoreAgentToolRequest) async throws {
    if let requiredNames, !requiredNames.contains(request.manifest.name) {
      return
    }
    switch try await provider.decision(for: request) {
    case .approve:
      return
    case .deny(let reason):
      throw CoreAgentPolicyError.denied(toolName: request.manifest.name, reason: reason)
    }
  }
}

public struct DenyAllCoreAgentToolPolicy: CoreAgentToolPolicy {
  private let reason: String

  public init(reason: String = "No tool authority has been delegated.") {
    self.reason = reason
  }

  public func authorize(_ request: CoreAgentToolRequest) async throws {
    throw CoreAgentPolicyError.denied(toolName: request.manifest.name, reason: reason)
  }
}

public struct CoreAgentToolConfiguration: Sendable {
  public var policy: any CoreAgentToolPolicy
  public var interventionPolicy: (any CoreAgentToolInterventionPolicy)?
  public var executionTimeout: Duration?
  public var maximumCallsPerRun: Int?

  public init(
    policy: any CoreAgentToolPolicy = AllowAllCoreAgentToolPolicy(),
    interventionPolicy: (any CoreAgentToolInterventionPolicy)? = nil,
    executionTimeout: Duration? = nil,
    maximumCallsPerRun: Int? = nil
  ) {
    self.policy = policy
    self.interventionPolicy = interventionPolicy
    self.executionTimeout = executionTimeout
    self.maximumCallsPerRun = maximumCallsPerRun
  }

  public static let `default` = CoreAgentToolConfiguration()
  public static let denyAll = CoreAgentToolConfiguration(policy: DenyAllCoreAgentToolPolicy())
}

actor CoreAgentToolRuntime {
  struct ToolOutputProvenance: Sendable {
    let toolInvocationID: UUID
    let outputSource: String
    let argumentsSource: String
    let requestedArgumentsDigest: String
    let executedArgumentsDigest: String?
  }

  private var currentRunID: UUID?
  private var callCount = 0
  private var beganToolInvocation = false
  private var outputProvenanceByRun: [UUID: [String: [ToolOutputProvenance]]] = [:]
  private let maximumCallsPerRun: Int?

  init(maximumCallsPerRun: Int?) {
    self.maximumCallsPerRun = maximumCallsPerRun
  }

  func begin(runID: UUID) {
    currentRunID = runID
    callCount = 0
    beganToolInvocation = false
    outputProvenanceByRun[runID] = [:]
  }

  func finish(runID: UUID) {
    guard currentRunID == runID else { return }
    currentRunID = nil
    callCount = 0
    beganToolInvocation = false
    outputProvenanceByRun.removeValue(forKey: runID)
  }

  func reserveCall() throws -> UUID {
    guard let currentRunID else {
      throw CoreAgentError.noActiveRun
    }
    if let maximumCallsPerRun, callCount >= maximumCallsPerRun {
      throw CoreAgentError.toolCallBudgetExceeded(maximum: maximumCallsPerRun)
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

  func recordOutputProvenance(
    runID: UUID,
    toolName: String,
    provenance: ToolOutputProvenance
  ) {
    outputProvenanceByRun[runID, default: [:]][toolName, default: []].append(provenance)
  }

  func consumeOutputProvenance(
    runID: UUID,
    toolName: String
  ) -> ToolOutputProvenance? {
    guard var runValues = outputProvenanceByRun[runID],
      var toolValues = runValues[toolName],
      !toolValues.isEmpty
    else {
      return nil
    }
    let provenance = toolValues.removeFirst()
    runValues[toolName] = toolValues
    outputProvenanceByRun[runID] = runValues
    return provenance
  }
}

struct CoreAgentGovernedTool: Tool {
  typealias Arguments = GeneratedContent
  typealias Output = Prompt

  let base: CoreAgentAnyTool
  let manifest: CoreAgentToolManifest
  let configuration: CoreAgentToolConfiguration
  let runtime: CoreAgentToolRuntime
  let recorder: CoreAgentEventRecorder

  var name: String { base.name }
  var description: String { base.description }
  var parameters: GenerationSchema { base.parameters }
  var includesSchemaInInstructions: Bool { manifest.includesSchemaInInstructions }

  @concurrent
  func call(arguments: GeneratedContent) async throws -> Prompt {
    let runID = try await runtime.reserveCall()
    let invocationID = UUID()
    let request = CoreAgentToolRequest(
      runID: runID,
      invocationID: invocationID,
      manifest: manifest,
      arguments: arguments
    )
    let requestedArgumentsDigest = CoreAgentArgumentAudit.digest(arguments)
    let requestedArgumentsJSON = CoreAgentArgumentAudit.redactedJSONString(arguments)
    let attributes = [
      "tool": name,
      "invocation_id": invocationID.uuidString.lowercased(),
      "manifest_digest": manifest.digest,
      "requested_arguments_digest": requestedArgumentsDigest,
    ]

    var executableArguments = arguments
    var executableRequest = request
    var argumentsSource = "model_request"
    var executedArgumentsDigest = requestedArgumentsDigest
    var executionAttributes = attributes.merging([
      "arguments_source": argumentsSource,
      "executed_arguments_digest": executedArgumentsDigest,
    ]) { _, new in new }

    if let interventionPolicy = configuration.interventionPolicy {
      var interventionStarted = false
      do {
        let shouldIntervene = try await interventionPolicy.shouldIntervene(request)
        try Task.checkCancellation()
        if shouldIntervene {
          interventionStarted = true
          await recorder.record(
            runID: runID,
            kind: .toolInterventionStarted,
            message: "Reviewing native tool call before execution.",
            attributes: attributes
          )
          let decision = try await interventionPolicy.decide(request)
          try Task.checkCancellation()
          switch decision {
          case .approve:
            await recorder.record(
              runID: runID,
              kind: .toolInterventionApproved,
              message: "Native tool call was approved.",
              attributes: attributes
            )
          case .edit(let editedArguments):
            executableArguments = editedArguments
            argumentsSource = "intervention_edit"
            executedArgumentsDigest = CoreAgentArgumentAudit.digest(editedArguments)
            executableRequest = CoreAgentToolRequest(
              runID: runID,
              invocationID: invocationID,
              manifest: manifest,
              arguments: editedArguments
            )
            executionAttributes = attributes.merging([
              "arguments_source": argumentsSource,
              "original_arguments_digest": requestedArgumentsDigest,
              "edited_arguments_digest": executedArgumentsDigest,
              "executed_arguments_digest": executedArgumentsDigest,
              "requested_arguments_json": requestedArgumentsJSON,
              "executed_arguments_json": CoreAgentArgumentAudit.redactedJSONString(editedArguments),
            ]) { _, new in new }
            await recorder.record(
              runID: runID,
              kind: .toolInterventionEdited,
              message: "Native tool call arguments were edited before execution.",
              attributes: executionAttributes
            )
          case .reject(let output):
            await recorder.record(
              runID: runID,
              kind: .toolInterventionRejected,
              message: "Native tool call was rejected before execution.",
              attributes: attributes
            )
            await runtime.recordOutputProvenance(
              runID: runID,
              toolName: name,
              provenance: CoreAgentToolRuntime.ToolOutputProvenance(
                toolInvocationID: invocationID,
                outputSource: "intervention_reject",
                argumentsSource: "intervention_reject",
                requestedArgumentsDigest: requestedArgumentsDigest,
                executedArgumentsDigest: nil
              )
            )
            return output
          case .respond(let output):
            await recorder.record(
              runID: runID,
              kind: .toolInterventionResponded,
              message: "Native tool call was answered by human input before execution.",
              attributes: attributes
            )
            await runtime.recordOutputProvenance(
              runID: runID,
              toolName: name,
              provenance: CoreAgentToolRuntime.ToolOutputProvenance(
                toolInvocationID: invocationID,
                outputSource: "intervention_respond",
                argumentsSource: "intervention_respond",
                requestedArgumentsDigest: requestedArgumentsDigest,
                executedArgumentsDigest: nil
              )
            )
            return output
          }
        }
      } catch is CancellationError {
        if interventionStarted {
          await recorder.record(
            runID: runID,
            kind: .toolInterventionCancelled,
            message: "Native tool intervention was cancelled.",
            attributes: attributes
          )
        }
        throw CancellationError()
      } catch {
        if interventionStarted {
          await recorder.record(
            runID: runID,
            kind: .toolInterventionFailed,
            message: String(describing: error),
            attributes: attributes
          )
        }
        throw error
      }
    }

    await recorder.record(
      runID: runID,
      kind: .toolAuthorizationStarted,
      message: "Authorizing native tool call.",
      attributes: executionAttributes
    )
    do {
      try await configuration.policy.authorize(executableRequest)
      try Task.checkCancellation()
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationSucceeded,
        message: "Native tool call authorized.",
        attributes: executionAttributes
      )
    } catch is CancellationError {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationCancelled,
        message: "Native tool authorization was cancelled.",
        attributes: executionAttributes
      )
      throw CancellationError()
    } catch let error as CoreAgentPolicyError {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationDenied,
        message: String(describing: error),
        attributes: executionAttributes
      )
      throw error
    } catch {
      await recorder.record(
        runID: runID,
        kind: .toolAuthorizationFailed,
        message: String(describing: error),
        attributes: executionAttributes
      )
      throw error
    }

    let clock = ContinuousClock()
    let started = clock.now
    await recorder.record(
      runID: runID,
      kind: .toolExecutionStarted,
      message: "Native tool execution started.",
      attributes: executionAttributes
    )

    do {
      let output: Prompt
      let invocationContext = CoreAgentToolInvocationContext(
        runID: runID,
        invocationID: invocationID,
        toolName: name,
        manifestDigest: manifest.digest
      )
      let callArguments = executableArguments
      if let timeout = configuration.executionTimeout {
        do {
          output = try await withCoreAgentTimeout(timeout) {
            try Task.checkCancellation()
            return try await CoreAgentToolInvocation.withCurrent(invocationContext) {
              try await base.call(arguments: callArguments)
            }
          }
        } catch is CoreAgentTimeoutMarker {
          throw CoreAgentError.toolExecutionTimedOut(toolName: name)
        }
      } else {
        try Task.checkCancellation()
        output = try await CoreAgentToolInvocation.withCurrent(invocationContext) {
          try await base.call(arguments: callArguments)
        }
      }
      let duration = started.duration(to: clock.now)
      await recorder.record(
        runID: runID,
        kind: .toolExecutionCompleted,
        message: "Native tool execution completed.",
        attributes: executionAttributes.merging(["duration": String(describing: duration)]) {
          _, new in new
        }
      )
      await runtime.recordOutputProvenance(
        runID: runID,
        toolName: name,
        provenance: CoreAgentToolRuntime.ToolOutputProvenance(
          toolInvocationID: invocationID,
          outputSource: "tool_execution",
          argumentsSource: argumentsSource,
          requestedArgumentsDigest: requestedArgumentsDigest,
          executedArgumentsDigest: executedArgumentsDigest
        )
      )
      return output
    } catch {
      let duration = started.duration(to: clock.now)
      await recorder.record(
        runID: runID,
        kind: .toolExecutionFailed,
        message: String(describing: error),
        attributes: executionAttributes.merging(["duration": String(describing: duration)]) {
          _, new in new
        }
      )
      throw error
    }
  }

}

struct CoreAgentAnyTool: Sendable {
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

struct CoreAgentTimeoutMarker: Error, Sendable {}

func withCoreAgentTimeout<Value: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw CoreAgentTimeoutMarker()
    }
    guard let result = try await group.next() else {
      throw CoreAgentTimeoutMarker()
    }
    group.cancelAll()
    return result
  }
}
