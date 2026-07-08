import CoreAgentGraph
import Testing

actor CoreAgentGraphNodeCacheInvocationCounter {
  private var count = 0

  func increment() -> Int {
    count += 1
    return count
  }

  func value() -> Int {
    count
  }
}

@Suite("CoreAgentGraph execution")
struct CoreAgentGraphExecutionTests {
  struct State: Sendable, Equatable {
    var log: [String] = []
    var route: String = ""
  }

  @Test("Runs sequential nodes in edge order")
  func runsSequentialNodes() async throws {
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

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["a", "b"])
  }

  @Test("Applies parallel updates in canonical node order")
  func appliesParallelUpdatesDeterministically() async throws {
    var graph = CoreAgentStateGraph<State> { current, update in
      var next = current
      next.log.append(contentsOf: update.log)
      return next
    }
    try graph.addNode("b") { _, _ in
      State(log: ["b"])
    }
    try graph.addNode("a") { _, _ in
      try await Task.sleep(for: .milliseconds(20))
      return State(log: ["a"])
    }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["a", "b"])
  }

  @Test("Rejects parallel fanout without an explicit reducer")
  func rejectsParallelFanoutWithoutExplicitReducer() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("b") { _, _ in State(log: ["b"]) }
    try graph.addNode("a") { _, _ in State(log: ["a"]) }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)

    let compiled = try graph.compile()

    await #expect(
      throws: CoreAgentGraphRuntimeError.parallelUpdatesRequireReducer(["a", "b"])
    ) {
      _ = try await compiled.invoke(State())
    }
  }

  @Test("Routes conditional edges by selector output")
  func routesConditionalEdges() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in
      var next = state
      next.log.append("router")
      return next
    }
    try graph.addNode("left") { state, _ in
      var next = state
      next.log.append("left")
      return next
    }
    try graph.addNode("right") { state, _ in
      var next = state
      next.log.append("right")
      return next
    }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(
      from: "router",
      routes: ["left": .node("left"), "right": .node("right")]
    ) { state, _ in
      state.route
    }
    try graph.addEdge(.node("left"), .end)
    try graph.addEdge(.node("right"), .end)

    let result = try await graph.compile().invoke(State(route: "right"))

    #expect(result.log == ["router", "right"])
  }

  @Test("Uses conditional default route when selector output has no match")
  func usesConditionalDefaultRoute() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in state }
    try graph.addNode("fallback") { state, _ in
      var next = state
      next.log.append("fallback")
      return next
    }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(
      from: "router",
      routes: ["known": .end],
      default: .node("fallback")
    ) { state, _ in
      state.route
    }
    try graph.addEdge(.node("fallback"), .end)

    let result = try await graph.compile().invoke(State(route: "unknown"))

    #expect(result.log == ["fallback"])
  }

  @Test("Allows conditional routes to end execution")
  func routesConditionalsToEnd() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in
      var next = state
      next.log.append("router")
      return next
    }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(from: "router", routes: ["done": .end]) { state, _ in
      state.route
    }

    let result = try await graph.compile().invoke(State(route: "done"))

    #expect(result.log == ["router"])
  }

  @Test("Rejects invalid conditional route outputs")
  func rejectsInvalidConditionalRouteOutput() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("router") { state, _ in state }
    try graph.addEdge(.start, .node("router"))
    try graph.addConditionalEdges(from: "router", routes: ["known": .end]) { state, _ in
      state.route
    }

    let compiled = try graph.compile()

    await #expect(
      throws: CoreAgentGraphRuntimeError.invalidConditionalRoute(
        source: "router",
        route: "unknown"
      )
    ) {
      _ = try await compiled.invoke(State(route: "unknown"))
    }
  }

  @Test("Graph node cache reuses updates for matching explicit keys")
  func graphNodeCacheReusesUpdatesForMatchingExplicitKeys() async throws {
    let cache = InMemoryCoreAgentGraphNodeCache<State>()
    let counter = CoreAgentGraphNodeCacheInvocationCounter()
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode(
      "expensive",
      cachePolicy: CoreAgentGraphCachePolicy { state, _ in
        CoreAgentGraphCacheKey(state.route)
      }
    ) { state, _ in
      let run = await counter.increment()
      var next = state
      next.log.append("run-\(run)")
      return next
    }
    try graph.addEdge(.start, .node("expensive"))
    try graph.addEdge(.node("expensive"), .end)
    let compiled = try graph.compile(cache: cache)

    let first = try await compiled.invoke(State(route: "same"))
    let second = try await compiled.invoke(State(route: "same"))

    #expect(first.log == ["run-1"])
    #expect(second.log == ["run-1"])
    #expect(await counter.value() == 1)
  }

  @Test("Graph node cache keys keep distinct inputs isolated")
  func graphNodeCacheKeysKeepDistinctInputsIsolated() async throws {
    let cache = InMemoryCoreAgentGraphNodeCache<State>()
    let counter = CoreAgentGraphNodeCacheInvocationCounter()
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode(
      "expensive",
      cachePolicy: CoreAgentGraphCachePolicy { state, _ in
        CoreAgentGraphCacheKey(state.route)
      }
    ) { state, _ in
      let run = await counter.increment()
      var next = state
      next.log.append("run-\(run)")
      return next
    }
    try graph.addEdge(.start, .node("expensive"))
    try graph.addEdge(.node("expensive"), .end)
    let compiled = try graph.compile(cache: cache)

    let first = try await compiled.invoke(State(route: "first"))
    let second = try await compiled.invoke(State(route: "second"))

    #expect(first.log == ["run-1"])
    #expect(second.log == ["run-2"])
    #expect(await counter.value() == 2)
  }

  @Test("Graph node cache ttl zero expires before reuse")
  func graphNodeCacheTTLZeroExpiresBeforeReuse() async throws {
    let cache = InMemoryCoreAgentGraphNodeCache<State>()
    let counter = CoreAgentGraphNodeCacheInvocationCounter()
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode(
      "expensive",
      cachePolicy: CoreAgentGraphCachePolicy(ttl: 0) { state, _ in
        CoreAgentGraphCacheKey(state.route)
      }
    ) { state, _ in
      let run = await counter.increment()
      var next = state
      next.log.append("run-\(run)")
      return next
    }
    try graph.addEdge(.start, .node("expensive"))
    try graph.addEdge(.node("expensive"), .end)
    let compiled = try graph.compile(cache: cache)

    let first = try await compiled.invoke(State(route: "same"))
    let second = try await compiled.invoke(State(route: "same"))

    #expect(first.log == ["run-1"])
    #expect(second.log == ["run-2"])
    #expect(await counter.value() == 2)
  }
}
