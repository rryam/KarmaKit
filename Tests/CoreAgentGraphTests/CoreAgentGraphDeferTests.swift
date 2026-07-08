import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph deferred nodes")
struct CoreAgentGraphDeferTests {
  struct State: Codable, Equatable, Sendable {
    var items: [String] = []
    var current: String?
    var processed: [String] = []
    var log: [String] = []
  }

  @Test("Deferred node runs after all pending tasks")
  func deferredNodeRunsAfterAllPendingTasks() async throws {
    var graph = makeAppendGraph()
    try graph.addNode("root") { _, _ in
      State(log: ["root"])
    }
    try graph.addNode("normal") { _, _ in
      State(log: ["normal"])
    }
    try graph.addNode("tail") { _, _ in
      State(log: ["tail"])
    }
    try graph.addNode("deferred", defer: true) { state, _ in
      State(log: ["deferred saw \(state.log.joined(separator: ","))"])
    }
    try graph.addEdge(.start, .node("root"))
    try graph.addEdge(.node("root"), .node("normal"))
    try graph.addEdge(.node("root"), .node("deferred"))
    try graph.addEdge(.node("normal"), .node("tail"))
    try graph.addEdge(.node("tail"), .end)
    try graph.addEdge(.node("deferred"), .end)

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["root", "normal", "tail", "deferred saw root,normal,tail"])
  }

  @Test("Deferred node participates in reachability")
  func deferredNodeParticipatesInReachability() async throws {
    var reachable = makeAppendGraph()
    try reachable.addNode("entry") { _, _ in
      State(log: ["entry"])
    }
    try reachable.addNode("deferred", defer: true) { _, _ in
      State(log: ["deferred"])
    }
    try reachable.addEdge(.start, .node("entry"))
    try reachable.addEdge(.node("entry"), .node("deferred"))
    try reachable.addEdge(.node("deferred"), .end)

    let result = try await reachable.compile().invoke(State())
    #expect(result.log == ["entry", "deferred"])

    var orphaned = makeAppendGraph()
    try orphaned.addNode("entry") { state, _ in
      state
    }
    try orphaned.addNode("orphaned", defer: true) { state, _ in
      state
    }
    try orphaned.addEdge(.start, .node("entry"))
    try orphaned.addEdge(.node("entry"), .end)

    #expect(throws: CoreAgentGraphCompileError.orphanedNode("orphaned")) {
      _ = try orphaned.compile()
    }
  }

  @Test("Deferred aggregator runs after all sends")
  func deferredAggregatorRunsAfterAllSends() async throws {
    var graph = makeAppendGraph()
    try graph.addNode("fanout") { _, _ in
      State(log: ["fanout"])
    }
    try graph.addCommandNode("worker") { state, _ in
      let item = try #require(state.current)
      return .command(
        update: State(processed: [item], log: ["worker-\(item)"]),
        goto: [.node("aggregate")],
        sends: [CoreAgentGraphSend("cleanup", state: State(current: item))]
      )
    }
    try graph.addNode("cleanup") { state, _ in
      State(log: ["cleanup-\(try #require(state.current))"])
    }
    try graph.addNode("aggregate", defer: true) { state, _ in
      State(log: ["aggregate saw \(state.processed.joined(separator: ","))"])
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { state, _ in
      state.items.map { item in
        CoreAgentGraphSend("worker", state: State(current: item))
      }
    }
    try graph.addCommandRoutes(from: "worker", to: [.node("aggregate"), .node("cleanup")])
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("cleanup"), .end)
    try graph.addEdge(.node("aggregate"), .end)

    let result = try await graph.compile().invoke(State(items: ["a", "b", "c"]))

    #expect(
      result.log == [
        "fanout",
        "worker-a",
        "worker-b",
        "worker-c",
        "cleanup-a",
        "cleanup-b",
        "cleanup-c",
        "aggregate saw a,b,c",
      ])
    #expect(result.log.filter { $0.hasPrefix("aggregate") }.count == 1)
  }

  private func makeAppendGraph() -> CoreAgentStateGraph<State> {
    CoreAgentStateGraph<State> { current, update in
      var next = current
      if !update.items.isEmpty {
        next.items = update.items
      }
      if let current = update.current {
        next.current = current
      }
      next.processed.append(contentsOf: update.processed)
      next.log.append(contentsOf: update.log)
      return next
    }
  }
}
