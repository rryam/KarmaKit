import CryptoKit
import Foundation
import FoundationModels

extension CoreAgentSession {
  func performStream<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    _ makeStream:
      @escaping @Sendable (LanguageModelSession, Prompt) ->
      LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    let transcriptBeforeRun = session.transcript
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models streaming run started.")
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
      let lastSnapshot = try await streamWithRetry(
        session: session,
        runID: runID,
        contentType: Content.self,
        preparedPrompt: preparedPrompt,
        contextBlocks: pluginContext.contextBlocks,
        promptFallback: contextQuery,
        makeStream: { makeStream($0, preparedPrompt) },
        onPartialResponse: onPartialResponse
      )
      completedModelResponse = true
      let content = try CoreAgentScriptedModelSupport.content(
        Content.self, from: lastSnapshot.rawContent)
      let usage = CoreAgentUsage(lastSnapshot.usage)
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
      let persisted = try await persistAfterSuccessfulResponse(
        transcript: sanitizedTranscript,
        runID: runID
      )
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: lastSnapshot.rawContent,
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

  struct ResolvedStreamSnapshot<Content: Generable & Sendable>: Sendable
  where Content.PartiallyGenerated: Sendable {
    let content: Content.PartiallyGenerated
    let rawContent: GeneratedContent
    let transcriptEntries: ArraySlice<Transcript.Entry>
    let usage: LanguageModelSession.Usage

    init(_ snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot) {
      content = snapshot.content
      rawContent = snapshot.rawContent
      transcriptEntries = snapshot.transcriptEntries
      usage = snapshot.usage
    }

    init(_ snapshot: CoreAgentScriptedStreamSnapshot<Content>) {
      content = snapshot.content
      rawContent = snapshot.rawContent
      transcriptEntries = snapshot.transcriptEntries
      usage = snapshot.usage
    }
  }

  func streamWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    contentType: Content.Type,
    preparedPrompt: Prompt,
    contextBlocks: [CoreAgentContextBlock],
    promptFallback: String?,
    makeStream:
      @escaping @Sendable (LanguageModelSession) -> LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> ResolvedStreamSnapshot<Content>
  where Content.PartiallyGenerated: Sendable {
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
        message: "Native model stream attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      let state = StreamAttemptState()
      do {
        if scriptedModelResponder != nil {
          if let timeout = configuration.responseTimeout {
            do {
              let scripted = try await withCoreAgentTimeout(timeout) {
                guard
                  let scripted = try await self.scriptedStreamSnapshotIfConfigured(
                    session: session,
                    contentType: contentType,
                    preparedPrompt: preparedPrompt,
                    contextBlocks: contextBlocks,
                    promptFallback: promptFallback,
                    onPartialResponse: onPartialResponse
                  )
                else {
                  throw CoreAgentError.streamFinishedWithoutResponse
                }
                return scripted
              }
              return ResolvedStreamSnapshot(scripted)
            } catch is CoreAgentTimeoutMarker {
              throw CoreAgentError.responseTimedOut
            }
          }
          if let scripted = try await scriptedStreamSnapshotIfConfigured(
            session: session,
            contentType: contentType,
            preparedPrompt: preparedPrompt,
            contextBlocks: contextBlocks,
            promptFallback: promptFallback,
            onPartialResponse: onPartialResponse
          ) {
            return ResolvedStreamSnapshot(scripted)
          }
        }
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
            throw CoreAgentError.streamFinishedWithoutResponse
          }
          return NativeStreamSnapshotBox(lastSnapshot)
        }

        guard let timeout = configuration.responseTimeout else {
          return ResolvedStreamSnapshot(try await consume().snapshot)
        }
        do {
          return ResolvedStreamSnapshot(
            try await withCoreAgentTimeout(timeout, operation: consume).snapshot)
        } catch is CoreAgentTimeoutMarker {
          throw CoreAgentError.responseTimedOut
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
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }

