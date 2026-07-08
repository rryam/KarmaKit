import CryptoKit
import Foundation
import FoundationModels

/// A production harness around one persistent native `LanguageModelSession`.
///
/// CoreAgent deliberately accepts Foundation Models types directly. It does not
/// define another provider, message, tool, schema, or agent-loop abstraction.
public actor CoreAgentSession {
  typealias SessionFactory = (Transcript?) -> LanguageModelSession

  let makeSession: SessionFactory
  let configuration: CoreAgentConfiguration
  let checkpointStore: (any CoreAgentCheckpointStore)?
  let checkpointKey: String
  let retention: CoreAgentTranscriptRetention
  let requiresMatchingCheckpointConfiguration: Bool
  let checkpointCompatibilityRevision: String
  let recordsProfileToolLifecycle: Bool
  let sessionMode: CoreAgentSessionMode
  let plugins: [any CoreAgentSessionPlugin]
  let runLifecycleTools: [any CoreAgentRunLifecycleTool]
  let runObservers: [any CoreAgentRunObserver]
  let toolRuntime: CoreAgentToolRuntime
  let recorder: CoreAgentEventRecorder
  let scriptedModelResponder: (any CoreAgentScriptedModelResponding)?
  let scriptedToolsByName: [String: any Tool]
  let scriptedSuppressProfileToolOutputAudit: Bool

  var nativeSession: LanguageModelSession?
  var mostRecentRun: CoreAgentRun?
  var hasActiveOperation = false

  public init<Model: LanguageModel>(
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: CoreAgentInstructionRestorationPolicy = .replaceWithCurrent,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default
  ) throws {
    try self.init(
      model: model,
      tools: tools,
      instructions: instructions,
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingToolset: requiresMatchingToolset,
      instructionRestorationPolicy: instructionRestorationPolicy,
      plugins: plugins,
      redactionPolicy: redactionPolicy,
      observers: observers,
      observerDeliveryConfiguration: observerDeliveryConfiguration,
      scriptedModelResponder: nil
    )
  }

  package init<Model: LanguageModel>(
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: CoreAgentInstructionRestorationPolicy = .replaceWithCurrent,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    scriptedModelResponder: (any CoreAgentScriptedModelResponding)?
  ) throws {
    if scriptedModelResponder == nil,
      let harness = model as? any CoreAgentScriptedLanguageModelHarness
    {
      try self.init(
        model: model,
        tools: tools,
        instructions: instructions,
        configuration: configuration,
        toolConfiguration: toolConfiguration,
        checkpointStore: checkpointStore,
        checkpointKey: checkpointKey,
        transcriptRetention: transcriptRetention,
        requiresMatchingToolset: requiresMatchingToolset,
        instructionRestorationPolicy: instructionRestorationPolicy,
        plugins: plugins,
        redactionPolicy: redactionPolicy,
        observers: observers,
        observerDeliveryConfiguration: observerDeliveryConfiguration,
        scriptedModelResponder: harness.scriptedRecorder
      )
      return
    }
    try Self.validate(
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: toolConfiguration.maximumCallsPerRun)
    let allTools = tools + plugins.flatMap(\.tools)
    let runLifecycleTools = allTools.compactMap { $0 as? any CoreAgentRunLifecycleTool }
    let runObservers =
      plugins.compactMap { $0 as? any CoreAgentRunObserver }
      + allTools.compactMap { $0 as? any CoreAgentRunObserver }
    try Self.validateUniqueToolNames(allTools)
    let prepared = try allTools.map { tool -> (any Tool, CoreAgentToolManifest) in
      let manifest = try CoreAgentToolManifest(tool: tool)
      let erased = CoreAgentAnyTool(tool)
      let governed = CoreAgentGovernedTool(
        base: erased,
        manifest: manifest,
        configuration: toolConfiguration,
        runtime: runtime,
        recorder: recorder
      )
      return (governed, manifest)
    }
    let governedTools = prepared.map(\.0)
    let revision = Self.makeToolsetRevision(prepared.map(\.1))

    let makeSession: SessionFactory = { transcript in
      if let transcript {
        if case .replaceWithCurrent = instructionRestorationPolicy,
          instructions != nil
        {
          let current = LanguageModelSession(
            model: model,
            tools: governedTools,
            instructions: instructions
          )
          var rebased = current.transcript
          rebased.history = transcript.history
          return LanguageModelSession(model: model, tools: governedTools, transcript: rebased)
        }
        return LanguageModelSession(model: model, tools: governedTools, transcript: transcript)
      }
      return LanguageModelSession(model: model, tools: governedTools, instructions: instructions)
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: requiresMatchingToolset,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: false,
      sessionMode: .explicitModel,
      plugins: plugins,
      runLifecycleTools: runLifecycleTools,
      runObservers: runObservers,
      toolRuntime: runtime,
      recorder: recorder,
      scriptedModelResponder: scriptedModelResponder,
      scriptedToolsByName: Dictionary(uniqueKeysWithValues: governedTools.map { ($0.name, $0) })
    )
  }

  /// Creates a harness around a native Xcode 27 dynamic profile.
  ///
  /// The factory is called again for lazy checkpoint restoration and `reset()`.
  /// Profile-owned tools remain native and are not wrapped by CoreAgent policy.
  public init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    configuration: CoreAgentConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    profile makeProfile: @escaping @Sendable () -> sending Profile
  ) throws {
    try self.init(
      checkpointCompatibilityID: checkpointCompatibilityID,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      plugins: plugins,
      redactionPolicy: redactionPolicy,
      observers: observers,
      observerDeliveryConfiguration: observerDeliveryConfiguration,
      scriptedModelResponder: nil,
      profile: makeProfile
    )
  }

  package init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    configuration: CoreAgentConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    scriptedModelResponder: (any CoreAgentScriptedModelResponding)?,
    scriptedToolsByName: [String: any Tool] = [:],
    scriptedSuppressProfileToolOutputAudit: Bool = false,
    profile makeProfile: @escaping @Sendable () -> sending Profile
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: .default,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)
    guard !checkpointCompatibilityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentError.emptyCheckpointCompatibilityID
    }
    if configuration.retryPolicy.maximumAttempts > 1 {
      throw CoreAgentError.unsafeRetryConfiguration(
        "Dynamic profiles may preserve partial history or own tools and lifecycle hooks that CoreAgent cannot intercept. Profile mode supports one attempt."
      )
    }

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: nil)
    let runLifecycleTools = plugins.flatMap(\.tools).compactMap {
      $0 as? any CoreAgentRunLifecycleTool
    }
    let runObservers =
      plugins.compactMap { $0 as? any CoreAgentRunObserver }
      + plugins.flatMap(\.tools).compactMap { $0 as? any CoreAgentRunObserver }
    let revision = Self.makeProfileRevision(checkpointCompatibilityID)
    let makeSession: SessionFactory = { transcript in
      let profile = makeProfile()
        .onToolCall { call in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolCallRecorded,
            message: "Native dynamic profile emitted a tool call.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
        .onToolOutput { call, _ in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolOutputRecorded,
            message: "Native dynamic profile emitted tool output.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
      return LanguageModelSession(
        profile: profile,
        history: transcript?.history ?? []
      )
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: true,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: true,
      sessionMode: .dynamicProfile,
      plugins: plugins,
      runLifecycleTools: runLifecycleTools,
      runObservers: runObservers,
      toolRuntime: runtime,
      recorder: recorder,
      scriptedModelResponder: scriptedModelResponder,
      scriptedToolsByName: scriptedToolsByName,
      scriptedSuppressProfileToolOutputAudit: scriptedSuppressProfileToolOutputAudit
    )
  }

  init(
    makeSession: @escaping SessionFactory,
    configuration: CoreAgentConfiguration,
    checkpointStore: (any CoreAgentCheckpointStore)?,
    checkpointKey: String,
    transcriptRetention: CoreAgentTranscriptRetention,
    requiresMatchingCheckpointConfiguration: Bool,
    checkpointCompatibilityRevision: String,
    recordsProfileToolLifecycle: Bool,
    sessionMode: CoreAgentSessionMode,
    plugins: [any CoreAgentSessionPlugin],
    runLifecycleTools: [any CoreAgentRunLifecycleTool],
    runObservers: [any CoreAgentRunObserver],
    toolRuntime: CoreAgentToolRuntime,
    recorder: CoreAgentEventRecorder,
    scriptedModelResponder: (any CoreAgentScriptedModelResponding)? = nil,
    scriptedToolsByName: [String: any Tool] = [:],
    scriptedSuppressProfileToolOutputAudit: Bool = false
  ) {
    self.makeSession = makeSession
    self.configuration = configuration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.retention = transcriptRetention
    self.requiresMatchingCheckpointConfiguration = requiresMatchingCheckpointConfiguration
    self.checkpointCompatibilityRevision = checkpointCompatibilityRevision
    self.recordsProfileToolLifecycle = recordsProfileToolLifecycle
    self.sessionMode = sessionMode
    self.plugins = plugins
    self.runLifecycleTools = runLifecycleTools
    self.runObservers = runObservers
    self.toolRuntime = toolRuntime
    self.recorder = recorder
    self.scriptedModelResponder = scriptedModelResponder
    self.scriptedToolsByName = scriptedToolsByName
    self.scriptedSuppressProfileToolOutputAudit = scriptedSuppressProfileToolOutputAudit
  }

  public func prewarm(promptPrefix: Prompt? = nil) async throws {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    session.prewarm(promptPrefix: promptPrefix)
  }

  public func transcript() async throws -> Transcript {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    return try await resolveSession().transcript
  }

  public func lastRun() -> CoreAgentRun? {
    mostRecentRun
  }

  /// Waits up to `timeout` for previously emitted events to reach observers.
  /// Reports timeouts, reentrant calls, and any cumulative queue overflow.
  @discardableResult
  public func flushObservers(timeout: Duration? = nil) async -> CoreAgentObserverFlushResult {
    await recorder.flushObservers(timeout: timeout)
  }

  @discardableResult
  public func checkpoint() async throws -> CoreAgentCheckpoint {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    let persisted = try await persist(transcript: session.transcript, runID: nil)
    _ = installActiveSessionTranscriptIfNeeded(from: persisted)
    return persisted.checkpoint
  }

  public func reset(removingCheckpoint: Bool = false) async throws {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    nativeSession = makeSession(nil)
    nativeSession?.transcriptErrorHandlingPolicy =
      configuration.transcriptErrorHandlingPolicy.nativeValue
    mostRecentRun = nil
    if removingCheckpoint {
      if let checkpointStore {
        let checkpoint = try await checkpointStore.loadCheckpoint(for: checkpointKey)
        try await checkpointStore.removeCheckpoint(for: checkpointKey)
        guard let checkpoint else { return }
        try await retention.removeArtifacts(from: checkpoint)
      }
    }
  }

  @discardableResult
  public func respond(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<String> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond(
    to prompt: String,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<String> {
    try await respond(
      to: Prompt(prompt),
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respond<Content: Generable & Sendable>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<Content> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond<Content: Generable & Sendable>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<Content> {
    try await respond(
      to: Prompt(prompt),
      generating: type,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respond(
    to prompt: Prompt,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<GeneratedContent> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        schema: schema,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond(
    to prompt: String,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<GeneratedContent> {
    try await respond(
      to: Prompt(prompt),
      schema: schema,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respondStreaming(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> CoreAgentResponse<String> {
    try await performStream(
      prompt: prompt,
      contextQuery: contextQuery,
      metadata: metadata
    ) { session, preparedPrompt in
      session.streamResponse(
        to: preparedPrompt,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    } onPartialResponse: { content, _ in
      await onPartialResponse(content)
    }
  }

  @discardableResult
  public func respondStreaming(
    to prompt: String,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> CoreAgentResponse<String> {
    try await respondStreaming(
      to: Prompt(prompt),
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt,
      onPartialResponse: onPartialResponse
    )
  }

  @discardableResult
  public func respondStreaming<Content: Generable & Sendable>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try await performStream(
      prompt: prompt,
      contextQuery: contextQuery,
      metadata: metadata
    ) { session, preparedPrompt in
      session.streamResponse(
        to: preparedPrompt,
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    } onPartialResponse: { content, _ in
      await onPartialResponse(content)
    }
  }

  @discardableResult
  public func respondStreaming<Content: Generable & Sendable>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try await respondStreaming(
      to: Prompt(prompt),
      generating: type,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt,
      onPartialResponse: onPartialResponse
    )
  }
}
