import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

public protocol CoreAgentDeepHITLExecutableActionBackend: Sendable {
  func execute(
    _ request: CoreAgentToolRequest,
    action: CoreAgentDeepHITLExecutableAction
  ) async throws -> Prompt
}

public struct ClosureCoreAgentDeepHITLExecutableActionBackend:
  CoreAgentDeepHITLExecutableActionBackend
{
  private let handler:
    @Sendable (CoreAgentToolRequest, CoreAgentDeepHITLExecutableAction) async throws -> Prompt

  public init(
    _ handler:
      @escaping @Sendable (
        CoreAgentToolRequest,
        CoreAgentDeepHITLExecutableAction
      ) async throws -> Prompt
  ) {
    self.handler = handler
  }

  public func execute(
    _ request: CoreAgentToolRequest,
    action: CoreAgentDeepHITLExecutableAction
  ) async throws -> Prompt {
    try await handler(request, action)
  }
}

public struct CoreAgentDeepHITLExecutedAction: Sendable {
  public let output: Prompt
  public let request: CoreAgentToolRequest
  public let manifest: CoreAgentToolManifest
  public let graphToolCallID: String
  public let requestedName: String
  public let executableName: String
  public let source: CoreAgentDeepHITLExecutionSource
  public let requestedArgumentsDigest: String
  public let executableArgumentsDigest: String
  public let requestedArgumentsRedactedJSON: String
  public let executableArgumentsRedactedJSON: String
  public let reviewedActionIdentity: CoreAgentDeepHITLActionIdentity?
  public let editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization?

  public init(
    output: Prompt,
    request: CoreAgentToolRequest,
    manifest: CoreAgentToolManifest,
    graphToolCallID: String,
    requestedName: String,
    executableName: String,
    source: CoreAgentDeepHITLExecutionSource,
    requestedArgumentsDigest: String,
    executableArgumentsDigest: String,
    requestedArgumentsRedactedJSON: String,
    executableArgumentsRedactedJSON: String,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity?,
    editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization?
  ) {
    self.output = output
    self.request = request
    self.manifest = manifest
    self.graphToolCallID = graphToolCallID
    self.requestedName = requestedName
    self.executableName = executableName
    self.source = source
    self.requestedArgumentsDigest = requestedArgumentsDigest
    self.executableArgumentsDigest = executableArgumentsDigest
    self.requestedArgumentsRedactedJSON = requestedArgumentsRedactedJSON
    self.executableArgumentsRedactedJSON = executableArgumentsRedactedJSON
    self.reviewedActionIdentity = reviewedActionIdentity
    self.editedTargetAuthorization = editedTargetAuthorization
  }
}

public struct CoreAgentDeepHITLExecutableActionExecutor: Sendable {
  private let manifestsByName: [String: CoreAgentToolManifest]
  private let policy: any CoreAgentToolPolicy
  private let backend: any CoreAgentDeepHITLExecutableActionBackend

  public init(
    manifests: [CoreAgentToolManifest],
    policy: any CoreAgentToolPolicy = AllowAllCoreAgentToolPolicy(),
    backend: any CoreAgentDeepHITLExecutableActionBackend
  ) throws {
    var manifestsByName: [String: CoreAgentToolManifest] = [:]
    for manifest in manifests {
      guard manifestsByName[manifest.name] == nil else {
        throw CoreAgentDeepHITLError.duplicateExecutableManifest(toolName: manifest.name)
      }
      manifestsByName[manifest.name] = manifest
    }
    self.manifestsByName = manifestsByName
    self.policy = policy
    self.backend = backend
  }

  public func execute(
    _ action: CoreAgentDeepHITLExecutableAction,
    runID: UUID
  ) async throws -> CoreAgentDeepHITLExecutedAction {
    guard let manifest = manifestsByName[action.executableName] else {
      throw CoreAgentDeepHITLError.missingExecutableManifest(toolName: action.executableName)
    }
    let requestedArguments: GeneratedContent
    do {
      requestedArguments = try GeneratedContent(json: action.requestedArgsJSON)
    } catch {
      throw CoreAgentDeepHITLError.invalidRequestedArguments(toolName: action.requestedName)
    }
    let arguments: GeneratedContent
    do {
      arguments = try GeneratedContent(json: action.executableArgsJSON)
    } catch {
      throw CoreAgentDeepHITLError.invalidExecutableArguments(toolName: action.executableName)
    }
    let requestedArgumentsDigest = CoreAgentArgumentAudit.digest(requestedArguments)
    let executableArgumentsDigest = CoreAgentArgumentAudit.digest(arguments)
    let request = CoreAgentToolRequest(
      runID: runID,
      invocationID: Self.invocationID(
        runID: runID,
        action: action,
        manifest: manifest,
        executableArgumentsDigest: executableArgumentsDigest
      ),
      manifest: manifest,
      arguments: arguments
    )
    try await policy.authorize(request)
    let context = CoreAgentToolInvocationContext(
      runID: runID,
      invocationID: request.invocationID,
      toolName: manifest.name,
      manifestDigest: manifest.digest
    )
    let output = try await CoreAgentToolInvocation.withCurrent(context) {
      try await backend.execute(request, action: action)
    }
    return CoreAgentDeepHITLExecutedAction(
      output: output,
      request: request,
      manifest: manifest,
      graphToolCallID: action.toolCallID,
      requestedName: action.requestedName,
      executableName: action.executableName,
      source: action.source,
      requestedArgumentsDigest: requestedArgumentsDigest,
      executableArgumentsDigest: executableArgumentsDigest,
      requestedArgumentsRedactedJSON: CoreAgentArgumentAudit.redactedJSONString(requestedArguments),
      executableArgumentsRedactedJSON: CoreAgentArgumentAudit.redactedJSONString(arguments),
      reviewedActionIdentity: action.reviewedActionIdentity,
      editedTargetAuthorization: action.editedTargetAuthorization
    )
  }

  private static func invocationID(
    runID: UUID,
    action: CoreAgentDeepHITLExecutableAction,
    manifest: CoreAgentToolManifest,
    executableArgumentsDigest: String
  ) -> UUID {
    let digest = SHA256.hash(
      data: Data(
        [
          "coreagent-deep-hitl-executable-action-v2",
          runID.uuidString.lowercased(),
          action.toolCallID,
          action.executableName,
          manifest.digest,
          executableArgumentsDigest,
        ].joined(separator: "\u{0}").utf8
      )
    )
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

}