  func scriptedSessionResponseIfConfigured<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    contentType: Content.Type,
    preparedPrompt: Prompt,
    contextBlocks: [CoreAgentContextBlock],
    promptFallback: String?
  ) async throws -> CoreAgentScriptedModelResponse<Content>? {
    guard let scriptedModelResponder else { return nil }

    var workingTranscript = session.transcript
    var combinedUsage = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 0, cachedTokenCount: 0),
      output: .init(totalTokenCount: 0, reasoningTokenCount: 0)
    )
    var combinedEntries: [Transcript.Entry] = []

    while true {
      let response = try await scriptedModelResponder.makeScriptedResponse(
        for: workingTranscript,
        contentType: contentType
      )
      workingTranscript.append(contentsOf: response.transcriptEntries)
      CoreAgentScriptedModelSupport.apply(response.transcriptEntries, to: session)
      session.transcript = workingTranscript
      combinedEntries.append(contentsOf: response.transcriptEntries)
      combinedUsage = mergeUsage(combinedUsage, response.usage)

      if response.continuesAfterToolCalls {
        let toolOutputs = try await executeScriptedToolCalls(
          in: response.transcriptEntries,
          session: session,
          runID: runID
        )
        workingTranscript.append(contentsOf: toolOutputs)
        session.transcript = workingTranscript
        combinedEntries.append(contentsOf: toolOutputs)
        continue
      }

      return CoreAgentScriptedModelResponse(
        content: response.content,
        rawContent: response.rawContent,
        transcriptEntries: combinedEntries[...],
        usage: combinedUsage
      )
    }
  }

  func scriptedStreamSnapshotIfConfigured<Content: Generable & Sendable>(
    session: LanguageModelSession,
    contentType: Content.Type,
    preparedPrompt: Prompt,
    contextBlocks: [CoreAgentContextBlock],
    promptFallback: String?,
    onPartialResponse: @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> CoreAgentScriptedStreamSnapshot<Content>?
  where Content.PartiallyGenerated: Sendable {
    guard let scriptedModelResponder else { return nil }
    let snapshot = try await scriptedModelResponder.makeScriptedStreamSnapshot(
      for: session.transcript,
      contentType: contentType,
      onPartialResponse: onPartialResponse
    )
    CoreAgentScriptedModelSupport.apply(snapshot.transcriptEntries, to: session)
    return snapshot
  }

  func executeScriptedToolCalls(
    in entries: ArraySlice<Transcript.Entry>,
    session: LanguageModelSession,
    runID: UUID
  ) async throws -> [Transcript.Entry] {
    var outputs: [Transcript.Entry] = []
    for entry in entries {
      guard case .toolCalls(let calls) = entry else { continue }
      for call in calls {
        guard let tool = scriptedToolsByName[call.toolName] else {
          throw CoreAgentScriptedModelBridgeError.missingScriptedTool(call.toolName)
        }
        if recordsProfileToolLifecycle {
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
        let prompt: Prompt
        do {
          prompt = try await CoreAgentAnyTool(tool).call(arguments: call.arguments)
        } catch {
          throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
        }
        let outputEntry = CoreAgentScriptedModelSupport.toolOutputEntry(
          id: call.id,
          toolName: call.toolName,
          output: prompt
        )
        if recordsProfileToolLifecycle, !scriptedSuppressProfileToolOutputAudit {
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
        outputs.append(outputEntry)
        CoreAgentScriptedModelSupport.apply([outputEntry][...], to: session)
      }
    }
    return outputs
  }

  func mergeUsage(
    _ lhs: LanguageModelSession.Usage,
    _ rhs: LanguageModelSession.Usage
  ) -> LanguageModelSession.Usage {
    .init(
      input: .init(
        totalTokenCount: lhs.input.totalTokenCount + rhs.input.totalTokenCount,
        cachedTokenCount: lhs.input.cachedTokenCount + rhs.input.cachedTokenCount
      ),
      output: .init(
        totalTokenCount: lhs.output.totalTokenCount + rhs.output.totalTokenCount,
        reasoningTokenCount: lhs.output.reasoningTokenCount + rhs.output.reasoningTokenCount
      )
    )
  }
}
