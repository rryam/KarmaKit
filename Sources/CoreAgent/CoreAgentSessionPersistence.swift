import CryptoKit
import Foundation
import FoundationModels

extension CoreAgentSession {
  func installSession(
    transcript: Transcript,
    ifNeededFor context: PreparedPluginContext
  ) {
    guard !context.contextBlocks.isEmpty else { return }
    _ = installSession(transcript: transcript)
  }

  @discardableResult
  func installSession(transcript: Transcript) -> Bool {
    guard sessionMode == .explicitModel else { return false }
    let session = makeSession(transcript)
    session.transcriptErrorHandlingPolicy = configuration.transcriptErrorHandlingPolicy.nativeValue
    nativeSession = session
    return true
  }

  func persist(
    transcript: Transcript,
    runID: UUID?
  ) async throws -> CoreAgentPersistedTranscript {
    let preparation = try await retention.prepareForPersistence(transcript)
    let persistableTranscript =
      CoreAgentCheckpointPersistenceValidation.sanitizedForFilePersistence(
        preparation.transcript
      )
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: checkpointCompatibilityRevision,
      transcript: persistableTranscript,
      artifacts: preparation.artifacts
    )
    let savedToCheckpointStore: Bool
    do {
      try await preparation.finalize()
      if let checkpointStore {
        try await checkpointStore.saveCheckpoint(checkpoint, for: checkpointKey)
        savedToCheckpointStore = true
      } else {
        savedToCheckpointStore = false
      }
    } catch {
      await preparation.rollback()
      throw error
    }
    if let runID, checkpointStore != nil {
      await recorder.record(
        runID: runID,
        kind: .transcriptCheckpointed,
        message: "Native transcript checkpointed.",
        attributes: [
          "history_entries": String(preparation.transcript.history.count),
          "artifacts": String(preparation.artifacts.count),
        ]
      )
    }
    return CoreAgentPersistedTranscript(
      checkpoint: checkpoint,
      activeSessionTranscript: preparation.activeSessionTranscript,
      savedToCheckpointStore: savedToCheckpointStore
    )
  }

  func persistAfterSuccessfulResponse(
    transcript: Transcript,
    runID: UUID
  ) async throws -> CoreAgentPersistedTranscript? {
    guard checkpointStore != nil else { return nil }
    do {
      return try await persist(transcript: transcript, runID: runID)
    } catch {
      await recordCheckpointFailure(error, runID: runID)
      if case .failRun = configuration.checkpointFailurePolicy {
        throw error
      }
      return nil
    }
  }

  func persistAfterFailedResponse(
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

  func recordCheckpointFailure(_ error: any Error, runID: UUID) async {
    await recorder.record(
      runID: runID,
      kind: .transcriptCheckpointFailed,
      message: String(describing: error),
      attributes: ["error_type": String(reflecting: Swift.type(of: error))]
    )
  }

  func installActiveSessionTranscriptIfNeeded(
    from persisted: CoreAgentPersistedTranscript?
  ) -> Bool {
    guard let persisted,
      persisted.savedToCheckpointStore,
      let activeSessionTranscript = persisted.activeSessionTranscript
    else {
      return false
    }
    return installSession(transcript: activeSessionTranscript)
  }

  func recordActiveSessionCompactionIfNeeded(
    installed: Bool,
    persisted: CoreAgentPersistedTranscript?,
    runID: UUID
  ) async {
    guard installed, let persisted else { return }
    await recorder.record(
      runID: runID,
      kind: .transcriptActiveSessionCompacted,
      message: "Native active session rebuilt from retained checkpoint transcript.",
      attributes: [
        "history_entries": String(persisted.checkpoint.transcript.history.count),
        "artifacts": String(persisted.checkpoint.artifacts.count),
      ]
    )
  }

  func recordNativeToolEntries(
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
              "tool": call.toolName,
              "requested_arguments_digest": CoreAgentArgumentAudit.digest(call.arguments),
              "requested_arguments_json": CoreAgentArgumentAudit.redactedJSONString(call.arguments),
            ]
          )
        }
      case .toolOutput(let output):
        var attributes = [
          "native_call_id": output.id,
          "tool": output.toolName,
        ]
        if let provenance = await toolRuntime.consumeOutputProvenance(
          runID: runID,
          toolName: output.toolName
        ) {
          attributes["tool_invocation_id"] =
            provenance.toolInvocationID.uuidString.lowercased()
          attributes["output_source"] = provenance.outputSource
          attributes["arguments_source"] = provenance.argumentsSource
          attributes["requested_arguments_digest"] = provenance.requestedArgumentsDigest
          if let executedArgumentsDigest = provenance.executedArgumentsDigest {
            attributes["executed_arguments_digest"] = executedArgumentsDigest
          }
        }
        await recorder.record(
          runID: runID,
          kind: .nativeToolOutputRecorded,
          message: "Native transcript recorded tool output.",
          attributes: attributes
        )
      default:
        continue
      }
    }
  }

  func recordProfileAuditBoundary(runID: UUID) async {
    guard recordsProfileToolLifecycle else { return }
    await recorder.record(
      runID: runID,
      kind: .profileToolAuditBestEffort,
      message:
        "Dynamic-profile tool observation is best effort; an earlier failing profile lifecycle hook can preempt CoreAgent observation."
    )
  }

  func finishRun(
    runID: UUID,
    startedAt: Date,
    usage: CoreAgentUsage?
  ) async -> CoreAgentRun {
    let events = await recorder.events(for: runID)
    let run = CoreAgentRun(
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

  func acquireSessionLease() throws {
    guard !hasActiveOperation else {
      throw CoreAgentError.concurrentOperation
    }
    hasActiveOperation = true
  }

  func releaseSessionLease() {
    hasActiveOperation = false
  }
}
