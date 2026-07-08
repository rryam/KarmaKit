import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph parent command routing")
struct CoreAgentGraphParentCommandTests {
  struct State: Codable, Equatable, Sendable {
    var log: [String] = []
  }

  @Test("Command routes to parent graph node")
  func commandRoutesToParentGraphNode() async throws {
    let child = try makeParentCommandChild(update: ["child-update"], target: "parent-target")
      .compile()
    var parent = makeAppendGraph()
    try parent.addSubgraph("subflow", child)
    try parent.addNode("parent-target") { state, _ in
      State(log: ["parent-target saw \(state.log.joined(separator: ","))"])
    }
    try parent.addCommandRoutes(from: "subflow", to: [.node("parent-target")])
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("parent-target"), .end)

    let result = try await parent.compile().invoke(State())

    #expect(result.log == ["child-update", "parent-target saw child-update"])
  }

  @Test("Parent command rejects undeclared target")
  func parentCommandRejectsUndeclaredTarget() async throws {
    let child = try makeParentCommandChild(update: ["child-update"], target: "parent-target")
      .compile()
    var parent = makeAppendGraph()
    try parent.addSubgraph("subflow", child)
    try parent.addNode("parent-target") { _, _ in
      State(log: ["should-not-run"])
    }
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("subflow"), .node("parent-target"))
    try parent.addEdge(.node("parent-target"), .end)
    let compiled = try parent.compile()

    await #expect(
      throws: CoreAgentGraphRuntimeError.undeclaredParentCommandTarget(
        source: "subflow",
        target: .node("parent-target")
      )
    ) {
      _ = try await compiled.invoke(State())
    }
  }

  @Test("Parent command update merges via parent reducer")
  func parentCommandUpdateMergesViaParentReducer() async throws {
    var child = CoreAgentStateGraph<State> { current, update in
      State(log: current.log + update.log.map { "child:\($0)" })
    }
    try child.addCommandNode("child-router") { _, _ in
      .command(update: State(log: ["route-update"]), goto: [.parent(.node("after"))])
    }
    try child.addEdge(.start, .node("child-router"))
    let compiledChild = try child.compile()

    var parent = CoreAgentStateGraph<State> { current, update in
      State(log: current.log + update.log.map { "parent:\($0)" })
    }
    try parent.addSubgraph("subflow", compiledChild)
    try parent.addNode("after") { state, _ in
      State(log: ["after saw \(state.log.joined(separator: ","))"])
    }
    try parent.addCommandRoutes(from: "subflow", to: [.node("after")])
    try parent.addEdge(.start, .node("subflow"))
    try parent.addEdge(.node("after"), .end)

    let result = try await parent.compile().invoke(State())

    #expect(
      result.log == [
        "parent:route-update",
        "parent:after saw parent:route-update",
      ])
  }

  private func makeParentCommandChild(
    update: [String],
    target: CoreAgentGraphNodeID
  ) throws -> CoreAgentStateGraph<State> {
    var graph = makeAppendGraph()
    try graph.addCommandNode("child-router") { _, _ in
      .command(update: State(log: update), goto: [.parent(.node(target))])
    }
    try graph.addEdge(.start, .node("child-router"))
    return graph
  }

  private func makeAppendGraph() -> CoreAgentStateGraph<State> {
    CoreAgentStateGraph<State> { current, update in
      State(log: current.log + update.log)
    }
  }
}
