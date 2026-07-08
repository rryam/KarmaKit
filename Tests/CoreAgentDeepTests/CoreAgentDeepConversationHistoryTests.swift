import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep conversation history compaction")
struct CoreAgentDeepConversationHistoryTests {
  @Test("Keeps small native histories unchanged")
  func keepsSmallHistoriesUnchanged() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(maximumInlineHistoryEntries: 4, retainedHistoryEntries: 2)
    )
    let transcript = Transcript(entries: [
      prompt("small prompt"),
      response("small response"),
    ])

    let decision = try await compactor.compact(transcript: transcript, scopeID: "thread-1")

    #expect(decision == .unchanged(transcript))
    #expect(await filesystem.snapshot().isEmpty)
  }

  @Test("Offloads full native transcript and replaces older history with a marked summary")
  func offloadsFullTranscriptAndCompactsHistory() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.write, .read], paths: ["/conversation_history/**"])
      ]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(
        maximumInlineHistoryEntries: 4,
        retainedHistoryEntries: 2,
        summaryEntryLimit: 3,
        summaryExcerptCharacters: 80
      )
    )
    let transcript = Transcript(entries: [
      prompt("old prompt api_key=secret-value"),
      response("old response"),
      prompt("middle prompt"),
      response("middle response"),
      prompt("newest prompt"),
      response("newest response"),
    ])

    let decision = try await compactor.compact(
      transcript: transcript,
      scopeID: "../thread with spaces"
    )
    let compaction = try #require(decision.compaction)

    #expect(compaction.offload.path.hasPrefix("/conversation_history/"))
    #expect(!compaction.offload.path.contains("thread"))
    #expect(!compaction.offload.path.contains("spaces"))
    #expect(compaction.offload.path.hasSuffix(".json"))
    #expect(compaction.offload.originalHistoryEntryCount == 6)
    #expect(compaction.offload.offloadedHistoryEntryCount == 4)
    #expect(compaction.offload.retainedHistoryEntryCount == 2)
    #expect(compaction.compactedTranscript.history.count == 3)
    #expect(compaction.compactedTranscript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(compaction.compactedTranscript.containsText("newest prompt"))
    #expect(compaction.compactedTranscript.containsText("newest response"))
    #expect(!compaction.compactedTranscript.containsText("old prompt api_key=secret-value"))
    #expect(!compaction.compactedTranscript.containsText(compaction.offload.path))
    #expect(compaction.summary.contains("[REDACTED]"))
    #expect(compaction.summary.contains("artifact_id=\(compaction.offload.id)"))
    #expect(!compaction.summary.contains("path="))

    let stored = try await filesystem.readFile(at: compaction.offload.path)
    let envelope = try JSONDecoder().decode(
      CoreAgentDeepConversationHistoryEnvelope.self,
      from: Data(stored.utf8)
    )
    #expect(envelope.schemaVersion == 1)
    #expect(envelope.artifactID == compaction.offload.id)
    #expect(envelope.digest == compaction.offload.digest)
    #expect(envelope.transcript == transcript)
  }

  @Test("Opaque scope path components avoid collisions and do not expose raw scope IDs")
  func scopeComponentsAreOpaqueAndCollisionResistant() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 0)
    )
    let transcript = Transcript(entries: [
      prompt("old prompt"),
      response("old response"),
      prompt("new prompt"),
      response("new response"),
    ])

    let firstDecision = try await compactor.compact(
      transcript: transcript,
      scopeID: "tenant@example.com/a/b"
    )
    let secondDecision = try await compactor.compact(
      transcript: transcript,
      scopeID: "tenant@example.com/a_b"
    )
    let first = try #require(firstDecision.compaction)
    let second = try #require(secondDecision.compaction)

    #expect(first.offload.path != second.offload.path)
    #expect(!first.offload.path.contains("tenant@example.com"))
    #expect(!first.summary.contains("tenant@example.com"))
    #expect(!second.offload.path.contains("tenant@example.com"))
    #expect(!second.summary.contains("tenant@example.com"))
  }

  @Test("Tool-call JSON arguments are structurally redacted in summaries")
  func toolCallArgumentsAreStructurallyRedactedInSummaries() async throws {
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "history_echo",
        argumentsJSON: #"{"value":"safe","api_key":"raw-key","nested":{"token":"raw-token"}}"#
      ),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [HistoryEchoTool()]
    )
    _ = try await session.respond(to: "Use the tool")
    let transcript = try await session.transcript()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(
        maximumInlineHistoryEntries: 2,
        retainedHistoryEntries: 0,
        summaryEntryLimit: 8,
        summaryExcerptCharacters: 500
      )
    )

    let decision = try await compactor.compact(transcript: transcript, scopeID: "tool-redaction")
    let compaction = try #require(decision.compaction)

    #expect(compaction.summary.contains(#""api_key":"[REDACTED]""#))
    #expect(compaction.summary.contains(#""token":"[REDACTED]""#))
    #expect(!compaction.summary.contains("raw-key"))
    #expect(!compaction.summary.contains("raw-token"))
  }

  @Test("Reasoning entries are preserved in the offload envelope but not replayed in summaries")
  func reasoningEntriesAreNotSummarizedIntoPromptContext() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .read], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 0)
    )
    let transcript = Transcript(entries: [
      prompt("old prompt"),
      reasoning("hidden chain of thought"),
      response("old response"),
      prompt("new prompt"),
      response("new response"),
    ])

    let decision = try await compactor.compact(transcript: transcript, scopeID: "reasoning")
    let compaction = try #require(decision.compaction)

    #expect(!compaction.summary.contains("hidden chain of thought"))
    #expect(!compaction.compactedTranscript.containsText("hidden chain of thought"))
    let stored = try await filesystem.readFile(at: compaction.offload.path)
    #expect(stored.contains("hidden chain of thought"))
  }

  @Test("Redacts summary excerpts before truncating them")
  func redactsBeforeTruncatingSummaryExcerpts() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(
        maximumInlineHistoryEntries: 2,
        retainedHistoryEntries: 0,
        summaryEntryLimit: 4,
        summaryExcerptCharacters: 24
      ),
      redactionPolicy: CoreAgentRedactionPolicy { value in
        value == "credential-token-" + String(repeating: "s", count: 80)
          ? "[REDACTED_CUSTOM_SECRET]" : value
      }
    )
    let secret = "credential-token-" + String(repeating: "s", count: 80)
    let transcript = Transcript(entries: [
      prompt(secret),
      response("old response"),
      prompt("new prompt"),
      response("new response"),
    ])

    let decision = try await compactor.compact(transcript: transcript, scopeID: "redaction")
    let compaction = try #require(decision.compaction)

    #expect(compaction.summary.contains("[REDACTED_CUSTOM_SECRET]"))
    #expect(!compaction.summary.contains(String(repeating: "s", count: 10)))
  }

  @Test("CoreAgent transcript retention can persist compacted history")
  func retentionAdapterPersistsCompactedHistory() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.write, .delete], paths: ["/conversation_history/**"])
      ]
    )
    let retention = CoreAgentTranscriptRetention.deepConversationHistory(
      filesystem: filesystem,
      configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
      scopeID: { "conversation" }
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      checkpointStore: checkpointStore,
      checkpointKey: "conversation",
      transcriptRetention: retention
    )

    _ = try await session.respond(to: "first prompt")
    _ = try await session.respond(to: "second prompt")

    let checkpoint = try #require(await checkpointStore.loadCheckpoint(for: "conversation"))
    #expect(checkpoint.transcript.history.count == 3)
    #expect(checkpoint.transcript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(checkpoint.transcript.containsText("second prompt"))
    #expect(checkpoint.transcript.containsText("second answer"))

    let storedFiles = await filesystem.snapshot()
    let storedPaths = storedFiles.keys.sorted()
    #expect(storedPaths.count == 1)
    #expect(storedPaths[0].hasPrefix("/conversation_history/"))
    let stored = try #require(storedFiles[storedPaths[0]])
    #expect(stored.contains("first answer"))
  }

  @Test("Model-facing read_file cannot read conversation-history artifacts without an explicit read grant")
  func conversationHistoryArtifactsAreNotModelReadableByDefault() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.write, .delete], paths: ["/conversation_history/**"])
      ]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      checkpointStore: checkpointStore,
      checkpointKey: "conversation",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "conversation" }
      )
    )

    _ = try await session.respond(to: "first prompt")
    _ = try await session.respond(to: "second prompt")

    let path = try #require(await filesystem.snapshot().keys.first)
    await #expect(throws: CoreAgentDeepFilesystemError.denied(operation: .read, path: path)) {
      _ = try await CoreAgentDeepReadFileTool(filesystem: filesystem).call(
        arguments: CoreAgentDeepReadFileArguments(path: path)
      )
    }
  }

  @Test("Checkpoint save failure rolls back conversation-history artifacts")
  func checkpointFailureRollsBackOffloadedArtifacts() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.write, .delete], paths: ["/conversation_history/**"])
      ]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      checkpointStore: ThrowingCheckpointStore(),
      checkpointKey: "conversation",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "conversation" }
      )
    )

    _ = try await session.respond(to: "first prompt")
    _ = try await session.respond(to: "second prompt")

    #expect(await filesystem.snapshot().isEmpty)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .transcriptCheckpointFailed })
  }

  @Test("Removing a checkpoint erases associated conversation-history artifacts")
  func removingCheckpointDeletesConversationHistoryArtifacts() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [
        .allow(operations: [.write, .delete], paths: ["/conversation_history/**"])
      ]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first answer"),
        .response(text: "second answer"),
      ]),
      checkpointStore: checkpointStore,
      checkpointKey: "conversation",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "conversation" }
      )
    )

    _ = try await session.respond(to: "first prompt")
    _ = try await session.respond(to: "second prompt")
    #expect(await filesystem.snapshot().count == 1)

    try await session.reset(removingCheckpoint: true)

    #expect(await filesystem.snapshot().isEmpty)
    #expect(await checkpointStore.loadCheckpoint(for: "conversation") == nil)
  }

  @Test("Does not retain orphaned native tool calls when a whole tool turn exceeds the retained budget")
  func compactionDoesNotRetainOrphanedToolTurns() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "history_echo", argumentsJSON: #"{"value":"tool-turn"}"#),
        .response(text: "tool response"),
      ]),
      tools: [HistoryEchoTool()],
      checkpointStore: checkpointStore,
      checkpointKey: "tool-turn",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "tool-turn" }
      )
    )

    _ = try await session.respond(to: "Use the tool")

    let checkpoint = try #require(await checkpointStore.loadCheckpoint(for: "tool-turn"))
    #expect(checkpoint.transcript.history.count == 1)
    #expect(checkpoint.transcript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(!checkpoint.transcript.history.contains { entry in
      if case .toolCalls = entry { return true }
      return false
    })
    #expect(!checkpoint.transcript.history.contains { entry in
      if case .toolOutput = entry { return true }
      return false
    })
  }

  @Test("Compacted checkpoints remain compatible with file-backed checkpoint persistence")
  func compactedHistoryPersistsThroughFileCheckpointStore() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "coreagent-conversation-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let checkpointStore = FileCheckpointStore(directory: directory)
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first file-backed answer"),
        .response(text: "second file-backed answer"),
      ]),
      checkpointStore: checkpointStore,
      checkpointKey: "file-backed",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "file-backed" }
      )
    )

    _ = try await session.respond(to: "first file prompt")
    _ = try await session.respond(to: "second file prompt")

    let checkpoint = try #require(try await checkpointStore.loadCheckpoint(for: "file-backed"))
    #expect(checkpoint.transcript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(checkpoint.transcript.containsText("second file-backed answer"))

    let restoredModel = RecordedLanguageModel(steps: [.response(text: "restored answer")])
    let restored = try CoreAgentSession(
      model: restoredModel,
      checkpointStore: checkpointStore,
      checkpointKey: "file-backed"
    )
    _ = try await restored.respond(to: "third file prompt")
    let restoredRequest = try #require(restoredModel.recorder.capturedTranscripts().first)
    #expect(restoredRequest.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(restoredRequest.containsText("second file-backed answer"))
  }

  @Test("Deep conversation retention rebuilds the active native session after checkpoint compaction")
  func currentSessionUsesCompactedHistoryAfterCheckpointPersistence() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let model = RecordedLanguageModel(steps: [
      .response(text: "first active answer"),
      .response(text: "second active answer"),
      .response(text: "third active answer"),
    ])
    let session = try CoreAgentSession(
      model: model,
      checkpointStore: checkpointStore,
      checkpointKey: "active",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "active" }
      )
    )

    _ = try await session.respond(to: "first active prompt")
    let secondResponse = try await session.respond(to: "second active prompt")
    #expect(secondResponse.run.events.contains { $0.kind == .transcriptActiveSessionCompacted })
    _ = try await session.respond(to: "third active prompt")

    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 3)
    let secondRequest = try #require(transcripts.dropLast().last)
    #expect(secondRequest.containsText("first active answer"))
    let thirdRequest = try #require(transcripts.last)
    #expect(thirdRequest.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(thirdRequest.containsText("second active prompt"))
    #expect(thirdRequest.containsText("second active answer"))
    #expect(thirdRequest.containsText("third active prompt"))
    #expect(!thirdRequest.containsResponseText("first active answer"))
    #expect(!thirdRequest.containsText("/conversation_history/"))
    let checkpoint = try #require(await checkpointStore.loadCheckpoint(for: "active"))
    #expect(checkpoint.transcript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
  }

  @Test("Deep conversation retention rebuilds the active streaming session after checkpoint compaction")
  func streamingSessionUsesCompactedHistoryAfterCheckpointPersistence() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let model = RecordedLanguageModel(steps: [
      .responseFragments(["first streaming answer"]),
      .responseFragments(["second streaming answer"]),
      .responseFragments(["third streaming answer"]),
    ])
    let session = try CoreAgentSession(
      model: model,
      checkpointStore: checkpointStore,
      checkpointKey: "active-streaming",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "active-streaming" }
      )
    )

    _ = try await session.respondStreaming(to: "first streaming prompt") { _ in }
    let secondResponse = try await session.respondStreaming(to: "second streaming prompt") { _ in }
    #expect(secondResponse.run.events.contains { $0.kind == .transcriptActiveSessionCompacted })
    _ = try await session.respondStreaming(to: "third streaming prompt") { _ in }

    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 3)
    let thirdRequest = try #require(transcripts.last)
    #expect(thirdRequest.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(thirdRequest.containsText("second streaming prompt"))
    #expect(thirdRequest.containsText("second streaming answer"))
    #expect(thirdRequest.containsText("third streaming prompt"))
    #expect(!thirdRequest.containsResponseText("first streaming answer"))
    #expect(!thirdRequest.containsText("/conversation_history/"))
  }

  @Test("Manual checkpoint without a checkpoint store does not rebuild active session history")
  func checkpointWithoutStoreDoesNotInstallActiveCompaction() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let model = RecordedLanguageModel(steps: [
      .response(text: "first no-store answer"),
      .response(text: "second no-store answer"),
      .response(text: "third no-store answer"),
    ])
    let session = try CoreAgentSession(
      model: model,
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "no-store" }
      )
    )

    _ = try await session.respond(to: "first no-store prompt")
    _ = try await session.respond(to: "second no-store prompt")
    let checkpoint = try await session.checkpoint()
    #expect(checkpoint.transcript.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    _ = try await session.respond(to: "third no-store prompt")

    let thirdRequest = try #require(model.recorder.capturedTranscripts().last)
    #expect(!thirdRequest.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(thirdRequest.containsResponseText("first no-store answer"))
  }

  @Test("Plugin completion failure does not install active conversation compaction")
  func pluginCompletionFailureDoesNotInstallActiveCompaction() async throws {
    let checkpointStore = InMemoryCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let model = RecordedLanguageModel(steps: [
      .response(text: "first plugin answer"),
      .response(text: "second plugin answer"),
      .response(text: "third plugin answer"),
    ])
    let controller = CompletionFailureController(failingCompletionNumbers: [2])
    let session = try CoreAgentSession(
      model: model,
      checkpointStore: checkpointStore,
      checkpointKey: "plugin-failure",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "plugin-failure" }
      ),
      plugins: [CompletionFailingPlugin(controller: controller)]
    )

    _ = try await session.respond(to: "first plugin prompt")
    await #expect(throws: CompletionFailureError.self) {
      _ = try await session.respond(to: "second plugin prompt")
    }
    let failedRun = try #require(await session.lastRun())
    #expect(!failedRun.events.contains { $0.kind == .transcriptActiveSessionCompacted })
    _ = try await session.respond(to: "third plugin prompt")

    let thirdRequest = try #require(model.recorder.capturedTranscripts().last)
    #expect(!thirdRequest.containsText("COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1"))
    #expect(thirdRequest.containsResponseText("first plugin answer"))
  }

  @Test("Rollback after checkpoint save failure preserves a previously committed artifact")
  func checkpointFailureRollbackPreservesExistingCommittedArtifact() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(
      filesystem: filesystem,
      configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2)
    )
    let transcript = Transcript(entries: [
      prompt("first shared prompt"),
      response("first shared answer"),
      prompt("second shared prompt"),
      response("second shared answer"),
    ])
    let committed = try await compactor.prepareForCheckpoint(
      transcript: transcript,
      scopeID: "shared-artifact"
    )
    try await committed.finalize()
    let snapshotBeforeFailure = await filesystem.snapshot()
    let committedPath = try #require(snapshotBeforeFailure.keys.first)
    let committedContents = try #require(snapshotBeforeFailure[committedPath])

    let failedAttempt = try await compactor.prepareForCheckpoint(
      transcript: transcript,
      scopeID: "shared-artifact"
    )
    try await failedAttempt.finalize()
    await failedAttempt.rollback()

    let snapshotAfterFailure = await filesystem.snapshot()
    #expect(snapshotAfterFailure[committedPath] == committedContents)
  }

  @Test("Removing checkpoint artifacts ignores paths outside the conversation-history namespace")
  func artifactRemovalIgnoresInvalidConversationHistoryPaths() async throws {
    let filesystem = CoreAgentDeepStateFilesystem(
      files: ["/unrelated/file.txt": "keep"],
      permissions: [.allow(operations: [.delete], paths: ["/**"])]
    )
    let compactor = CoreAgentDeepConversationHistoryCompactor(filesystem: filesystem)
    let artifact = CoreAgentCheckpointArtifact(
      id: "conversation-history-forged",
      kind: CoreAgentDeepConversationHistoryCompactor.checkpointArtifactKind,
      path: "/unrelated/file.txt",
      digest: String(repeating: "a", count: 64)
    )

    try await compactor.removeCheckpointArtifacts([artifact])

    #expect(await filesystem.snapshot()["/unrelated/file.txt"] == "keep")
  }

  @Test("Checkpoint removal failure leaves conversation-history artifacts intact")
  func resetRemovalFailureLeavesArtifactsIntact() async throws {
    let checkpointStore = RemoveFailingCheckpointStore()
    let filesystem = CoreAgentDeepStateFilesystem(
      permissions: [.allow(operations: [.write, .delete], paths: ["/conversation_history/**"])]
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "first reset answer"),
        .response(text: "second reset answer"),
      ]),
      checkpointStore: checkpointStore,
      checkpointKey: "reset-failure",
      transcriptRetention: .deepConversationHistory(
        filesystem: filesystem,
        configuration: .init(maximumInlineHistoryEntries: 2, retainedHistoryEntries: 2),
        scopeID: { "reset-failure" }
      )
    )

    _ = try await session.respond(to: "first reset prompt")
    _ = try await session.respond(to: "second reset prompt")
    let path = try #require(await filesystem.snapshot().keys.first)

    await #expect(throws: RemoveFailingCheckpointStore.Error.self) {
      try await session.reset(removingCheckpoint: true)
    }

    #expect(await filesystem.snapshot()[path] != nil)
    #expect(try await checkpointStore.loadCheckpoint(for: "reset-failure") != nil)
  }
}

