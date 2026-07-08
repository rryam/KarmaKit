import CryptoKit
import Foundation
import FoundationModels

extension CoreAgentSession {
  func resolveSession() async throws -> LanguageModelSession {
    if let nativeSession {
      return nativeSession
    }

    let checkpoint = try await checkpointStore?.loadCheckpoint(for: checkpointKey)
    let transcript: Transcript?
    if let checkpoint {
      guard checkpoint.formatVersion == CoreAgentCheckpoint.currentFormatVersion else {
        throw CoreAgentError.unsupportedCheckpointVersion(checkpoint.formatVersion)
      }
      if requiresMatchingCheckpointConfiguration,
        checkpoint.compatibilityRevision != checkpointCompatibilityRevision
      {
        throw CoreAgentError.checkpointCompatibilityMismatch(
          expected: checkpointCompatibilityRevision,
          actual: checkpoint.compatibilityRevision
        )
      }
      transcript = checkpoint.transcript
    } else {
      transcript = nil
    }

    let session = makeSession(transcript)
    session.transcriptErrorHandlingPolicy = configuration.transcriptErrorHandlingPolicy.nativeValue
    nativeSession = session
    return session
  }

  func performResponse<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    _ operation:
      @escaping @Sendable (LanguageModelSession, Prompt) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> CoreAgentResponse<Content> {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    let transcriptBeforeRun = session.transcript
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models run started.")
    await recordProfileAuditBoundary(runID: runID)
    await toolRuntime.begin(runID: runID)
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
        contentType: Content.self,
        preparedPrompt: preparedPrompt,
        contextBlocks: pluginContext.contextBlocks,
        promptFallback: contextQuery,
        operation: { try await operation($0, preparedPrompt) }
      )
      completedModelResponse = true
      let usage = CoreAgentUsage(nativeResponse.usage)
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
      let persisted = try await persistAfterSuccessfulResponse(
        transcript: sanitizedTranscript,
        runID: runID
      )
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: nativeResponse.rawContent,
          transcriptEntries: runTranscriptEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recordActiveSessionCompactionIfNeeded(
        installed: installActiveSessionTranscriptIfNeeded(from: persisted),
        persisted: persisted,
        runID: runID
      )
      await finishRunLifecycleTools(runID: runID)
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await notifyRunObservers(run)
      await toolRuntime.finish(runID: runID)
      return CoreAgentResponse(
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
        CoreAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await finishRunLifecycleTools(runID: runID)
      await recorder.record(
        runID: runID,
        kind: .runFailed,
        message: String(describing: error),
        attributes: ["error_type": String(reflecting: Swift.type(of: error))]
      )
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await notifyRunObservers(run)
      await toolRuntime.finish(runID: runID)
      throw error
    }
  }

  struct ResolvedModelResponse<Content: Generable & Sendable>: Sendable {
    let content: Content
    let rawContent: GeneratedContent
    let transcriptEntries: ArraySlice<Transcript.Entry>
    let usage: LanguageModelSession.Usage

    init(_ response: LanguageModelSession.Response<Content>) {
      content = response.content
      rawContent = response.rawContent
      transcriptEntries = response.transcriptEntries
      usage = response.usage
    }

    init(_ response: CoreAgentScriptedModelResponse<Content>) {
      content = response.content
      rawContent = response.rawContent
      transcriptEntries = response.transcriptEntries
      usage = response.usage
    }
  }

  func responseWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    contentType: Content.Type,
    preparedPrompt: Prompt,
    contextBlocks: [CoreAgentContextBlock],
    promptFallback: String?,
    operation:
      @escaping @Sendable (LanguageModelSession) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> ResolvedModelResponse<Content> {
    if let scriptedModelResponder {
      CoreAgentScriptedModelSupport.appendPrompt(
        preparedPrompt,
        contextBlocks: contextBlocks,
        fallbackText: promptFallback,
        to: session
      )
    }

    let retryPolicy = configuration.retryPolicy
    for attempt in 1...retryPolicy.maximumAttempts {
      await recorder.record(
        runID: runID,
        kind: .modelAttemptStarted,
        message: "Native model attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      do {
        if scriptedModelResponder != nil {
          if let timeout = configuration.responseTimeout {
            do {
              let scripted = try await withCoreAgentTimeout(timeout) {
                guard
                  let scripted = try await self.scriptedSessionResponseIfConfigured(
                    session: session,
                    runID: runID,
                    contentType: contentType,
                    preparedPrompt: preparedPrompt,
                    contextBlocks: contextBlocks,
                    promptFallback: promptFallback
                  )
                else {
                  throw CoreAgentError.streamFinishedWithoutResponse
                }
                return scripted
              }
              return ResolvedModelResponse(scripted)
            } catch is CoreAgentTimeoutMarker {
              throw CoreAgentError.responseTimedOut
            }
          }
          if let scripted = try await scriptedSessionResponseIfConfigured(
            session: session,
            runID: runID,
            contentType: contentType,
            preparedPrompt: preparedPrompt,
            contextBlocks: contextBlocks,
            promptFallback: promptFallback
          ) {
            return ResolvedModelResponse(scripted)
          }
        }
        guard let timeout = configuration.responseTimeout else {
          return ResolvedModelResponse(try await operation(session))
        }
        do {
          let box = try await withCoreAgentTimeout(timeout) {
            NativeResponseBox(try await operation(session))
          }
          return ResolvedModelResponse(box.response)
        } catch is CoreAgentTimeoutMarker {
          throw CoreAgentError.responseTimedOut
        }
      } catch {
        await recorder.record(
          runID: runID,
          kind: .modelAttemptFailed,
          message: String(describing: error),
          attributes: [
            "attempt": String(attempt),
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
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }
}
