import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph streaming")
struct CoreAgentGraphStreamingTests {
  struct State: Sendable, Equatable {
    var log: [String] = []
  }

  struct Progress: Codable, Equatable, Sendable {
    var label: String
  }

  struct Failure: Error, Equatable {}

  @Test("Streams full state snapshots after each super-step")
  func streamsValueSnapshots() async throws {
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

    let events = try await collect(graph.compile().stream(State()))

    let snapshots = events.compactMap { event -> [String]? in
      guard case .values(let snapshot, _) = event else { return nil }
      return snapshot.log
    }
    #expect(snapshots == [[], ["a"], ["a", "b"]])
  }

  @Test("Streams node updates and task lifecycle events")
  func streamsUpdatesAndTasks() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("a") { state, _ in
      var next = state
      next.log.append("a")
      return next
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)

    let events = try await collect(graph.compile().stream(State()))

    #expect(events.contains(.taskStarted(nodeID: "a", step: 1)))
    #expect(events.contains(.taskCompleted(nodeID: "a", step: 1)))
    #expect(events.contains(.updates(nodeID: "a", update: State(log: ["a"]), step: 1)))
  }

  @Test("Streams task failure events before throwing")
  func streamsTaskFailures() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("a") { _, _ in
      throw Failure()
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    var events: [CoreAgentGraphStreamEvent<State>] = []

    do {
      for try await event in try graph.compile().stream(State()) {
        events.append(event)
      }
      Issue.record("Expected stream to throw node failure")
    } catch {
      #expect(error is Failure)
    }

    #expect(events.contains(.taskFailed(nodeID: "a", step: 1)))
  }

  @Test("Streams parallel task events in canonical node order")
  func streamsParallelEventsInCanonicalOrder() async throws {
    var graph = CoreAgentStateGraph<State> { current, update in
      var next = current
      next.log.append(contentsOf: update.log)
      return next
    }
    try graph.addNode("b") { _, _ in State(log: ["b"]) }
    try graph.addNode("a") { _, _ in
      try await Task.sleep(for: .milliseconds(20))
      return State(log: ["a"])
    }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)

    let events = try await collect(graph.compile().stream(State()))

    let updateOrder = events.compactMap { event -> String? in
      guard case .updates(let nodeID, _, _) = event else { return nil }
      return nodeID.rawValue
    }
    #expect(updateOrder == ["a", "b"])
  }

  @Test("Streams resumed values with monotonic checkpoint step numbers")
  func streamsResumedValuesWithRestoredStep() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
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
    let compiled = try graph.compile(checkpointer: checkpointer)
    _ = try await compiled.invoke(State(), threadID: "thread")
    let afterFirstStep = try #require(
      await checkpointer.history(threadID: "thread").first { $0.step == 1 }
    )

    let events = try await collect(
      compiled.stream(State(log: ["ignored"]), threadID: "thread", checkpointID: afterFirstStep.id)
    )

    let valueSteps = events.compactMap { event -> Int? in
      guard case .values(_, let step) = event else { return nil }
      return step
    }
    #expect(valueSteps == [1, 2])
  }

  @Test("Streams custom events from node context")
  func streamsCustomEventsFromContext() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("a") { state, context in
      try await context.emitCustomEvent("progress", value: Progress(label: "started"))
      return state
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)

    let events = try await collect(graph.compile().stream(State(), threadID: "thread"))
    let custom = try #require(
      events.compactMap { event -> CoreAgentGraphCustomEvent? in
        guard case .custom(let custom, step: 1) = event else { return nil }
        return custom
      }.first)

    #expect(custom.name == "progress")
    #expect(try custom.value.decode(as: Progress.self) == Progress(label: "started"))
  }

  @Test("Runtime context carries run thread namespace and step metadata")
  func runtimeContextCarriesMetadata() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("a") { state, context in
      #expect(context.threadID == "thread")
      #expect(context.checkpointNamespace == "namespace")
      #expect(context.step == 1)
      #expect(context.runID.rawValue.isEmpty == false)
      return state
    }
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)

    _ = try await graph.compile().invoke(
      State(),
      threadID: "thread",
      namespace: "namespace"
    )
  }

  @Test("Graph node cache streams cache hits and cached updates")
  func graphNodeCacheStreamsCacheHitsAndCachedUpdates() async throws {
    let cache = InMemoryCoreAgentGraphNodeCache<State>()
    let counter = CoreAgentGraphNodeCacheInvocationCounter()
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode(
      "expensive",
      cachePolicy: CoreAgentGraphCachePolicy { _, _ in
        CoreAgentGraphCacheKey("constant")
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

    _ = try await compiled.invoke(State())
    let events = try await collect(compiled.stream(State()))

    #expect(events.contains(.nodeCacheHit(nodeID: "expensive", key: "constant", step: 1)))
    #expect(
      events.contains(.updates(nodeID: "expensive", update: State(log: ["run-1"]), step: 1))
    )
    #expect(await counter.value() == 1)
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