private func prompt(_ content: String) -> Transcript.Entry {
  .prompt(.init(segments: [.text(.init(content: content))]))
}

private func response(_ content: String) -> Transcript.Entry {
  .response(.init(segments: [.text(.init(content: content))]))
}

private func reasoning(_ content: String) -> Transcript.Entry {
  .reasoning(.init(segments: [.text(.init(content: content))]))
}

@Generable
private struct HistoryEchoArguments: Sendable {
  let value: String
}

private struct HistoryEchoTool: Tool {
  let name = "history_echo"
  let description = "Returns the supplied value."

  @concurrent
  func call(arguments: HistoryEchoArguments) async throws -> String {
    arguments.value
  }
}

private enum ThrowingCheckpointStoreError: Error {
  case saveFailed
}

private actor ThrowingCheckpointStore: CoreAgentCheckpointStore {
  func loadCheckpoint(for key: String) throws -> CoreAgentCheckpoint? {
    nil
  }

  func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) throws {
    throw ThrowingCheckpointStoreError.saveFailed
  }

  func removeCheckpoint(for key: String) throws {}
}

private actor RemoveFailingCheckpointStore: CoreAgentCheckpointStore {
  enum Error: Swift.Error {
    case removeFailed
  }

  private var checkpoints: [String: CoreAgentCheckpoint] = [:]

  func loadCheckpoint(for key: String) throws -> CoreAgentCheckpoint? {
    checkpoints[key]
  }

  func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) throws {
    checkpoints[key] = checkpoint
  }

  func removeCheckpoint(for key: String) throws {
    throw Error.removeFailed
  }
}

