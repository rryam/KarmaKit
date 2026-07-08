import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph compile validation")
struct CoreAgentGraphCompileTests {
  struct State: Sendable, Equatable {
    var value = ""
  }

  @Test("Rejects duplicate node identifiers")
  func rejectsDuplicateNodes() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("planner") { state, _ in state }

    #expect(throws: CoreAgentGraphCompileError.duplicateNode("planner")) {
      try graph.addNode("planner") { state, _ in state }
    }
  }

  @Test("Rejects graphs without an entry edge")
  func rejectsMissingEntryPoint() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("planner") { state, _ in state }
    try graph.addEdge(.node("planner"), .end)

    #expect(throws: CoreAgentGraphCompileError.missingEntryPoint) {
      _ = try graph.compile()
    }
  }

  @Test("Rejects orphaned nodes")
  func rejectsOrphanedNodes() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("planner") { state, _ in state }
    try graph.addNode("unused") { state, _ in state }
    try graph.addEdge(.start, .node("planner"))
    try graph.addEdge(.node("planner"), .end)

    #expect(throws: CoreAgentGraphCompileError.orphanedNode("unused")) {
      _ = try graph.compile()
    }
  }

  @Test("Rejects edges to missing nodes")
  func rejectsMissingEdgeTarget() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("planner") { state, _ in state }
    try graph.addEdge(.start, .node("planner"))
    try graph.addEdge(.node("planner"), .node("missing"))

    #expect(throws: CoreAgentGraphCompileError.unknownEdgeTarget("missing")) {
      _ = try graph.compile()
    }
  }

  @Test("Rejects conditional routes to missing nodes")
  func rejectsMissingConditionalTarget() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in state }
    try graph.addNode("known") { state, _ in state }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(from: "router", routes: ["known": "known", "bad": "missing"])
    try graph.addEdge(.node("known"), .end)

    #expect(
      throws: CoreAgentGraphCompileError.unknownConditionalTarget(
        source: "router",
        route: "bad",
        target: "missing"
      )
    ) {
      _ = try graph.compile()
    }
  }

  @Test("Rejects selectorless conditional routes with valid targets")
  func rejectsSelectorlessConditionalRoutes() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in state }
    try graph.addNode("known") { state, _ in state }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(from: "router", routes: ["known": "known"])
    try graph.addEdge(.node("known"), .end)

    #expect(throws: CoreAgentGraphCompileError.missingConditionalSelector(source: "router")) {
      _ = try graph.compile()
    }
  }

  @Test("Rejects invalid recursion limits")
  func rejectsInvalidRecursionLimit() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("planner") { state, _ in state }
    try graph.addEdge(.start, .node("planner"))
    try graph.addEdge(.node("planner"), .end)

    #expect(throws: CoreAgentGraphCompileError.invalidRecursionLimit(0)) {
      _ = try graph.compile(configuration: .init(recursionLimit: 0))
    }
  }
}
