import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph package")
struct CoreAgentGraphSmokeTests {
  @Test("Exposes stable graph node identifiers")
  func graphNodeIdentifiers() {
    let id = CoreAgentGraphNodeID("planner")

    #expect(id.rawValue == "planner")
    #expect(String(describing: id) == "planner")
  }
}
