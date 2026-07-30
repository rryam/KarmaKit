#if compiler(>=6.4)
  import Foundation
  import FoundationModels

  /// A deterministic authorization result for a profile-owned native tool call.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public enum DynamicProfileToolAuthorizationDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
  }

  /// The native tool call and the exact trusted manifest used to authorize it.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct DynamicProfileToolAuthorizationRequest: Sendable {
    public let nativeCallID: String
    public let manifest: FoundationModelsAgentToolManifest
    public let arguments: GeneratedContent
    public let canonicalArgumentsJSON: String
    public let metadata: FoundationModelsAgentRequestMetadata

    public init(
      nativeCallID: String,
      manifest: FoundationModelsAgentToolManifest,
      arguments: GeneratedContent,
      canonicalArgumentsJSON: String,
      metadata: FoundationModelsAgentRequestMetadata
    ) {
      self.nativeCallID = nativeCallID
      self.manifest = manifest
      self.arguments = arguments
      self.canonicalArgumentsJSON = canonicalArgumentsJSON
      self.metadata = metadata
    }
  }

  /// Makes the application-specific allow, deny, or approval decision for a profile tool.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public protocol DynamicProfileToolAuthorizer: Sendable {
    func decision(for request: DynamicProfileToolAuthorizationRequest) async throws
      -> DynamicProfileToolAuthorizationDecision
  }

  /// Adapts an async closure into a dynamic-profile tool authorizer.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct ClosureDynamicProfileToolAuthorizer: DynamicProfileToolAuthorizer {
    private let handler:
      @Sendable (DynamicProfileToolAuthorizationRequest) async throws ->
        DynamicProfileToolAuthorizationDecision

    public init(
      _ handler:
        @escaping @Sendable (DynamicProfileToolAuthorizationRequest) async throws ->
        DynamicProfileToolAuthorizationDecision
    ) {
      self.handler = handler
    }

    public func decision(for request: DynamicProfileToolAuthorizationRequest) async throws
      -> DynamicProfileToolAuthorizationDecision
    {
      try await handler(request)
    }
  }

  /// Allows every call that passes the registry, manifest, and budget gates.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct AllowRegisteredDynamicProfileTools: DynamicProfileToolAuthorizer {
    public init() {}

    public func decision(for request: DynamicProfileToolAuthorizationRequest) async throws
      -> DynamicProfileToolAuthorizationDecision
    {
      .allow
    }
  }

  /// The explicit manifest registry for tools owned by a native dynamic profile.
  ///
  /// The registry is a caller-maintained description of the profile's opaque tools. Construct it
  /// from the same tool values used by the profile and update it whenever a tool contract changes.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct DynamicProfileToolRegistry: Sendable {
    private let manifestsByName: [String: FoundationModelsAgentToolManifest]

    public init(manifests: [FoundationModelsAgentToolManifest]) throws {
      var values: [String: FoundationModelsAgentToolManifest] = [:]
      for manifest in manifests {
        guard values.updateValue(manifest, forKey: manifest.name) == nil else {
          throw FoundationModelsAgentError.duplicateToolName(manifest.name)
        }
      }
      self.manifestsByName = values
    }

    public init(tools: [any Tool]) throws {
      try self.init(manifests: tools.map { try FoundationModelsAgentToolManifest(tool: $0) })
    }

    public var manifests: [FoundationModelsAgentToolManifest] {
      manifestsByName.values.sorted { $0.name < $1.name }
    }

    public func manifest(named name: String) -> FoundationModelsAgentToolManifest? {
      manifestsByName[name]
    }
  }

  /// Fail-closed errors emitted before a profile-owned tool implementation can run.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public enum DynamicProfileToolGovernanceError: Error, LocalizedError, Sendable, Equatable {
    case unknownTool(toolName: String)
    case untrustedManifest(toolName: String, digest: String)
    case denied(toolName: String, reason: String)
    case totalBudgetExhausted(maximum: Int)
    case toolBudgetExhausted(toolName: String, maximum: Int)

    public var errorDescription: String? {
      switch self {
      case .unknownTool(let toolName):
        "Profile tool '\(toolName)' is absent from the explicit governance registry."
      case .untrustedManifest(let toolName, let digest):
        "Profile tool '\(toolName)' has an untrusted manifest digest: \(digest)"
      case .denied(let toolName, let reason):
        "Profile tool '\(toolName)' was denied: \(reason)"
      case .totalBudgetExhausted(let maximum):
        "The dynamic-profile run exhausted its total budget of \(maximum) tool calls."
      case .toolBudgetExhausted(let toolName, let maximum):
        "Profile tool '\(toolName)' exhausted its per-run budget of \(maximum) calls."
      }
    }
  }

  /// Governance applied by `AgentSession` to tools owned by a native dynamic profile.
  ///
  /// Registry lookup, exact manifest trust, total/per-tool budgets, and authorization all run in
  /// Xcode 27's pre-execution `onToolCall` hook. Unknown tools and changed manifests fail closed.
  /// This hook does not wrap opaque execution, so it cannot enforce execution timeouts, inspect or
  /// filter tool output, or undo side effects after a tool returns.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct DynamicProfileToolGovernanceConfiguration: Sendable {
    public let registry: DynamicProfileToolRegistry
    public let trustedManifestDigests: Set<String>
    public let authorizer: any DynamicProfileToolAuthorizer
    public let maximumCallsPerRun: Int?
    public let maximumCallsPerToolPerRun: [String: Int]

    public init(
      registry: DynamicProfileToolRegistry,
      trustedManifestDigests: Set<String>,
      authorizer: any DynamicProfileToolAuthorizer = AllowRegisteredDynamicProfileTools(),
      maximumCallsPerRun: Int? = nil,
      maximumCallsPerToolPerRun: [String: Int] = [:]
    ) throws {
      if let maximumCallsPerRun, maximumCallsPerRun < 0 {
        throw FoundationModelsAgentError.invalidToolCallLimit(maximumCallsPerRun)
      }
      for (toolName, limit) in maximumCallsPerToolPerRun where limit < 0 {
        throw FoundationModelsAgentError.invalidPerToolCallLimit(
          toolName: toolName,
          limit: limit
        )
      }
      self.registry = registry
      self.trustedManifestDigests = trustedManifestDigests
      self.authorizer = authorizer
      self.maximumCallsPerRun = maximumCallsPerRun
      self.maximumCallsPerToolPerRun = maximumCallsPerToolPerRun
    }

    /// Pins the current registry exactly. Rebuild this configuration after intentional tool changes.
    public init(
      trusting registry: DynamicProfileToolRegistry,
      authorizer: any DynamicProfileToolAuthorizer = AllowRegisteredDynamicProfileTools(),
      maximumCallsPerRun: Int? = nil,
      maximumCallsPerToolPerRun: [String: Int] = [:]
    ) throws {
      try self.init(
        registry: registry,
        trustedManifestDigests: Set(registry.manifests.map(\.digest)),
        authorizer: authorizer,
        maximumCallsPerRun: maximumCallsPerRun,
        maximumCallsPerToolPerRun: maximumCallsPerToolPerRun
      )
    }
  }

  /// A reusable native profile modifier implementing `DynamicProfileToolGovernanceConfiguration`.
  ///
  /// `AgentSession` installs this modifier and supplies its run lifecycle and event recorder. When
  /// composing profiles manually, use the `AgentSession` dynamic-profile initializer so budgets
  /// reset at each response run and governance outcomes join the audited run.
  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  public struct DynamicProfileToolGovernanceModifier:
    LanguageModelSession.DynamicProfileModifier, Sendable
  {
    let runtime: DynamicProfileToolGovernanceRuntime

    public init(configuration: DynamicProfileToolGovernanceConfiguration) {
      self.runtime = DynamicProfileToolGovernanceRuntime(configuration: configuration)
    }

    public func body(content: Content) -> some LanguageModelSession.DynamicProfile {
      content.onToolCall { call in
        try await runtime.authorize(call)
      }
    }
  }

  @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
  @available(tvOS, unavailable)
  actor DynamicProfileToolGovernanceRuntime {
    private let configuration: DynamicProfileToolGovernanceConfiguration
    private var activeRunID: UUID?
    private var recorder: FoundationModelsAgentEventRecorder?
    private var totalCallCount = 0
    private var perToolCallCount: [String: Int] = [:]

    init(configuration: DynamicProfileToolGovernanceConfiguration) {
      self.configuration = configuration
    }

    func begin(runID: UUID, recorder: FoundationModelsAgentEventRecorder) {
      activeRunID = runID
      self.recorder = recorder
      totalCallCount = 0
      perToolCallCount = [:]
    }

    func finish(runID: UUID) {
      guard activeRunID == runID else { return }
      activeRunID = nil
      recorder = nil
      totalCallCount = 0
      perToolCallCount = [:]
    }

    func authorize(_ call: Transcript.ToolCall) async throws {
      guard let manifest = configuration.registry.manifest(named: call.toolName) else {
        let error = DynamicProfileToolGovernanceError.unknownTool(toolName: call.toolName)
        await record(call: call, kind: .profileToolDenied, error: error)
        throw error
      }
      guard configuration.trustedManifestDigests.contains(manifest.digest) else {
        let error = DynamicProfileToolGovernanceError.untrustedManifest(
          toolName: call.toolName,
          digest: manifest.digest
        )
        await record(call: call, manifest: manifest, kind: .profileToolDenied, error: error)
        throw error
      }

      if let maximum = configuration.maximumCallsPerRun, totalCallCount >= maximum {
        let error = DynamicProfileToolGovernanceError.totalBudgetExhausted(maximum: maximum)
        await record(
          call: call,
          manifest: manifest,
          kind: .profileToolBudgetExhausted,
          error: error
        )
        throw error
      }
      let toolCallCount = perToolCallCount[call.toolName, default: 0]
      if let maximum = configuration.maximumCallsPerToolPerRun[call.toolName],
        toolCallCount >= maximum
      {
        let error = DynamicProfileToolGovernanceError.toolBudgetExhausted(
          toolName: call.toolName,
          maximum: maximum
        )
        await record(
          call: call,
          manifest: manifest,
          kind: .profileToolBudgetExhausted,
          error: error
        )
        throw error
      }

      totalCallCount += 1
      perToolCallCount[call.toolName] = toolCallCount + 1
      let request = DynamicProfileToolAuthorizationRequest(
        nativeCallID: call.id,
        manifest: manifest,
        arguments: call.arguments,
        canonicalArgumentsJSON: Self.canonicalJSON(call.arguments.jsonString),
        metadata: call.metadata
      )

      let decision: DynamicProfileToolAuthorizationDecision
      do {
        decision = try await configuration.authorizer.decision(for: request)
        try Task.checkCancellation()
      } catch is CancellationError {
        await record(
          call: call,
          manifest: manifest,
          kind: .profileToolApprovalFailed,
          message: "Dynamic-profile tool approval was cancelled.",
          error: CancellationError()
        )
        throw CancellationError()
      } catch {
        await record(
          call: call,
          manifest: manifest,
          kind: .profileToolApprovalFailed,
          error: error
        )
        throw error
      }

      switch decision {
      case .allow:
        await record(call: call, manifest: manifest, kind: .profileToolAllowed)
      case .deny(let reason):
        let error = DynamicProfileToolGovernanceError.denied(
          toolName: call.toolName,
          reason: reason
        )
        await record(call: call, manifest: manifest, kind: .profileToolDenied, error: error)
        throw error
      }
    }

    private func record(
      call: Transcript.ToolCall,
      manifest: FoundationModelsAgentToolManifest? = nil,
      kind: FoundationModelsAgentEventKind,
      message: String? = nil,
      error: (any Error)? = nil
    ) async {
      guard let activeRunID, let recorder else { return }
      var attributes = [
        "native_call_id": call.id,
        "tool": call.toolName,
      ]
      if let manifest {
        attributes["manifest_digest"] = manifest.digest
      }
      if let error {
        attributes["error_type"] = String(reflecting: Swift.type(of: error))
      }
      await recorder.record(
        runID: activeRunID,
        kind: kind,
        message: message ?? error.map(String.init(describing:)) ?? "Profile tool call allowed.",
        attributes: attributes
      )
    }

    private static func canonicalJSON(_ json: String) -> String {
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let canonical = try? JSONSerialization.data(
          withJSONObject: object,
          options: [.sortedKeys, .withoutEscapingSlashes]
        )
      else {
        return json
      }
      return String(decoding: canonical, as: UTF8.self)
    }
  }
#endif
