import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph checkpoints")
struct CoreAgentGraphCheckpointTests {
  struct State: Sendable, Equatable {
    var log: [String] = []
  }

  @Test("Saves latest checkpoints and lists state history with parent lineage")
  func savesLatestAndHistory() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let graph = try makeLinearGraph().compile(checkpointer: checkpointer)

    let result = try await graph.invoke(State(), threadID: "thread-1")

    #expect(result.log == ["a", "b"])
    let latest = try #require(await checkpointer.latest(threadID: "thread-1"))
    #expect(latest.state.log == ["a", "b"])
    #expect(latest.parentCheckpointID != nil)

    let history = await checkpointer.history(threadID: "thread-1")
    #expect(history.map(\.step) == [2, 1, 0])
    #expect(history[0].parentCheckpointID == history[1].id)
    #expect(history[1].parentCheckpointID == history[2].id)
    #expect(history[2].parentCheckpointID == nil)
  }

  @Test("Resumes from a specific checkpoint ID")
  func resumesFromSpecificCheckpoint() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let graph = try makeLinearGraph().compile(checkpointer: checkpointer)
    _ = try await graph.invoke(State(), threadID: "thread-1")
    let afterFirstStep = try #require(
      await checkpointer.history(threadID: "thread-1").first { $0.step == 1 }
    )

    let result = try await graph.invoke(
      State(log: ["ignored"]),
      threadID: "thread-1",
      checkpointID: afterFirstStep.id
    )

    #expect(result.log == ["a", "b"])
  }

  @Test("Forks checkpoint lineage into a new thread without overwriting the parent")
  func forksCheckpointLineage() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let graph = try makeLinearGraph().compile(checkpointer: checkpointer)
    _ = try await graph.invoke(State(), threadID: "parent")
    let parentStepOne = try #require(
      await checkpointer.history(threadID: "parent").first { $0.step == 1 }
    )

    _ = try await graph.invoke(
      State(),
      threadID: "child",
      checkpointID: parentStepOne.id
    )

    let parentHistory = await checkpointer.history(threadID: "parent")
    let childHistory = await checkpointer.history(threadID: "child")
    #expect(parentHistory.map(\.step) == [2, 1, 0])
    #expect(childHistory.map(\.step) == [2])
    #expect(childHistory.first?.parentCheckpointID == parentStepOne.id)
  }

  @Test("Isolates checkpoints by namespace")
  func isolatesCheckpointsByNamespace() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let graph = try makeLinearGraph().compile(checkpointer: checkpointer)

    _ = try await graph.invoke(State(), threadID: "thread", namespace: "alpha")
    _ = try await graph.invoke(State(log: ["seed"]), threadID: "thread", namespace: "beta")

    let alpha = try #require(await checkpointer.latest(threadID: "thread", namespace: "alpha"))
    let beta = try #require(await checkpointer.latest(threadID: "thread", namespace: "beta"))
    #expect(alpha.state.log == ["a", "b"])
    #expect(beta.state.log == ["seed", "a", "b"])
  }

  @Test("Keeps duplicate checkpoint IDs isolated by thread and namespace")
  func keepsDuplicateCheckpointIDsScopedInHistory() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let checkpointID = CoreAgentGraphCheckpointID("shared-id")

    await checkpointer.save(
      CoreAgentGraphCheckpoint(
        id: checkpointID,
        threadID: "thread",
        namespace: "alpha",
        step: 1,
        state: State(log: ["alpha"]),
        nextNodeIDs: []
      )
    )
    await checkpointer.save(
      CoreAgentGraphCheckpoint(
        id: checkpointID,
        threadID: "thread",
        namespace: "beta",
        step: 1,
        state: State(log: ["beta"]),
        nextNodeIDs: []
      )
    )

    let alpha = try #require(await checkpointer.latest(threadID: "thread", namespace: "alpha"))
    let beta = try #require(await checkpointer.latest(threadID: "thread", namespace: "beta"))

    #expect(alpha.id == checkpointID)
    #expect(beta.id == checkpointID)
    #expect(alpha.state.log == ["alpha"])
    #expect(beta.state.log == ["beta"])
  }

  @Test("Resuming from a limit checkpoint throws a typed recursion error")
  func resumesPastRecursionLimitWithTypedError() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("loop") { state, _ in
      var next = state
      next.log.append("loop")
      return next
    }
    try graph.addEdge(.start, .node("loop"))
    try graph.addEdge(.node("loop"), .node("loop"))
    let compiled = try graph.compile(
      configuration: CoreAgentGraphConfiguration(recursionLimit: 1),
      checkpointer: checkpointer
    )

    await #expect(throws: CoreAgentGraphRuntimeError.recursionLimitExceeded(limit: 1)) {
      _ = try await compiled.invoke(State(), threadID: "thread")
    }
    let limitCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(limitCheckpoint.step == 1)
    #expect(limitCheckpoint.nextNodeIDs == ["loop"])

    await #expect(throws: CoreAgentGraphRuntimeError.recursionLimitExceeded(limit: 1)) {
      _ = try await compiled.invoke(
        State(log: ["ignored"]),
        threadID: "thread",
        checkpointID: limitCheckpoint.id
      )
    }
  }

  @Test("Streams checkpoint events when a checkpointer is attached")
  func streamsCheckpointEvents() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let graph = try makeLinearGraph().compile(checkpointer: checkpointer)

    var checkpointIDs: [CoreAgentGraphCheckpointID] = []
    for try await event in graph.stream(State(), threadID: "thread") {
      if case .checkpoint(let checkpoint) = event {
        checkpointIDs.append(checkpoint.id)
      }
    }

    #expect(checkpointIDs.count == 3)
    #expect(await checkpointer.history(threadID: "thread").map(\.id) == checkpointIDs.reversed())
  }

  private func makeLinearGraph() throws -> CoreAgentStateGraph<State> {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("a") { state, _ in
      var next = state
      next.log.append("a")
      return next
    }
    try graph.addNode("b") { state, _ in
      var next = state
      next.log.append("b")
      return next
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .node("b"))
    try graph.addEdge(.node("b"), .end)
    return graph
  }
}
