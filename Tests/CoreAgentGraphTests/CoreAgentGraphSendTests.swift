import CoreAgentGraph
import Foundation
import Testing

@Suite("CoreAgentGraph Send fanout")
struct CoreAgentGraphSendTests {
  struct State: Codable, Equatable, Sendable {
    var items: [String] = []
    var current: String?
    var processed: [String] = []
    var log: [String] = []
  }

  struct TransientFailure: Error, Equatable {}

  actor Attempts {
    private var counts: [String: Int] = [:]

    func record(_ key: String) -> Int {
      counts[key, default: 0] += 1
      return counts[key, default: 0]
    }

    func count(_ key: String) -> Int {
      counts[key, default: 0]
    }
  }

  @Test("Send edges run the same node multiple times with distinct sent state")
  func sendEdgesRunSameNodeMultipleTimesWithDistinctSentState() async throws {
    var graph = makeAppendGraph()
    try graph.addNode("fanout") { _, _ in
      State()
    }
    try graph.addNode("worker") { state, _ in
      State(
        processed: ["processed-\(try #require(state.current))"],
        log: ["input-\(try #require(state.current))"]
      )
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { state, _ in
      state.items.map { item in
        CoreAgentGraphSend("worker", state: State(current: item))
      }
    }
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("worker"), .end)

    let result = try await graph.compile().invoke(State(items: ["cats", "dogs", "owls"]))

    #expect(result.processed == ["processed-cats", "processed-dogs", "processed-owls"])
    #expect(result.log == ["input-cats", "input-dogs", "input-owls"])
  }

  @Test("Send edges require a reducer for parallel pushed updates")
  func sendEdgesRequireReducerForParallelPushedUpdates() async throws {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("fanout") { state, _ in
      state
    }
    try graph.addNode("worker") { state, _ in
      State(processed: [try #require(state.current)])
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { state, _ in
      state.items.map { CoreAgentGraphSend("worker", state: State(current: $0)) }
    }
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("worker"), .end)

    await #expect(
      throws: CoreAgentGraphRuntimeError.parallelUpdatesRequireReducer(["worker", "worker"])
    ) {
      _ = try await graph.compile().invoke(State(items: ["a", "b"]))
    }
  }

  @Test("Send edges reject undeclared dynamic targets")
  func sendEdgesRejectUndeclaredDynamicTarget() async throws {
    var graph = makeAppendGraph()
    try graph.addNode("fanout") { _, _ in
      State()
    }
    try graph.addNode("worker") { _, _ in
      State(processed: ["declared"])
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { _, _ in
      [CoreAgentGraphSend("missing", state: State(current: "x"))]
    }
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("worker"), .end)

    await #expect(
      throws: CoreAgentGraphRuntimeError.undeclaredSendTarget(
        source: "fanout",
        target: "missing"
      )
    ) {
      _ = try await graph.compile().invoke(State(items: ["x"]))
    }
  }

  @Test("Command nodes can emit sends after applying their update")
  func commandNodeCanEmitSendsAfterApplyingUpdate() async throws {
    var graph = makeAppendGraph()
    try graph.addCommandNode("router") { _, _ in
      .command(
        update: State(log: ["router"]),
        goto: [],
        sends: [
          CoreAgentGraphSend("worker", state: State(current: "a")),
          CoreAgentGraphSend("worker", state: State(current: "b")),
        ]
      )
    }
    try graph.addNode("worker") { state, _ in
      State(log: ["worker-\(try #require(state.current))"])
    }
    try graph.addCommandRoutes(from: "router", to: [.node("worker")])
    try graph.addEdge(.start, .node("router"))
    try graph.addEdge(.node("worker"), .end)

    let result = try await graph.compile().invoke(State())

    #expect(result.log == ["router", "worker-a", "worker-b"])
  }

