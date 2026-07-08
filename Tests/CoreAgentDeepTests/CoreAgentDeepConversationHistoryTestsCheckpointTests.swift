import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentDeepConversationHistoryTests {
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
