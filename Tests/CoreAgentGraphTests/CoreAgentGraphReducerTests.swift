import CoreAgentGraph
import FoundationModels
import Testing

@Suite("CoreAgentGraph reducers")
struct CoreAgentGraphReducerTests {
  @Test("Overwrites state only when selected explicitly")
  func overwritesExplicitly() throws {
    let channel = CoreAgentGraphChannel<String>.overwrite()

    #expect(try channel.reduce("old", "new") == "new")
  }

  @Test("Appends collection state in reducer order")
  func appendsCollections() throws {
    let channel = CoreAgentGraphChannel<[String]>.append()

    #expect(try channel.reduce(["a"], ["b", "c"]) == ["a", "b", "c"])
  }

  @Test("Initializes graphs from an explicit channel reducer")
  func initializesGraphFromChannelReducer() async throws {
    var graph = CoreAgentStateGraph(channel: CoreAgentGraphChannel<[String]>.append())
    try graph.addNode("b") { _, _ in ["b"] }
    try graph.addNode("a") { _, _ in
      try await Task.sleep(for: .milliseconds(20))
      return ["a"]
    }
    try graph.addEdge(.start, .node("b"))
    try graph.addEdge(.start, .node("a"))
    try graph.addEdge(.node("a"), .end)
    try graph.addEdge(.node("b"), .end)

    let result = try await graph.compile().invoke([])

    #expect(result == ["a", "b"])
  }

  @Test("Appends native Foundation Models transcript entries")
  func appendsNativeTranscriptEntries() throws {
    let first: Transcript.Entry = .prompt(.init(segments: [.text(.init(content: "first"))]))
    let second: Transcript.Entry = .prompt(.init(segments: [.text(.init(content: "second"))]))
    let channel = CoreAgentGraphChannel<[Transcript.Entry]>.transcriptHistory()

    #expect(try channel.reduce([first], [second]) == [first, second])
  }
}