private enum CompletionFailureError: Error {
  case completionFailed
}

private actor CompletionFailureController {
  private let failingCompletionNumbers: Set<Int>
  private var completionCount = 0

  init(failingCompletionNumbers: Set<Int>) {
    self.failingCompletionNumbers = failingCompletionNumbers
  }

  func shouldFailCompletion() -> Bool {
    completionCount += 1
    return failingCompletionNumbers.contains(completionCount)
  }
}

private struct CompletionFailingPlugin: CoreAgentSessionPlugin {
  let identifier = "completion.failing"
  let controller: CompletionFailureController
  let failurePolicies = CoreAgentPluginFailurePolicies(completion: .failRun)

  func didComplete(_ completion: CoreAgentPluginCompletion) async throws -> [CoreAgentPluginEvent] {
    if await controller.shouldFailCompletion() {
      throw CompletionFailureError.completionFailed
    }
    return []
  }
}

private extension CoreAgentDeepConversationHistoryCompactionDecision {
  var compaction: CoreAgentDeepConversationHistoryCompaction? {
    guard case .compacted(let compaction) = self else { return nil }
    return compaction
  }
}

private extension Transcript {
  func containsText(_ expected: String) -> Bool {
    contains { entry in
      switch entry {
      case .instructions(let instructions):
        instructions.segments.containsText(expected)
      case .prompt(let prompt):
        prompt.segments.containsText(expected)
      case .toolOutput(let output):
        output.segments.containsText(expected)
      case .response(let response):
        response.segments.containsText(expected)
      case .reasoning(let reasoning):
        reasoning.segments.containsText(expected)
      case .toolCalls(let calls):
        calls.contains { $0.arguments.jsonString.contains(expected) }
      @unknown default:
        false
      }
    }
  }

  func containsResponseText(_ expected: String) -> Bool {
    contains { entry in
      guard case .response(let response) = entry else { return false }
      return response.segments.containsText(expected)
    }
  }
}

private extension [Transcript.Segment] {
  func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}
