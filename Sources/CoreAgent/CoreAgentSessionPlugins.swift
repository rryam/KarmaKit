import CryptoKit
import Foundation
import FoundationModels

extension CoreAgentSession {
  func preparePlugins(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata
  ) async throws -> PreparedPluginContext {
    var blocks: [CoreAgentContextBlock] = []
    var sanitizationFailurePolicy = CoreAgentPluginFailurePolicy.recordAndContinue

    for plugin in plugins {
      await recorder.record(
        runID: runID,
        kind: .pluginPreparationStarted,
        message: "CoreAgent session plugin preparation started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let preparation = try await plugin.prepare(
          for: CoreAgentPluginRequest(
            runID: runID,
            prompt: prompt,
            contextQuery: contextQuery,
            metadata: metadata,
            mode: sessionMode
          )
        )
        if sessionMode == .dynamicProfile, !preparation.contextBlocks.isEmpty {
          throw CoreAgentError.pluginContextUnsupportedForDynamicProfile
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
            message: "CoreAgent session plugin contributed context.",
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
          message: "CoreAgent session plugin preparation completed.",
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

  func completePlugins(_ completion: CoreAgentPluginCompletion) async throws {
    var fatalError: (any Error)?

    for plugin in plugins {
      await recorder.record(
        runID: completion.runID,
        kind: .pluginCompletionStarted,
        message: "CoreAgent session plugin completion started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let events = try await plugin.didComplete(completion)
        await recordPluginEvents(events, plugin: plugin.identifier, runID: completion.runID)
        await recorder.record(
          runID: completion.runID,
          kind: .pluginCompletionCompleted,
          message: "CoreAgent session plugin completion completed.",
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

  func failPlugins(_ failure: CoreAgentPluginFailure) async {
    for plugin in plugins {
      let events = await plugin.didFail(failure)
      await recordPluginEvents(events, plugin: plugin.identifier, runID: failure.runID)
    }
  }

  func finishRunLifecycleTools(runID: UUID) async {
    for tool in runLifecycleTools {
      await tool.coreAgentRunDidFinish(runID)
    }
  }

  func notifyRunObservers(_ run: CoreAgentRun) async {
    for observer in runObservers {
      await observer.coreAgentRunDidFinish(run)
    }
  }

  func recordPluginEvents(
    _ events: [CoreAgentPluginEvent],
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

  func makePrompt(
    _ prompt: Prompt,
    contextBlocks: [CoreAgentContextBlock]
  ) -> Prompt {
    guard !contextBlocks.isEmpty else { return prompt }
    return Prompt {
      contextBlocks.map(\.content)
      prompt
    }
  }

  func sanitizePluginContext(
    in transcript: Transcript,
    contextBlocks: [CoreAgentContextBlock],
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

  func transcriptEntries(
    addedTo transcript: Transcript,
    after previousTranscript: Transcript
  ) -> [Transcript.Entry] {
    let entries = Array(transcript)
    let previousEntryCount = Array(previousTranscript).count
    guard entries.count >= previousEntryCount else { return entries }
    return Array(entries.dropFirst(previousEntryCount))
  }

  func sanitizePluginContext(
    in entries: [Transcript.Entry],
    contextBlocks: [CoreAgentContextBlock],
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
      throw CoreAgentError.pluginContextSanitizationFailed
    }
    return entries
  }

  func sanitizeCompletedTranscript(
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

  func sanitizeFailedTranscript(
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

  func recordSanitizationFailure(
    _ error: any Error,
    context: PreparedPluginContext,
    runID: UUID
  ) async {
    await recorder.record(
      runID: runID,
      kind: .pluginEvent,
      message: "CoreAgent could not verify injected context during transcript sanitization.",
      attributes: [
        "plugin_event": "context_sanitization_failed",
        "context_block_ids": context.contextBlocks.map(\.id).joined(separator: ","),
        "error_type": String(reflecting: Swift.type(of: error)),
        "history_reverted": "true",
      ]
    )
  }
}