  @Test("Send stream events expose duplicate task evidence")
  func sendStreamEventsExposeDuplicateTaskEvidence() async throws {
    var graph = makeAppendGraph()
    try graph.addNode("fanout") { _, _ in
      State()
    }
    try graph.addNode("worker") { state, _ in
      State(processed: [try #require(state.current)])
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { state, _ in
      state.items.map { CoreAgentGraphSend("worker", state: State(current: $0)) }
    }
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("worker"), .end)

    let events = try await collect(
      try graph.compile().stream(State(items: ["one", "two"]))
    )
    let sendEvents = events.compactMap {
      event -> (
        CoreAgentGraphNodeID,
        CoreAgentGraphNodeID,
        State,
        CoreAgentGraphTaskID,
        Int
      )? in
      guard case .send(let source, let target, let state, let taskID, let step) = event else {
        return nil
      }
      return (source, target, state, taskID, step)
    }

    #expect(sendEvents.map(\.0) == ["fanout", "fanout"])
    #expect(sendEvents.map(\.1) == ["worker", "worker"])
    #expect(sendEvents.map(\.2.current) == ["one", "two"])
    #expect(sendEvents.map(\.4) == [1, 1])
    #expect(Set(sendEvents.map(\.3)).count == 2)
  }

  @Test("Send checkpoint resume preserves duplicate task inputs and pending writes")
  func sendCheckpointResumePreservesDuplicateTaskInputsAndPendingWrites() async throws {
    let attempts = Attempts()
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    var graph = makeAppendGraph()
    try graph.addNode("fanout") { _, _ in
      State()
    }
    try graph.addNode("worker") { state, _ in
      let item = try #require(state.current)
      let attempt = await attempts.record(item)
      if item == "b", attempt == 1 {
        throw TransientFailure()
      }
      return State(processed: [item])
    }
    try graph.addSendEdges(from: "fanout", to: ["worker"]) { state, _ in
      state.items.map { CoreAgentGraphSend("worker", state: State(current: $0)) }
    }
    try graph.addEdge(.start, .node("fanout"))
    try graph.addEdge(.node("worker"), .end)
    let compiled = try graph.compile(checkpointer: checkpointer)

    do {
      _ = try await compiled.invoke(State(items: ["a", "b"]), threadID: "thread")
      Issue.record("Expected first run to throw the transient failure")
    } catch {
      #expect(error is TransientFailure)
    }

    let failureCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    let pendingWrite = try #require(failureCheckpoint.pendingWrites.first)
    let retryTask = try #require(failureCheckpoint.nextTasks.first)

    #expect(failureCheckpoint.pendingWrites.count == 1)
    #expect(pendingWrite.nodeID == "worker")
    #expect(pendingWrite.taskID != nil)
    #expect(pendingWrite.update.processed == ["a"])
    #expect(failureCheckpoint.nextTasks.count == 1)
    #expect(retryTask.nodeID == "worker")
    #expect(retryTask.input?.current == "b")
    #expect(retryTask.taskID != pendingWrite.taskID)

    let result = try await compiled.invoke(
      State(items: ["ignored"]),
      threadID: "thread",
      checkpointID: failureCheckpoint.id
    )

    #expect(result.processed == ["a", "b"])
    #expect(await attempts.count("a") == 1)
    #expect(await attempts.count("b") == 2)
  }

  @Test("Retry slice after failure ignores tasks whose node was skipped")
  func retrySliceAfterFailureIgnoresSkippedTaskOrder() async throws {
    // Regression: a resumed checkpoint can carry a scheduled task whose node no longer
    // exists in the compiled graph (schema drift). `executeNodes` skips such a task, so
    // `results` is shorter than `activeTasks`. The retry slice must key off the failing
    // task's `order` (its index in `activeTasks`), not its position within `results`;
    // otherwise the phantom skipped task is wrongly re-queued for retry.
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    var graph = makeAppendGraph()
    try graph.addNode("worker") { state, _ in
      State(processed: [try #require(state.current)])
    }
    try graph.addNode("boom") { _, _ in
      throw TransientFailure()
    }
    try graph.addEdge(.start, .node("worker"))
    try graph.addEdge(.node("worker"), .end)
    try graph.addEdge(.start, .node("boom"))
    try graph.addEdge(.node("boom"), .end)
    let compiled = try graph.compile(checkpointer: checkpointer)

    // Regular (pull) tasks are canonicalized in sorted node-ID order. "aaa-removed"
    // sorts before "boom", so it occupies order 0 and is skipped at execution time (no
    // such node in the graph), leaving the failing "boom" task at order 1. The old
    // `results.firstIndex` logic returned position 0 for that failure and wrongly sliced
    // `activeTasks[0...]`, re-queuing the phantom "aaa-removed" task.
    let seeded = CoreAgentGraphCheckpoint<State>(
      threadID: "thread",
      step: 0,
      state: State(),
      nextTasks: [
        CoreAgentGraphPendingTask("aaa-removed"),
        CoreAgentGraphPendingTask("boom"),
      ]
    )
    await checkpointer.save(seeded)

    do {
      _ = try await compiled.invoke(
        State(),
        threadID: "thread",
        checkpointID: seeded.id
      )
      Issue.record("Expected the boom node to throw the transient failure")
    } catch {
      #expect(error is TransientFailure)
    }

    let retryCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    // Only the failing task is re-queued; the skipped "removed" task must not reappear.
    #expect(retryCheckpoint.nextTasks.map(\.nodeID) == ["boom"])
  }

  @Test("Checkpoints decode legacy next node IDs as pending tasks")
  func checkpointsDecodeLegacyNextNodeIDsAsPendingTasks() throws {
    struct LegacyCheckpoint: Codable {
      var id = CoreAgentGraphCheckpointID("legacy")
      var threadID = CoreAgentGraphThreadID("thread")
      var namespace = CoreAgentGraphCheckpointNamespace.default
      var parentCheckpointID: CoreAgentGraphCheckpointID?
      var step = 3
      var state = State(log: ["legacy"])
      var nextNodeIDs: [CoreAgentGraphNodeID] = ["a", "b"]
      var pendingWrites: [CoreAgentGraphPendingWrite<State>] = []
      var createdAt = Date(timeIntervalSinceReferenceDate: 42)
    }

    let data = try JSONEncoder().encode(LegacyCheckpoint())
    let checkpoint = try JSONDecoder().decode(CoreAgentGraphCheckpoint<State>.self, from: data)

    #expect(checkpoint.nextNodeIDs == ["a", "b"])
    #expect(checkpoint.nextTasks.map(\.nodeID) == ["a", "b"])
    #expect(checkpoint.nextTasks.allSatisfy { $0.input == nil && $0.taskID == nil })
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
