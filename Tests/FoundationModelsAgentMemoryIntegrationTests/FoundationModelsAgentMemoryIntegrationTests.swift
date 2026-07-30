import Foundation
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentMemory
import FoundationModelsAgentTestSupport
import Testing

private enum FlushBarrierTestError: Error {
  case initialIndexWrite
}

@Generable
private struct LegacyMemorySearchArguments {
  let query: String
  let maximumResults: Int?
}

private struct LegacyMemorySearchTool: Tool {
  let name = ["core", "agent_search_memory"].joined()
  let description = "Returns previously stored evidence."

  @concurrent
  func call(arguments: LegacyMemorySearchArguments) async throws -> String {
    "legacy-memory-payload"
  }
}

private actor FlushBarrierIndex: FoundationModelsAgentMemoryIndex {
  private var upsertCount = 0
  private var repairStarted = false
  private var repairStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var repairRelease: CheckedContinuation<Void, Never>?

  func upsert(_ record: FoundationModelsAgentMemoryRecord) async throws {
    upsertCount += 1
    if upsertCount == 1 {
      throw FlushBarrierTestError.initialIndexWrite
    }
    guard upsertCount == 2 else { return }
    repairStarted = true
    let waiters = repairStartWaiters
    repairStartWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      repairRelease = continuation
    }
  }

  func search(
    query: String,
    in scope: FoundationModelsAgentMemoryScope,
    limit: Int
  ) -> [FoundationModelsAgentMemorySearchCandidate] {
    []
  }

  func remove(id: UUID, in scope: FoundationModelsAgentMemoryScope) {}

  func removeAll(in scope: FoundationModelsAgentMemoryScope) {}

  func waitUntilRepairStarts() async {
    guard !repairStarted else { return }
    await withCheckedContinuation { continuation in
      repairStartWaiters.append(continuation)
    }
  }

  func releaseRepair() {
    repairRelease?.resume()
    repairRelease = nil
  }
}

private actor FlushBarrierConsolidator: FoundationModelsAgentMemoryConsolidator {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func consolidate(episode: FoundationModelsAgentMemoryRecord) async
    -> [FoundationModelsAgentMemoryCandidateDraft]
  {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      release = continuation
    }
    return []
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finish() {
    release?.resume()
    release = nil
  }
}

private actor FlushCompletionProbe {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}

@Suite("FoundationModelsAgent memory native-session integration")
struct FoundationModelsAgentMemoryIntegrationTests {
  @Test("Search-tool evidence is excluded from captured episodes")
  func noMemoryOfMemoryRecursion() async throws {
    let scope = try FoundationModelsAgentMemoryScope(
      applicationID: "com.example.integration",
      userID: "user",
      agentID: "assistant"
    )
    let store = InMemoryFoundationModelsAgentMemoryStore()
    let memory = FoundationModelsAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice)
    )
    _ = try await memory.remember("unique-memory-payload", sensitivity: .general)
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "foundationmodelsagent_search_memory",
        argumentsJSON: #"{"query":"unique-memory-payload","maximumResults":1}"#
      ),
      .response(text: "done"),
    ])
    let session = try AgentSession(model: model, plugins: [memory])

    _ = try await session.respond(to: Prompt("Use the memory search tool."))

    let episodes = await store.records(in: scope).filter { $0.kind == .episode }
    let episode = try #require(episodes.first)
    #expect(!episode.content.contains("unique-memory-payload"))
    #expect(episode.content.contains("Use the memory search tool."))
    #expect(episode.content.contains("done"))
  }

  @Test("Previous search-tool evidence is excluded from captured episodes")
  func noLegacyMemoryOfMemoryRecursion() async throws {
    let scope = try FoundationModelsAgentMemoryScope(
      applicationID: "com.example.legacy-integration",
      userID: "user",
      agentID: "assistant"
    )
    let store = InMemoryFoundationModelsAgentMemoryStore()
    let memory = FoundationModelsAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice)
    )
    let legacyToolName = ["core", "agent_search_memory"].joined()
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: legacyToolName,
        argumentsJSON: #"{"query":"legacy-memory-payload","maximumResults":1}"#
      ),
      .response(text: "done"),
    ])
    let session = try AgentSession(
      model: model,
      tools: [LegacyMemorySearchTool()],
      plugins: [memory]
    )

    _ = try await session.respond(to: Prompt("Use the previous memory search tool."))

    let episodes = await store.records(in: scope).filter { $0.kind == .episode }
    let episode = try #require(episodes.first)
    #expect(!episode.content.contains("legacy-memory-payload"))
    #expect(episode.content.contains("Use the previous memory search tool."))
    #expect(episode.content.contains("done"))
  }

  @Test("Flush waits for an episode enqueued while another derivative is draining")
  func flushIsAStableBarrier() async throws {
    let scope = try FoundationModelsAgentMemoryScope(
      applicationID: "com.example.flush",
      userID: "user",
      agentID: "assistant"
    )
    let index = FlushBarrierIndex()
    let consolidator = FlushBarrierConsolidator()
    let memory = FoundationModelsAgentMemoryCoordinator(
      scope: scope,
      store: InMemoryFoundationModelsAgentMemoryStore(),
      disclosurePolicy: .init(destination: .onDevice),
      index: index,
      consolidator: consolidator
    )
    _ = try await memory.remember("Seed a pending index repair.")
    await index.waitUntilRepairStarts()

    let completion = FlushCompletionProbe()
    let flushTask = Task {
      await memory.flush()
      await completion.markComplete()
    }
    try await Task.sleep(for: .milliseconds(20))

    let session = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "captured")]),
      plugins: [memory]
    )
    _ = try await session.respond(to: "Capture this episode.")
    await consolidator.waitUntilStarted()

    await index.releaseRepair()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await completion.isComplete == false)

    await consolidator.finish()
    await flushTask.value
    #expect(await completion.isComplete)
  }
}
