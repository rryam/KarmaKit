import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph subgraphs")
struct CoreAgentGraphSubgraphTests {
  struct State: Codable, Equatable, Sendable {
    var log: [String] = []
    var value = 0
  }

  @Test("Compiled graph runs as a node")
  func compiledGraphRunsAsNode() async throws {
    let child = try makeChildGraph().compile()
    var parent = CoreAgentStateGraph<State>()
    try parent.addSubgraph("subflow", child)
    try parent.addNode("after") { state, _ in
      var next = state
      next.log.append("after")
      next.value += 3
      return next
    }
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("subflow"), .node("after"))
    try parent.addEdge(.node("after"), .end)

    let result = try await parent.compile().invoke(State(log: ["seed"], value: 2))

    #expect(result.log == ["seed", "child-a", "child-b", "after"])
    #expect(result.value == 9)
  }

  @Test("Subgraph checkpoints are namespaced")
  func subgraphCheckpointsAreNamespaced() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let child = try makeChildGraph().compile(checkpointer: checkpointer)
    var parent = CoreAgentStateGraph<State>()
    try parent.addSubgraph("subflow", child)
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("subflow"), .end)

    let compiled = try parent.compile(checkpointer: checkpointer)
    let result = try await compiled.invoke(State(log: ["parent"], value: 1), threadID: "thread")

    let subgraphNamespace = CoreAgentGraphCheckpointNamespace.default
      .appendingSubgraphNode("subflow")
    let parentHistory = await checkpointer.history(threadID: "thread", namespace: .default)
    let childHistory = await checkpointer.history(
      threadID: "thread",
      namespace: subgraphNamespace
    )

    #expect(result.log == ["parent", "child-a", "child-b"])
    #expect(subgraphNamespace != .default)
    #expect(subgraphNamespace.rawValue.contains("subflow"))
    #expect(parentHistory.map(\.namespace) == [.default, .default])
    #expect(parentHistory.map(\.step) == [1, 0])
    #expect(
      childHistory.map(\.namespace) == [
        subgraphNamespace,
        subgraphNamespace,
        subgraphNamespace,
      ])
    #expect(childHistory.map(\.step) == [2, 1, 0])
    #expect(childHistory.first?.state.log == ["parent", "child-a", "child-b"])
  }

  @Test("Subgraph stream events surface to parent")
  func subgraphStreamEventsSurfaceToParent() async throws {
    let child = try makeChildGraph().compile()
    var parent = CoreAgentStateGraph<State>()
    try parent.addSubgraph("subflow", child)
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("subflow"), .end)

    let events = try await collect(try parent.compile().stream(State()))
    let subgraphNamespace = CoreAgentGraphCheckpointNamespace.default
      .appendingSubgraphNode("subflow")
    let subgraphEvents = events.compactMap {
      event -> (
        namespace: CoreAgentGraphCheckpointNamespace,
        childEvent: CoreAgentGraphStreamEvent<State>,
        parentStep: Int
      )? in
      guard case .subgraph(let namespace, let childEvent, let parentStep) = event else {
        return nil
      }
      return (namespace, childEvent, parentStep)
    }

    let started = subgraphEvents.compactMap { event -> String? in
      guard case .taskStarted(let nodeID, let childStep) = event.childEvent else {
        return nil
      }
      return "\(nodeID.rawValue):\(childStep):\(event.parentStep)"
    }
    let updates = subgraphEvents.compactMap { event -> String? in
      guard case .updates(let nodeID, _, let childStep) = event.childEvent else {
        return nil
      }
      return "\(nodeID.rawValue):\(childStep):\(event.parentStep)"
    }

    #expect(Set(subgraphEvents.map(\.namespace)) == Set([subgraphNamespace]))
    #expect(started == ["child-a:1:1", "child-b:2:1"])
    #expect(updates == ["child-a:1:1", "child-b:2:1"])
  }

  private func makeChildGraph() throws -> CoreAgentStateGraph<State> {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("child-a") { state, _ in
      var next = state
      next.log.append("child-a")
      next.value += 1
      return next
    }
    try graph.addNode("child-b") { state, _ in
      var next = state
      next.log.append("child-b")
      next.value *= 2
      return next
    }
    try graph.addEdge(.start, .node("child-a"))
    try graph.addEdge(.node("child-a"), .node("child-b"))
    try graph.addEdge(.node("child-b"), .end)
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
