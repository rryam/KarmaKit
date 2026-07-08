import CoreAgent
import CoreAgentAgenticKit
import CoreAgentDeep
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentSkills
import CoreAgentTestSupport
import FoundationModels
import Testing

@Suite("CoreAgentAgenticKit integration")
struct CoreAgentAgenticKitTests {
  @Test("CoreAgentEngine remains usable without CoreAgentDeep imports in trace-only hosts")
  func engineRemainsUsableWithoutDeepHarness() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let plugin = CoreAgentEnginePlugin(store: store, projectID: "trace-only")
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "trace-only ok")]),
      plugins: [plugin]
    )

    let response = try await session.respond(to: "hello")
    let trace = try #require(await store.trace(projectID: "trace-only", runID: response.run.id))

    #expect(trace.run.id == response.run.id)
    #expect(trace.receipt.verify())
  }

  @Test("Integrated kit wires graph, deep, skills, and engine products")
  func integratedKitExposesStackProducts() {
    let _: CoreAgentAgenticGraphNodeID.Type = CoreAgentAgenticGraphNodeID.self
    let _: InMemoryCoreAgentSkillStore.Type = InMemoryCoreAgentSkillStore.self
    let kit = CoreAgentAgenticKit(
      configuration: CoreAgentAgenticKitConfiguration(projectID: "demo")
    )
    #expect(
      kit.filesystemTools().map(\.name).sorted() == [
        "delete",
        "edit_file",
        "glob",
        "grep",
        "ls",
        "read_file",
        "write_file",
      ])
  }

  @Test("Integrated kit accepts a read-only filesystem tool surface")
  func integratedKitAcceptsReadOnlyFilesystemToolSurface() throws {
    let kit = CoreAgentAgenticKit(
      configuration: CoreAgentAgenticKitConfiguration(
        projectID: "read-only-demo",
        filesystemToolSurface: try CoreAgentDeepFilesystemToolSurface(
          allowing: [.readFile, .list, .glob, .grep]
        )
      )
    )

    #expect(
      kit.filesystemTools().map(\.name).sorted() == [
        "glob",
        "grep",
        "ls",
        "read_file",
      ])
  }

  @Test("Recorded end-to-end sample runs todo, filesystem, subagent, and trace ingestion")
  func recordedEndToEndSampleRun() async throws {
    let kit = CoreAgentAgenticKit(
      configuration: CoreAgentAgenticKitConfiguration(
        projectID: "agentic-kit",
        threadID: "thread-1"
      )
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        id: "todo-1",
        name: "write_todos",
        argumentsJSON: #"{"todos":[{"content":"Ship feature","status":"in_progress"}]}"#
      ),
      .toolCall(
        id: "write-1",
        name: "write_file",
        argumentsJSON: #"{"path":"/workspace/plan.txt","content":"step one"}"#
      ),
      .toolCall(
        id: "task-1",
        name: "task",
        argumentsJSON: #"{"description":"Summarize plan","subagent_type":"worker"}"#
      ),
      .response(text: "integrated run complete"),
    ])
    let session = try kit.makeSession(
      model: model,
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Summarizes delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "summary: step one"
            )
          }
        )
      ]
    )

    let response = try await session.respond(to: "Run the integrated deep-agent sample.")

    #expect(response.content == "integrated run complete")
    #expect(
      await kit.todoStore.todos() == [
        CoreAgentDeepTodo(content: "Ship feature", status: .inProgress)
      ])
    #expect(try await kit.filesystem.readFile(at: "/workspace/plan.txt") == "step one")
    #expect(await kit.subagentAuditStore.records().first?.subagentName == "worker")

    let trace = try #require(
      await kit.engineStore.trace(projectID: "agentic-kit", runID: response.run.id)
    )
    #expect(trace.threadID == "thread-1")
    #expect(trace.receipt.verify())
    #expect(trace.run.events.contains { $0.attributes["tool"] == "write_todos" })
    #expect(trace.run.events.contains { $0.attributes["tool"] == "write_file" })
    #expect(trace.run.events.contains { $0.attributes["tool"] == "task" })
  }
}
