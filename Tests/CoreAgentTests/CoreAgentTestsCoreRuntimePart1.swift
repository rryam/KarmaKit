import CoreAgent
import CoreAgentTestSupport
import CoreGraphics
import Foundation
import FoundationModels
import Testing

extension CoreAgentTests {
  @Test("Recreates a dynamic profile and restores only its native history")
  func dynamicProfileRestore() async throws {
    let store = InMemoryCheckpointStore()
    let firstModel = RecordedLanguageModel(steps: [.response(text: "first")])
    let first = try CoreAgentSession(
      checkpointCompatibilityID: "assistant-profile-v1",
      model: firstModel,
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile(instructions: "Old profile instructions.")
    }
    _ = try await first.respond(to: "One")

    let secondModel = RecordedLanguageModel(steps: [.response(text: "second")])
    let second = try CoreAgentSession(
      checkpointCompatibilityID: "assistant-profile-v1",
      model: secondModel,
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile(instructions: "New profile instructions.")
    }
    _ = try await second.respond(to: "Two")

    let restored = try #require(secondModel.recorder.capturedTranscripts().first)
    #expect(restored.history.count >= 3)
    let instructionText = restored.compactMap { entry -> String? in
      guard case .instructions(let instructions) = entry else { return nil }
      return instructions.segments.compactMap { segment in
        guard case .text(let text) = segment else { return nil }
        return text.content
      }.joined(separator: " ")
    }.joined(separator: " ")
    #expect(instructionText.contains("New profile instructions."))
    #expect(!instructionText.contains("Old profile instructions."))

    let incompatible = try CoreAgentSession(
      checkpointCompatibilityID: "assistant-profile-v2",
      model: RecordedLanguageModel(steps: [.response(text: "unused")]),
      checkpointStore: store,
      checkpointKey: "dynamic-profile"
    ) {
      TestDynamicProfile()
    }
    await #expect(throws: CoreAgentError.self) {
      _ = try await incompatible.respond(to: "Mismatch")
    }
  }

  @Test("Creates fresh non-Sendable profile state when rebuilding on reset")
  func dynamicProfileSendingFactory() async throws {
    let counter = ProfileFactoryCounter()
    let model = RecordedLanguageModel(steps: [])
    let session = try CoreAgentSession(
      checkpointCompatibilityID: "stateful-profile-v1",
      model: model
    ) {
      counter.increment()
      return NonSendableStateProfile(
        state: NonSendableProfileState(instructions: "Stateful profile instructions."))
    }

    _ = try await session.transcript()
    try await session.reset()

    #expect(counter.count == 2)
  }

  @Test("Rejects retries for an opaque dynamic profile")
  func dynamicProfileRetrySafety() throws {
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }

    #expect(throws: CoreAgentError.self) {
      _ = try CoreAgentSession(
        checkpointCompatibilityID: "profile-v1",
        model: RecordedLanguageModel(steps: [.response(text: "unused")]),
        configuration: .init(
          retryPolicy: retry,
          allowsRetryAfterToolInvocation: true
        )
      ) {
        TestDynamicProfile()
      }
    }
  }

  @Test("Audits a profile-owned tool even when the model continuation fails")
  func dynamicProfileFailedToolAudit() async throws {
    let counter = InvocationCounter()
    let model = RecordedLanguageModel(steps: [
      .toolCall(name: "echo", argumentsJSON: #"{"value":"side-effect"}"#),
      .failure("continuation failed"),
    ])
    let echoTool = EchoTool(counter: counter)
    let session = try CoreAgentSession(
      checkpointCompatibilityID: "tool-profile-v1",
      model: model,
      scriptedTools: [echoTool]
    ) {
      TestToolDynamicProfile(tool: echoTool)
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .nativeToolCallRecorded })
    #expect(run.events.contains { $0.kind == .nativeToolOutputRecorded })
    #expect(run.events.last?.kind == .runFailed)
  }

  @Test("Marks profile tool audit as best effort when an inner hook hides its output")
  func dynamicProfileLifecycleAuditBoundary() async throws {
    let counter = InvocationCounter()
    let echoTool = EchoTool(counter: counter)
    let session = try CoreAgentSession(
      checkpointCompatibilityID: "throwing-hook-profile-v1",
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "echo", argumentsJSON: #"{"value":"side-effect"}"#)
      ]),
      scriptedTools: [echoTool],
      scriptedSuppressProfileToolOutputAudit: true
    ) {
      ThrowingLifecycleDynamicProfile(tool: echoTool)
    }

    await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Use echo")
    }

    #expect(await counter.count == 1)
    let run = try #require(await session.lastRun())
    #expect(run.events.contains { $0.kind == .profileToolAuditBestEffort })
    #expect(run.events.contains { $0.kind == .nativeToolCallRecorded })
    #expect(!run.events.contains { $0.kind == .nativeToolOutputRecorded })
  }

  @Test("Applies bounded transcript retention only to persisted history")
  func transcriptRetention() async throws {
    let store = InMemoryCheckpointStore()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "one"),
        .response(text: "two"),
      ]),
      instructions: Instructions("Retain me."),
      checkpointStore: store,
      checkpointKey: "bounded",
      transcriptRetention: .latestHistoryEntries(2)
    )

    _ = try await session.respond(to: "First")
    _ = try await session.respond(to: "Second")

    let checkpoint = try #require(await store.loadCheckpoint(for: "bounded"))
    #expect(checkpoint.transcript.history.count == 2)
    #expect(
      checkpoint.transcript.contains { entry in
        if case .instructions = entry { return true }
        return false
      })
    #expect(try await session.transcript().history.count > 2)
  }

  @Test("Never truncates persisted history into an orphaned tool turn")
  func transcriptRetentionKeepsTurnBoundaries() async throws {
    let store = InMemoryCheckpointStore()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .toolCall(name: "echo", argumentsJSON: #"{"value":"turn"}"#),
        .response(text: "done"),
      ]),
      tools: [EchoTool(counter: InvocationCounter())],
      checkpointStore: store,
      checkpointKey: "tool-turn",
      transcriptRetention: .latestHistoryEntries(2)
    )

    _ = try await session.respond(to: "Use echo")

    let checkpoint = try #require(await store.loadCheckpoint(for: "tool-turn"))
    #expect(checkpoint.transcript.history.isEmpty)
  }

}
