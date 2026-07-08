import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph pending writes")
struct CoreAgentGraphPendingWriteTests {
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

  @Test("Recovers pending writes without replaying completed nodes")
  func recoversPendingWritesWithoutReplayingCompletedNodes() async throws {
    let attempts = Attempts()
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    var graph = CoreAgentStateGraph<State> { current, update in
      var next = current
      next.log.append(contentsOf: update.log)
      return next
    }
    try graph.addNode("a") { _, _ in
      _ = await attempts.record("a")
      return State(log: ["a"])
    }
    try graph.addNode("b") { _, _ in
      let attempt = await attempts.record("b")
      if attempt == 1 {
        throw TransientFailure()
      }
      return State(log: ["b"])
    }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)
    let compiled = try graph.compile(checkpointer: checkpointer)

    do {
      _ = try await compiled.invoke(State(), threadID: "thread")
      Issue.record("Expected first run to throw the transient failure")
    } catch {
      #expect(error is TransientFailure)
    }

    let failureCheckpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(failureCheckpoint.state == State())
    #expect(failureCheckpoint.nextNodeIDs == ["b"])
    #expect(
      failureCheckpoint.pendingWrites == [
        CoreAgentGraphPendingWrite(nodeID: "a", step: 1, update: State(log: ["a"]))
      ]
    )

    let result = try await compiled.invoke(
      State(log: ["ignored"]),
      threadID: "thread",
      checkpointID: failureCheckpoint.id
    )

    #expect(result.log == ["a", "b"])
    #expect(await attempts.count("a") == 1)
    #expect(await attempts.count("b") == 2)
  }
}
