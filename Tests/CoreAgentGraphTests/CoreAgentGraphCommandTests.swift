import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph command and state update")
struct CoreAgentGraphCommandTests {
  struct State: Sendable, Equatable {
    var log: [String] = []
  }

  struct TransientFailure: Error, Equatable {}

  actor Attempts {
    private var counts: [String: Int] = [:]

    func record(_ nodeID: String) -> Int {
      counts[nodeID, default: 0] += 1
      return counts[nodeID, default: 0]
    }

    func count(_ nodeID: String) -> Int {
      counts[nodeID, default: 0]
    }
  }

  @Test("Graph command applies update and routes to declared target")
  func graphCommandAppliesUpdateAndRoutesToDeclaredTarget() async throws {
    var graph = makeAppendGraph()
    try graph.addCommandNode("router") { _, _ in
      .command(update: State(log: ["router"]), goto: [.node("right")])
    }
    try graph.addNode("right") { _, _ in
      State(log: ["right"])
    }
    try graph.addCommandRoutes(from: "router", to: [.node("right")])
    try graph.addEdge(.start, .node("router"))
    try graph.addEdge(.node("right"), .end)

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["router", "right"])
  }

  @Test("Graph command goto end bypasses regular edge")
  func graphCommandGotoEndBypassesRegularEdge() async throws {
    var graph = makeAppendGraph()
    try graph.addCommandNode("router") { _, _ in
      .command(update: State(log: ["router"]), goto: [.end])
    }
    try graph.addNode("should-not-run") { _, _ in
      State(log: ["should-not-run"])
    }
    try graph.addCommandRoutes(from: "router", to: [.end])
    try graph.addEdge(.start, .node("router"))
    try graph.addEdge(.node("router"), .node("should-not-run"))
    try graph.addEdge(.node("should-not-run"), .end)

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["router"])
  }

  @Test("Graph command rejects undeclared goto target")
  func graphCommandRejectsUndeclaredGotoTarget() async throws {
    var graph = makeAppendGraph()
    try graph.addCommandNode("router") { _, _ in
      .command(update: State(log: ["router"]), goto: [.node("right")])
    }
    try graph.addNode("right") { _, _ in
      State(log: ["right"])
    }
    try graph.addEdge(.start, .node("router"))
    try graph.addEdge(.node("router"), .node("right"))
    try graph.addEdge(.node("right"), .end)
    let compiled = try graph.compile()

    await #expect(
      throws: CoreAgentGraphRuntimeError.undeclaredCommandTarget(
        source: "router",
        target: .node("right")
      )
    ) {
      _ = try await compiled.invoke(State())
    }
  }

  @Test("Graph command pending writes preserve goto after parallel failure")
  func graphCommandPendingWritesPreserveGotoAfterParallelFailure() async throws {
    let attempts = Attempts()
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    var graph = makeAppendGraph()
    try graph.addCommandNode("a-command") { _, _ in
      _ = await attempts.record("a-command")
      return .command(update: State(log: ["a-command"]), goto: [.node("after-command")])
    }
    try graph.addNode("after-command") { _, _ in
      State(log: ["after-command"])
    }
    try graph.addNode("z-fail") { _, _ in
      let attempt = await attempts.record("z-fail")
      if attempt == 1 {
        throw TransientFailure()
      }
      return State(log: ["z-fail"])
    }
    try graph.addCommandRoutes(from: "a-command", to: [.node("after-command")])
    try graph.addEdge(.start, .node("a-command"))
    try graph.addEdge(.start, .node("z-fail"))
    try graph.addEdge(.node("after-command"), .end)
    try graph.addEdge(.node("z-fail"), .end)
    let compiled = try graph.compile(checkpointer: checkpointer)

    do {
      _ = try await compiled.invoke(State(), threadID: "thread")
      Issue.record("Expected first run to throw the transient failure")
    } catch {
      #expect(error is TransientFailure)
    }

    let failureCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(failureCheckpoint.nextNodeIDs == ["z-fail"])
    #expect(failureCheckpoint.pendingWrites.first?.commandGoto == [.node("after-command")])

    let result = try await compiled.invoke(
      State(), threadID: "thread", checkpointID: failureCheckpoint.id)

    #expect(result.log == ["a-command", "after-command", "z-fail"])
    #expect(await attempts.count("a-command") == 1)
    #expect(await attempts.count("z-fail") == 2)
  }

  @Test("Graph command streams command and typed update evidence")
  func graphCommandStreamsCommandAndUpdateEvidence() async throws {
    var graph = makeAppendGraph()
    try graph.addCommandNode("router") { _, _ in
      .command(update: State(log: ["router"]), goto: [.node("right")])
    }
    try graph.addNode("right") { _, _ in
      State(log: ["right"])
    }
    try graph.addCommandRoutes(from: "router", to: [.node("right")])
    try graph.addEdge(.start, .node("router"))
    try graph.addEdge(.node("right"), .end)

    let events = try await collect(try graph.compile().stream(State()))

    #expect(events.contains(.command(nodeID: "router", goto: [.node("right")], step: 1)))
    #expect(events.contains(.updates(nodeID: "router", update: State(log: ["router"]), step: 1)))
  }

  @Test("Update state saves child checkpoint and routes as node output")
  func graphCommandUpdateStateSavesChildCheckpointAndRoutes() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let compiled = try makeLinearAppendGraph().compile(checkpointer: checkpointer)
    _ = try await compiled.invoke(State(), threadID: "thread")
    let latest = try #require(await checkpointer.latest(threadID: "thread"))

    let patched = try await compiled.updateState(
      State(log: ["manual"]),
      asNode: "a",
      threadID: "thread"
    )

    #expect(patched.parentCheckpointID == latest.id)
    #expect(patched.step == latest.step + 1)
    #expect(patched.state.log == ["a", "b", "manual"])
    #expect(patched.nextNodeIDs == ["b"])

    let resumed = try await compiled.invoke(State(), threadID: "thread", checkpointID: patched.id)
    #expect(resumed.log == ["a", "b", "manual", "b"])
  }

  @Test("Bulk update state applies supersteps in order")
  func graphCommandBulkUpdateStateAppliesSuperstepsInOrder() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let compiled = try makeThreeNodeAppendGraph().compile(checkpointer: checkpointer)
    _ = try await compiled.invoke(State(), threadID: "thread")
    let latest = try #require(await checkpointer.latest(threadID: "thread"))

    let patched = try await compiled.bulkUpdateState(
      [
        [CoreAgentGraphStateUpdate(update: State(log: ["manual-a"]), asNode: "a")],
        [CoreAgentGraphStateUpdate(update: State(log: ["manual-b"]), asNode: "b")],
      ],
      threadID: "thread"
    )

    #expect(patched.parentCheckpointID != latest.id)
    #expect(patched.step == latest.step + 2)
    #expect(patched.state.log == ["a", "b", "c", "manual-a", "manual-b"])
    #expect(patched.nextNodeIDs == ["c"])

    let history = await checkpointer.history(threadID: "thread")
    #expect(
      history.prefix(2).map(\.state.log) == [patched.state.log, ["a", "b", "c", "manual-a"]])
  }

  @Test("State update requires checkpointer and existing checkpoint")
  func graphCommandStateUpdateRequiresCheckpointerAndExistingCheckpoint() async throws {
    let noCheckpointer = try makeLinearAppendGraph().compile()
    await #expect(throws: CoreAgentGraphRuntimeError.stateUpdateRequiresCheckpointer) {
      _ = try await noCheckpointer.updateState(State(log: ["manual"]), asNode: "a")
    }

    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let noCheckpoint = try makeLinearAppendGraph().compile(checkpointer: checkpointer)
    await #expect(throws: CoreAgentGraphRuntimeError.stateUpdateRequiresCheckpoint) {
      _ = try await noCheckpoint.updateState(State(log: ["manual"]), asNode: "a")
    }
  }

  private func makeAppendGraph() -> CoreAgentStateGraph<State> {
    CoreAgentStateGraph<State> { current, update in
      var next = current
      next.log.append(contentsOf: update.log)
      return next
    }
  }

  private func makeLinearAppendGraph() throws -> CoreAgentStateGraph<State> {
    var graph = makeAppendGraph()
    try graph.addNode("a") { _, _ in State(log: ["a"]) }
    try graph.addNode("b") { _, _ in State(log: ["b"]) }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .node("b"))
    try graph.addEdge(.node("b"), .end)
    return graph
  }

  private func makeThreeNodeAppendGraph() throws -> CoreAgentStateGraph<State> {
    var graph = try makeLinearAppendGraph()
    try graph.addNode("c") { _, _ in State(log: ["c"]) }
    try graph.addEdge(.node("b"), .node("c"))
    try graph.addEdge(.node("c"), .end)
    return graph
  }

  private func collect(
    _ stream: AsyncThrowingStream<CoreAgentGraphStreamEvent<State>, any Error>
  ) async throws -> [CoreAgentGraphStreamEvent<State>] {
    var events: [CoreAgentGraphStreamEvent<State>] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }
}
