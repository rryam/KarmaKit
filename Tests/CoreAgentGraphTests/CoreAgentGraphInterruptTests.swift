import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph interrupts")
struct CoreAgentGraphInterruptTests {
  struct State: Sendable, Equatable {
    var log: [String] = []
  }

  @Test("Streams typed interrupt events and persists the resume point")
  func streamsInterruptAndPersistsResumePoint() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let compiled = try makeInterruptingGraph().compile(checkpointer: checkpointer)
    let expectedInterrupt = try CoreAgentGraphInterrupt(id: "approval", value: "need approval")
    var events: [CoreAgentGraphStreamEvent<State>] = []

    do {
      for try await event in compiled.stream(State(), threadID: "thread") {
        events.append(event)
      }
      Issue.record("Expected stream to throw an interrupt")
    } catch {
      #expect(error as? CoreAgentGraphRuntimeError == .interrupted(expectedInterrupt))
    }

    #expect(events.contains(.interrupted(nodeID: "ask", expectedInterrupt, step: 1)))
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))
    #expect(checkpoint.state == State())
    #expect(checkpoint.nextNodeIDs == ["ask"])
  }

  @Test("Resume commands are consumed by the interrupted node")
  func resumeCommandIsConsumed() async throws {
    let checkpointer = InMemoryCoreAgentGraphCheckpointer<State>()
    let compiled = try makeInterruptingGraph().compile(checkpointer: checkpointer)

    do {
      _ = try await compiled.invoke(State(), threadID: "thread")
      Issue.record("Expected invoke to throw an interrupt")
    } catch {
      #expect(
        error as? CoreAgentGraphRuntimeError
          == .interrupted(try CoreAgentGraphInterrupt(id: "approval", value: "need approval"))
      )
    }
    let checkpoint = try #require(await checkpointer.latest(threadID: "thread"))

    let result = try await compiled.invoke(
      State(log: ["ignored"]),
      threadID: "thread",
      checkpointID: checkpoint.id,
      command: try .resume("approved")
    )

    #expect(result.log == ["approved"])
  }

  @Test("Parallel interrupts are reported in canonical node order")
  func interruptsUseCanonicalNodeOrder() async throws {
    var graph = CoreAgentStateGraph<State> { current, update in
      var next = current
      next.log.append(contentsOf: update.log)
      return next
    }
    try graph.addNode("b") { _, context in
      try context.interrupt("b", id: "b")
    }
    try graph.addNode("a") { _, context in
      try await Task.sleep(for: .milliseconds(20))
      try context.interrupt("a", id: "a")
    }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    let expectedInterrupt = try CoreAgentGraphInterrupt(id: "a", value: "a")

    await #expect(throws: CoreAgentGraphRuntimeError.interrupted(expectedInterrupt)) {
      _ = try await graph.compile().invoke(State())
    }
  }

  @Test("Resume context exposes stable idempotency markers")
  func resumeContextExposesStableIdempotencyMarkers() async throws {
    let marker = CoreAgentGraphInterruptID("approval")
    let interrupt = try CoreAgentGraphInterrupt(id: marker, value: "need approval")

    #expect(interrupt.id == marker)
    #expect(try interrupt.value.decode(as: String.self) == "need approval")
  }

  private func makeInterruptingGraph() throws -> CoreAgentStateGraph<State> {
    var graph = CoreAgentStateGraph<State>()
    try graph.addNode("ask") { state, context in
      if let answer = try context.resumeValue(as: String.self) {
        var next = state
        next.log.append(answer)
        return next
      }
      try context.interrupt("need approval", id: "approval")
    }
    try graph.addEdge(.start, .node("ask"))
    try graph.addEdge(.node("ask"), .end)
    return graph
  }
}
