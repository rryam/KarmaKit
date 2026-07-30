import CryptoKit
import Foundation
import FoundationModels

/// A production harness around one persistent native `LanguageModelSession`.
///
/// FoundationModelsAgent deliberately accepts Foundation Models types directly. It does not
/// define another provider, message, tool, schema, or agent-loop abstraction.
public actor AgentSession {
  private typealias SessionFactory = (Transcript?) -> LanguageModelSession

  private let makeSession: SessionFactory
  private let configuration: FoundationModelsAgentConfiguration
  private let checkpointStore: (any FoundationModelsAgentCheckpointStore)?
  private let checkpointKey: String
  private let retention: FoundationModelsAgentTranscriptRetention
  private let requiresMatchingCheckpointConfiguration: Bool
  private let checkpointCompatibilityRevision: String
  private let acceptedCheckpointCompatibilityRevisions: Set<String>
  private let recordsProfileToolLifecycle: Bool
  private let sessionMode: AgentSessionMode
  private let plugins: [any AgentSessionPlugin]
  private let toolRuntime: FoundationModelsAgentToolRuntime
  private let recorder: FoundationModelsAgentEventRecorder

  private var nativeSession: LanguageModelSession?
  private var mostRecentRun: FoundationModelsAgentRun?
  private var hasActiveOperation = false
  private var pendingCheckpointRestoreFound: Bool?

  public init<Model: LanguageModel>(
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: FoundationModelsAgentConfiguration = .default,
    toolConfiguration: FoundationModelsAgentToolConfiguration = .default,
    checkpointStore: (any FoundationModelsAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: FoundationModelsAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: FoundationModelsAgentInstructionRestorationPolicy =
      .replaceWithCurrent,
    plugins: [any AgentSessionPlugin] = [],
    redactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    observers: [any FoundationModelsAgentObserver] = [],
    observerDeliveryConfiguration: FoundationModelsAgentObserverDeliveryConfiguration = .default,
    instrumentation: AgentSessionInstrumentationConfiguration = .disabled
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)

    let recorder = FoundationModelsAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration,
      instrumentationConfiguration: instrumentation
    )
    let runtime = FoundationModelsAgentToolRuntime(
      maximumCallsPerRun: toolConfiguration.maximumCallsPerRun)
    let allTools = tools + plugins.flatMap(\.tools)
    try Self.validateUniqueToolNames(allTools)
    let prepared = try allTools.map { tool -> (any Tool, FoundationModelsAgentToolManifest) in
      let manifest = try FoundationModelsAgentToolManifest(tool: tool)
      let erased = FoundationModelsAgentAnyTool(tool)
      let governed = FoundationModelsAgentGovernedTool(
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
      acceptedCheckpointCompatibilityRevisions: [revision],
      recordsProfileToolLifecycle: false,
      sessionMode: .explicitModel,
      plugins: plugins,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  /// Creates a harness around a native Xcode 27 dynamic profile.
  ///
  /// The factory is called again for lazy checkpoint restoration and `reset()`.
  /// Profile-owned tools remain native and are not wrapped by FoundationModelsAgent policy.
  public init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    configuration: FoundationModelsAgentConfiguration = .default,
    checkpointStore: (any FoundationModelsAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: FoundationModelsAgentTranscriptRetention = .complete,
    plugins: [any AgentSessionPlugin] = [],
    redactionPolicy: FoundationModelsAgentRedactionPolicy = .standard,
    observers: [any FoundationModelsAgentObserver] = [],
    observerDeliveryConfiguration: FoundationModelsAgentObserverDeliveryConfiguration = .default,
    instrumentation: AgentSessionInstrumentationConfiguration = .disabled,
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
      throw FoundationModelsAgentError.emptyCheckpointCompatibilityID
    }
    if configuration.retryPolicy.maximumAttempts > 1 {
      throw FoundationModelsAgentError.unsafeRetryConfiguration(
        "Dynamic profiles may preserve partial history or own tools and lifecycle hooks that FoundationModelsAgent cannot intercept. Profile mode supports one attempt."
      )
    }

    let recorder = FoundationModelsAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration,
      instrumentationConfiguration: instrumentation
    )
    let runtime = FoundationModelsAgentToolRuntime(maximumCallsPerRun: nil)
    let revision = Self.makeProfileRevision(checkpointCompatibilityID)
    let previousRevision = Self.makePreviousProfileRevision(checkpointCompatibilityID)
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
              "profile_owned": "true",
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
              "profile_owned": "true",
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
      acceptedCheckpointCompatibilityRevisions: [revision, previousRevision],
      recordsProfileToolLifecycle: true,
      sessionMode: .dynamicProfile,
      plugins: plugins,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  private init(
    makeSession: @escaping SessionFactory,
    configuration: FoundationModelsAgentConfiguration,
    checkpointStore: (any FoundationModelsAgentCheckpointStore)?,
    checkpointKey: String,
    transcriptRetention: FoundationModelsAgentTranscriptRetention,
    requiresMatchingCheckpointConfiguration: Bool,
    checkpointCompatibilityRevision: String,
    acceptedCheckpointCompatibilityRevisions: Set<String>,
    recordsProfileToolLifecycle: Bool,
    sessionMode: AgentSessionMode,
    plugins: [any AgentSessionPlugin],
    toolRuntime: FoundationModelsAgentToolRuntime,
    recorder: FoundationModelsAgentEventRecorder
  ) {
    self.makeSession = makeSession
    self.configuration = configuration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.retention = transcriptRetention
    self.requiresMatchingCheckpointConfiguration = requiresMatchingCheckpointConfiguration
    self.checkpointCompatibilityRevision = checkpointCompatibilityRevision
    self.acceptedCheckpointCompatibilityRevisions = acceptedCheckpointCompatibilityRevisions
    self.recordsProfileToolLifecycle = recordsProfileToolLifecycle
    self.sessionMode = sessionMode
    self.plugins = plugins
    self.toolRuntime = toolRuntime
    self.recorder = recorder
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

  public func lastRun() -> FoundationModelsAgentRun? {
    mostRecentRun
  }

  /// Waits up to `timeout` for previously emitted events to reach observers.
  /// Reports timeouts, reentrant calls, and any cumulative queue overflow.
  @discardableResult
  public func flushObservers(timeout: Duration? = nil) async
    -> FoundationModelsAgentObserverFlushResult
  {
    await recorder.flushObservers(timeout: timeout)
  }

  @discardableResult
  public func checkpoint() async throws -> FoundationModelsAgentCheckpoint {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    return try await persist(transcript: session.transcript, runID: nil)
  }

  public func reset(removingCheckpoint: Bool = false) async throws {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    nativeSession = makeSession(nil)
    nativeSession?.transcriptErrorHandlingPolicy =
      configuration.transcriptErrorHandlingPolicy.nativeValue
    mostRecentRun = nil
    pendingCheckpointRestoreFound = nil
    if removingCheckpoint {
      try await checkpointStore?.removeCheckpoint(for: checkpointKey)
    }
  }

  @discardableResult
  public func respond(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<String> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<String> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<Content> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<Content> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<GeneratedContent> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> FoundationModelsAgentResponse<GeneratedContent> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> FoundationModelsAgentResponse<String> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> FoundationModelsAgentResponse<String> {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> FoundationModelsAgentResponse<Content>
  where Content.PartiallyGenerated: Sendable {
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
    metadata: FoundationModelsAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> FoundationModelsAgentResponse<Content>
  where Content.PartiallyGenerated: Sendable {
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

  private func resolveSession(runID: UUID? = nil) async throws -> LanguageModelSession {
    if let nativeSession {
      return nativeSession
    }

    if let runID, checkpointStore != nil {
      await recorder.record(
        runID: runID,
        kind: .checkpointRestoreStarted,
        message: "Native transcript checkpoint restore started."
      )
    }

    do {
      let checkpoint = try await checkpointStore?.loadCheckpoint(for: checkpointKey)
      let transcript: Transcript?
      if let checkpoint {
        guard checkpoint.formatVersion == FoundationModelsAgentCheckpoint.currentFormatVersion
        else {
          throw FoundationModelsAgentError.unsupportedCheckpointVersion(checkpoint.formatVersion)
        }
        if requiresMatchingCheckpointConfiguration,
          !acceptedCheckpointCompatibilityRevisions.contains(checkpoint.compatibilityRevision)
        {
          throw FoundationModelsAgentError.checkpointCompatibilityMismatch(
            expected: checkpointCompatibilityRevision,
            actual: checkpoint.compatibilityRevision
          )
        }
        transcript = checkpoint.transcript
      } else {
        transcript = nil
      }

      let session = makeSession(transcript)
      session.transcriptErrorHandlingPolicy =
        configuration.transcriptErrorHandlingPolicy.nativeValue
      nativeSession = session
      if let runID, checkpointStore != nil {
        await recorder.record(
          runID: runID,
          kind: .checkpointRestoreCompleted,
          message: "Native transcript checkpoint restore completed.",
          attributes: ["checkpoint_found": String(checkpoint != nil)]
        )
      } else if checkpointStore != nil {
        pendingCheckpointRestoreFound = checkpoint != nil
      }
      return session
    } catch {
      if let runID, checkpointStore != nil {
        await recorder.record(
          runID: runID,
          kind: .checkpointRestoreFailed,
          message: String(describing: error),
          attributes: ["error_type": String(reflecting: Swift.type(of: error))]
        )
      }
      throw error
    }
  }

  private func performResponse<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata,
    _ operation:
      @escaping @Sendable (LanguageModelSession, Prompt) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> FoundationModelsAgentResponse<Content> {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models run started.")
    await recordPendingCheckpointRestore(runID: runID)
    await toolRuntime.begin(runID: runID)
    let session: LanguageModelSession
    do {
      session = try await resolveSession(runID: runID)
    } catch {
      await recordRunFailure(error, runID: runID)
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
    let transcriptBeforeRun = session.transcript
    await recordProfileAuditBoundary(runID: runID)
    var completedModelResponse = false
    var pluginContext = PreparedPluginContext.empty

    do {
      pluginContext = try await preparePlugins(
        runID: runID,
        prompt: prompt,
        contextQuery: contextQuery,
        metadata: metadata
      )
      let preparedPrompt = makePrompt(prompt, contextBlocks: pluginContext.contextBlocks)
      let nativeResponse = try await responseWithRetry(
        session: session,
        runID: runID,
        operation: { try await operation($0, preparedPrompt) }
      )
      completedModelResponse = true
      let usage = FoundationModelsAgentUsage(nativeResponse.usage)
      let sanitizedTranscript = try await sanitizeCompletedTranscript(
        session.transcript,
        fallback: transcriptBeforeRun,
        context: pluginContext,
        runID: runID
      )
      let runTranscriptEntries = transcriptEntries(
        addedTo: sanitizedTranscript,
        after: transcriptBeforeRun
      )
      installSession(transcript: sanitizedTranscript, ifNeededFor: pluginContext)
      if !recordsProfileToolLifecycle {
        await recordNativeToolEntries(nativeResponse.transcriptEntries, runID: runID)
      }
      await recorder.record(
        runID: runID,
        kind: .modelResponseCompleted,
        message: "Native model response completed.",
        attributes: [
          "input_tokens": String(usage.inputTokens),
          "output_tokens": String(usage.outputTokens),
          "transcript_entries": String(nativeResponse.transcriptEntries.count),
        ]
      )
      try await persistAfterSuccessfulResponse(transcript: sanitizedTranscript, runID: runID)
      try await completePlugins(
        FoundationModelsAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: nativeResponse.rawContent,
          transcriptEntries: runTranscriptEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await toolRuntime.finish(runID: runID)
      return FoundationModelsAgentResponse(
        content: nativeResponse.content,
        rawContent: nativeResponse.rawContent,
        transcriptEntries: Array(nativeResponse.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        FoundationModelsAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await recordRunFailure(error, runID: runID)
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
  }

  private func responseWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    operation:
      @escaping @Sendable (LanguageModelSession) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> LanguageModelSession.Response<Content> {
    let retryPolicy = configuration.retryPolicy
    for attempt in 1...retryPolicy.maximumAttempts {
      await recorder.record(
        runID: runID,
        kind: .modelAttemptStarted,
        message: "Native model attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      do {
        guard let timeout = configuration.responseTimeout else {
          return try await operation(session)
        }
        do {
          let box = try await withFoundationModelsAgentTimeout(timeout) {
            NativeResponseBox(try await operation(session))
          }
          return box.response
        } catch is FoundationModelsAgentTimeoutMarker {
          throw FoundationModelsAgentError.responseTimedOut
        }
      } catch {
        await recorder.record(
          runID: runID,
          kind: .modelAttemptFailed,
          message: String(describing: error),
          attributes: [
            "attempt": String(attempt),
            "cancelled": String(Task.isCancelled || error is CancellationError),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        let startedToolInvocation = await toolRuntime.hasStartedToolInvocation(runID: runID)
        let mayRetryAfterTools =
          !startedToolInvocation || configuration.allowsRetryAfterToolInvocation
        guard attempt < retryPolicy.maximumAttempts,
          mayRetryAfterTools,
          retryPolicy.shouldRetry(error)
        else {
          throw error
        }
        await recorder.record(
          runID: runID,
          kind: .modelRetryScheduled,
          message: "Native model retry scheduled.",
          attributes: ["next_attempt": String(attempt + 1)]
        )
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }

  private func performStream<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata,
    _ makeStream:
      @escaping @Sendable (LanguageModelSession, Prompt) ->
      LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> FoundationModelsAgentResponse<Content>
  where Content.PartiallyGenerated: Sendable {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models streaming run started.")
    await recordPendingCheckpointRestore(runID: runID)
    await toolRuntime.begin(runID: runID)
    let session: LanguageModelSession
    do {
      session = try await resolveSession(runID: runID)
    } catch {
      await recordRunFailure(error, runID: runID)
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
    let transcriptBeforeRun = session.transcript
    await recordProfileAuditBoundary(runID: runID)

    var completedModelResponse = false
    var pluginContext = PreparedPluginContext.empty
    do {
      pluginContext = try await preparePlugins(
        runID: runID,
        prompt: prompt,
        contextQuery: contextQuery,
        metadata: metadata
      )
      let preparedPrompt = makePrompt(prompt, contextBlocks: pluginContext.contextBlocks)
      let lastSnapshot = try await streamWithRetry(
        session: session,
        runID: runID,
        makeStream: { makeStream($0, preparedPrompt) },
        onPartialResponse: onPartialResponse
      )
      completedModelResponse = true
      let content = try Content(lastSnapshot.rawContent)
      let usage = FoundationModelsAgentUsage(lastSnapshot.usage)
      let sanitizedTranscript = try await sanitizeCompletedTranscript(
        session.transcript,
        fallback: transcriptBeforeRun,
        context: pluginContext,
        runID: runID
      )
      let runTranscriptEntries = transcriptEntries(
        addedTo: sanitizedTranscript,
        after: transcriptBeforeRun
      )
      installSession(transcript: sanitizedTranscript, ifNeededFor: pluginContext)
      if !recordsProfileToolLifecycle {
        await recordNativeToolEntries(lastSnapshot.transcriptEntries, runID: runID)
      }
      await recorder.record(
        runID: runID,
        kind: .modelResponseCompleted,
        message: "Native model stream completed.",
        attributes: [
          "input_tokens": String(usage.inputTokens),
          "output_tokens": String(usage.outputTokens),
          "transcript_entries": String(lastSnapshot.transcriptEntries.count),
        ]
      )
      try await persistAfterSuccessfulResponse(transcript: sanitizedTranscript, runID: runID)
      try await completePlugins(
        FoundationModelsAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: lastSnapshot.rawContent,
          transcriptEntries: runTranscriptEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await toolRuntime.finish(runID: runID)
      return FoundationModelsAgentResponse(
        content: content,
        rawContent: lastSnapshot.rawContent,
        transcriptEntries: Array(lastSnapshot.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        FoundationModelsAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await recordRunFailure(error, runID: runID)
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
  }

  private func streamWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    makeStream:
      @escaping @Sendable (LanguageModelSession) -> LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> LanguageModelSession.ResponseStream<Content>.Snapshot
  where Content.PartiallyGenerated: Sendable {
    let retryPolicy = configuration.retryPolicy
    for attempt in 1...retryPolicy.maximumAttempts {
      await recorder.record(
        runID: runID,
        kind: .modelAttemptStarted,
        message: "Native model stream attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      let state = StreamAttemptState()
      do {
        let consume: @Sendable () async throws -> NativeStreamSnapshotBox<Content> = {
          let stream = makeStream(session)
          var lastSnapshot: LanguageModelSession.ResponseStream<Content>.Snapshot?
          for try await snapshot in stream {
            try Task.checkCancellation()
            await state.markSnapshotEmitted()
            lastSnapshot = snapshot
            await onPartialResponse(snapshot.content, snapshot.rawContent)
          }
          guard let lastSnapshot else {
            throw FoundationModelsAgentError.streamFinishedWithoutResponse
          }
          return NativeStreamSnapshotBox(lastSnapshot)
        }

        guard let timeout = configuration.responseTimeout else {
          return try await consume().snapshot
        }
        do {
          return try await withFoundationModelsAgentTimeout(timeout, operation: consume).snapshot
        } catch is FoundationModelsAgentTimeoutMarker {
          throw FoundationModelsAgentError.responseTimedOut
        }
      } catch {
        let emittedSnapshot = await state.emittedSnapshot
        let startedToolInvocation = await toolRuntime.hasStartedToolInvocation(runID: runID)
        await recorder.record(
          runID: runID,
          kind: .modelAttemptFailed,
          message: String(describing: error),
          attributes: [
            "attempt": String(attempt),
            "cancelled": String(Task.isCancelled || error is CancellationError),
            "emitted_partial_response": String(emittedSnapshot),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        let mayRetryAfterTools =
          !startedToolInvocation || configuration.allowsRetryAfterToolInvocation
        guard attempt < retryPolicy.maximumAttempts,
          !emittedSnapshot,
          mayRetryAfterTools,
          retryPolicy.shouldRetry(error)
        else {
          throw error
        }
        await recorder.record(
          runID: runID,
          kind: .modelRetryScheduled,
          message: "Native model stream retry scheduled.",
          attributes: ["next_attempt": String(attempt + 1)]
        )
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }

  private func preparePlugins(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: FoundationModelsAgentRequestMetadata
  ) async throws -> PreparedPluginContext {
    var blocks: [FoundationModelsAgentContextBlock] = []
    var sanitizationFailurePolicy = FoundationModelsAgentPluginFailurePolicy.recordAndContinue

    for plugin in plugins {
      await recorder.record(
        runID: runID,
        kind: .pluginPreparationStarted,
        message: "FoundationModelsAgent session plugin preparation started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let preparation = try await plugin.prepare(
          for: FoundationModelsAgentPluginRequest(
            runID: runID,
            prompt: prompt,
            contextQuery: contextQuery,
            metadata: metadata,
            mode: sessionMode
          )
        )
        if sessionMode == .dynamicProfile, !preparation.contextBlocks.isEmpty {
          throw FoundationModelsAgentError.pluginContextUnsupportedForDynamicProfile
        }
        blocks.append(contentsOf: preparation.contextBlocks)
        if !preparation.contextBlocks.isEmpty,
          case .failRun = plugin.failurePolicies.sanitization
        {
          sanitizationFailurePolicy = .failRun
        }
        for block in preparation.contextBlocks {
          await recorder.record(
            runID: runID,
            kind: .pluginEvent,
            message: "FoundationModelsAgent session plugin contributed context.",
            attributes: [
              "plugin": plugin.identifier,
              "plugin_event": "context_prepared",
              "context_block_id": block.id,
            ].merging(block.attributes) { current, _ in current }
          )
        }
        await recordPluginEvents(preparation.events, plugin: plugin.identifier, runID: runID)
        await recorder.record(
          runID: runID,
          kind: .pluginPreparationCompleted,
          message: "FoundationModelsAgent session plugin preparation completed.",
          attributes: [
            "plugin": plugin.identifier,
            "context_blocks": String(preparation.contextBlocks.count),
          ]
        )
      } catch {
        await recorder.record(
          runID: runID,
          kind: .pluginPreparationFailed,
          message: String(describing: error),
          attributes: [
            "plugin": plugin.identifier,
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        if case .failRun = plugin.failurePolicies.preparation {
          throw error
        }
      }
    }

    return PreparedPluginContext(
      contextBlocks: blocks,
      sanitizationFailurePolicy: sanitizationFailurePolicy
    )
  }

  private func completePlugins(_ completion: FoundationModelsAgentPluginCompletion) async throws {
    var fatalError: (any Error)?

    for plugin in plugins {
      await recorder.record(
        runID: completion.runID,
        kind: .pluginCompletionStarted,
        message: "FoundationModelsAgent session plugin completion started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let events = try await plugin.didComplete(completion)
        await recordPluginEvents(events, plugin: plugin.identifier, runID: completion.runID)
        await recorder.record(
          runID: completion.runID,
          kind: .pluginCompletionCompleted,
          message: "FoundationModelsAgent session plugin completion completed.",
          attributes: ["plugin": plugin.identifier]
        )
      } catch {
        await recorder.record(
          runID: completion.runID,
          kind: .pluginCompletionFailed,
          message: String(describing: error),
          attributes: [
            "plugin": plugin.identifier,
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        if case .failRun = plugin.failurePolicies.completion, fatalError == nil {
          fatalError = error
        }
      }
    }

    if let fatalError {
      throw fatalError
    }
  }

  private func failPlugins(_ failure: FoundationModelsAgentPluginFailure) async {
    for plugin in plugins {
      let events = await plugin.didFail(failure)
      await recordPluginEvents(events, plugin: plugin.identifier, runID: failure.runID)
    }
  }

  private func recordPluginEvents(
    _ events: [FoundationModelsAgentPluginEvent],
    plugin: String,
    runID: UUID
  ) async {
    for event in events {
      var attributes = event.attributes
      attributes["plugin"] = plugin
      attributes["plugin_event"] = event.name
      await recorder.record(
        runID: runID,
        kind: .pluginEvent,
        message: event.message,
        attributes: attributes
      )
    }
  }

  private func makePrompt(
    _ prompt: Prompt,
    contextBlocks: [FoundationModelsAgentContextBlock]
  ) -> Prompt {
    guard !contextBlocks.isEmpty else { return prompt }
    return Prompt {
      contextBlocks.map(\.content)
      prompt
    }
  }

  private func sanitizePluginContext(
    in transcript: Transcript,
    contextBlocks: [FoundationModelsAgentContextBlock],
    requiresMatch: Bool
  ) throws -> Transcript {
    let sanitized = try sanitizePluginContext(
      in: Array(transcript),
      contextBlocks: contextBlocks,
      requiresMatch: requiresMatch
    )
    var transcript = Transcript()
    transcript.append(contentsOf: sanitized)
    return transcript
  }

  private func transcriptEntries(
    addedTo transcript: Transcript,
    after previousTranscript: Transcript
  ) -> [Transcript.Entry] {
    let entries = Array(transcript)
    let previousEntryCount = Array(previousTranscript).count
    guard entries.count >= previousEntryCount else { return entries }
    return Array(entries.dropFirst(previousEntryCount))
  }

  private func sanitizePluginContext(
    in entries: [Transcript.Entry],
    contextBlocks: [FoundationModelsAgentContextBlock],
    requiresMatch: Bool
  ) throws -> [Transcript.Entry] {
    guard !contextBlocks.isEmpty else { return entries }
    let expected = contextBlocks.map(\.content)
    var entries = entries

    for index in entries.indices.reversed() {
      guard case .prompt(let prompt) = entries[index],
        prompt.segments.count >= expected.count
      else {
        continue
      }
      let prefix = prompt.segments.prefix(expected.count)
      let matches = zip(prefix, expected).allSatisfy { segment, content in
        guard case .text(let text) = segment else { return false }
        return text.content == content
      }
      guard matches else { continue }

      let sanitizedPrompt = Transcript.Prompt(
        id: prompt.id,
        metadata: prompt.metadata,
        segments: Array(prompt.segments.dropFirst(expected.count)),
        options: prompt.options,
        responseFormat: prompt.responseFormat,
        contextOptions: prompt.contextOptions
      )
      entries[index] = .prompt(sanitizedPrompt)
      return entries
    }

    if requiresMatch {
      throw FoundationModelsAgentError.pluginContextSanitizationFailed
    }
    return entries
  }

  private func sanitizeCompletedTranscript(
    _ transcript: Transcript,
    fallback: Transcript,
    context: PreparedPluginContext,
    runID: UUID
  ) async throws -> Transcript {
    do {
      return try sanitizePluginContext(
        in: transcript,
        contextBlocks: context.contextBlocks,
        requiresMatch: !context.contextBlocks.isEmpty
      )
    } catch {
      await recordSanitizationFailure(error, context: context, runID: runID)
      if case .failRun = context.sanitizationFailurePolicy {
        throw error
      }
      return fallback
    }
  }

  private func sanitizeFailedTranscript(
    _ transcript: Transcript,
    fallback: Transcript,
    context: PreparedPluginContext,
    runID: UUID
  ) async -> Transcript {
    do {
      return try sanitizePluginContext(
        in: transcript,
        contextBlocks: context.contextBlocks,
        requiresMatch: !context.contextBlocks.isEmpty
      )
    } catch {
      await recordSanitizationFailure(error, context: context, runID: runID)
      return fallback
    }
  }

  private func recordSanitizationFailure(
    _ error: any Error,
    context: PreparedPluginContext,
    runID: UUID
  ) async {
    await recorder.record(
      runID: runID,
      kind: .pluginEvent,
      message:
        "FoundationModelsAgent could not verify injected context during transcript sanitization.",
      attributes: [
        "plugin_event": "context_sanitization_failed",
        "context_block_ids": context.contextBlocks.map(\.id).joined(separator: ","),
        "error_type": String(reflecting: Swift.type(of: error)),
        "history_reverted": "true",
      ]
    )
  }

  private func installSession(
    transcript: Transcript,
    ifNeededFor context: PreparedPluginContext
  ) {
    guard sessionMode == .explicitModel, !context.contextBlocks.isEmpty else { return }
    let session = makeSession(transcript)
    session.transcriptErrorHandlingPolicy = configuration.transcriptErrorHandlingPolicy.nativeValue
    nativeSession = session
  }

  private func persist(transcript: Transcript, runID: UUID?) async throws
    -> FoundationModelsAgentCheckpoint
  {
    if let runID, checkpointStore != nil {
      await recorder.record(
        runID: runID,
        kind: .checkpointWriteStarted,
        message: "Native transcript checkpoint write started."
      )
    }
    let retained = try await retention.prepareForPersistence(transcript)
    let checkpoint = FoundationModelsAgentCheckpoint(
      compatibilityRevision: checkpointCompatibilityRevision,
      transcript: retained
    )
    try await checkpointStore?.saveCheckpoint(checkpoint, for: checkpointKey)
    if let runID, checkpointStore != nil {
      await recorder.record(
        runID: runID,
        kind: .transcriptCheckpointed,
        message: "Native transcript checkpointed.",
        attributes: ["history_entries": String(retained.history.count)]
      )
    }
    return checkpoint
  }

  private func persistAfterSuccessfulResponse(
    transcript: Transcript,
    runID: UUID
  ) async throws {
    guard checkpointStore != nil else { return }
    do {
      _ = try await persist(transcript: transcript, runID: runID)
    } catch {
      await recordCheckpointFailure(error, runID: runID)
      if case .failRun = configuration.checkpointFailurePolicy {
        throw error
      }
    }
  }

  private func persistAfterFailedResponse(
    transcript: Transcript,
    runID: UUID
  ) async {
    guard checkpointStore != nil else { return }
    do {
      _ = try await persist(transcript: transcript, runID: runID)
    } catch {
      await recordCheckpointFailure(error, runID: runID)
    }
  }

  private func recordCheckpointFailure(_ error: any Error, runID: UUID) async {
    await recorder.record(
      runID: runID,
      kind: .transcriptCheckpointFailed,
      message: String(describing: error),
      attributes: ["error_type": String(reflecting: Swift.type(of: error))]
    )
  }

  private func recordNativeToolEntries(
    _ entries: ArraySlice<Transcript.Entry>,
    runID: UUID
  ) async {
    for entry in entries {
      switch entry {
      case .toolCalls(let calls):
        for call in calls {
          await recorder.record(
            runID: runID,
            kind: .nativeToolCallRecorded,
            message: "Native transcript recorded a tool call.",
            attributes: [
              "native_call_id": call.id,
              "profile_owned": "false",
              "tool": call.toolName,
            ]
          )
        }
      case .toolOutput(let output):
        await recorder.record(
          runID: runID,
          kind: .nativeToolOutputRecorded,
          message: "Native transcript recorded tool output.",
          attributes: [
            "native_call_id": output.id,
            "profile_owned": "false",
            "tool": output.toolName,
          ]
        )
      default:
        continue
      }
    }
  }

  private func recordProfileAuditBoundary(runID: UUID) async {
    guard recordsProfileToolLifecycle else { return }
    await recorder.record(
      runID: runID,
      kind: .profileToolAuditBestEffort,
      message:
        "Dynamic-profile tool observation is best effort; an earlier failing profile lifecycle hook can preempt FoundationModelsAgent observation."
    )
  }

  private func recordPendingCheckpointRestore(runID: UUID) async {
    guard let checkpointFound = pendingCheckpointRestoreFound else { return }
    pendingCheckpointRestoreFound = nil
    await recorder.record(
      runID: runID,
      kind: .checkpointRestoreCompleted,
      message: "Native transcript checkpoint was restored before this run.",
      attributes: [
        "checkpoint_found": String(checkpointFound),
        "restored_before_run": "true",
      ]
    )
  }

  private func recordRunFailure(_ error: any Error, runID: UUID) async {
    let kind: FoundationModelsAgentEventKind =
      Task.isCancelled || error is CancellationError ? .runCancelled : .runFailed
    await recorder.record(
      runID: runID,
      kind: kind,
      message: String(describing: error),
      attributes: ["error_type": String(reflecting: Swift.type(of: error))]
    )
  }

  private func finishRun(
    runID: UUID,
    startedAt: Date,
    usage: FoundationModelsAgentUsage?
  ) async -> FoundationModelsAgentRun {
    let events = await recorder.events(for: runID)
    let run = FoundationModelsAgentRun(
      id: runID,
      startedAt: startedAt,
      endedAt: Date(),
      usage: usage,
      events: events
    )
    mostRecentRun = run
    await recorder.discard(runID: runID)
    return run
  }

  private func acquireSessionLease() throws {
    guard !hasActiveOperation else {
      throw FoundationModelsAgentError.concurrentOperation
    }
    hasActiveOperation = true
  }

  private func releaseSessionLease() {
    hasActiveOperation = false
  }

  private static func makeToolsetRevision(_ manifests: [FoundationModelsAgentToolManifest])
    -> String
  {
    let source = manifests.sorted { $0.name < $1.name }.map(\.digest).joined(separator: "\n")
    return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func makeProfileRevision(_ compatibilityID: String) -> String {
    SHA256.hash(data: Data("foundationmodelsagent-profile-v1\u{0}\(compatibilityID)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func makePreviousProfileRevision(_ compatibilityID: String) -> String {
    let salt = ["core", "agent-profile-v1"].joined()
    return SHA256.hash(data: Data("\(salt)\u{0}\(compatibilityID)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func validate(
    configuration: FoundationModelsAgentConfiguration,
    toolConfiguration: FoundationModelsAgentToolConfiguration,
    transcriptRetention: FoundationModelsAgentTranscriptRetention,
    observerDeliveryConfiguration: FoundationModelsAgentObserverDeliveryConfiguration
  ) throws {
    if let timeout = configuration.responseTimeout, timeout < .zero {
      throw FoundationModelsAgentError.invalidDuration(name: "Response timeout")
    }
    if let timeout = toolConfiguration.executionTimeout, timeout < .zero {
      throw FoundationModelsAgentError.invalidDuration(name: "Tool execution timeout")
    }
    if let limit = toolConfiguration.maximumCallsPerRun, limit < 0 {
      throw FoundationModelsAgentError.invalidToolCallLimit(limit)
    }
    guard observerDeliveryConfiguration.maximumPendingEvents > 0 else {
      throw FoundationModelsAgentError.invalidObserverQueueLimit(
        observerDeliveryConfiguration.maximumPendingEvents)
    }
    guard observerDeliveryConfiguration.defaultFlushTimeout >= .zero else {
      throw FoundationModelsAgentError.invalidDuration(name: "Observer flush timeout")
    }
    if case .preserve = configuration.transcriptErrorHandlingPolicy,
      configuration.retryPolicy.maximumAttempts > 1
    {
      throw FoundationModelsAgentError.unsafeRetryConfiguration(
        "Preserved partial transcripts cannot be retried safely. Use .revert or one attempt."
      )
    }
    try transcriptRetention.validate()
  }

  private static func validate(plugins: [any AgentSessionPlugin]) throws {
    var identifiers: Set<String> = []
    for plugin in plugins {
      let identifier = plugin.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty else {
        throw FoundationModelsAgentError.emptyPluginIdentifier
      }
      guard identifiers.insert(identifier).inserted else {
        throw FoundationModelsAgentError.duplicatePluginIdentifier(identifier)
      }
    }
  }

  private static func validateUniqueToolNames(_ tools: [any Tool]) throws {
    var names: Set<String> = []
    for tool in tools {
      guard names.insert(tool.name).inserted else {
        throw FoundationModelsAgentError.duplicateToolName(tool.name)
      }
    }
  }
}

private struct PreparedPluginContext: Sendable {
  let contextBlocks: [FoundationModelsAgentContextBlock]
  let sanitizationFailurePolicy: FoundationModelsAgentPluginFailurePolicy

  static let empty = PreparedPluginContext(
    contextBlocks: [],
    sanitizationFailurePolicy: .recordAndContinue
  )
}

private final class NativeResponseBox<Content: Generable>: @unchecked Sendable {
  let response: LanguageModelSession.Response<Content>

  init(_ response: LanguageModelSession.Response<Content>) {
    self.response = response
  }
}

private final class NativeStreamSnapshotBox<Content: Generable>: @unchecked Sendable {
  let snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot

  init(_ snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot) {
    self.snapshot = snapshot
  }
}

private actor StreamAttemptState {
  private(set) var emittedSnapshot = false

  func markSnapshotEmitted() {
    emittedSnapshot = true
  }
}
