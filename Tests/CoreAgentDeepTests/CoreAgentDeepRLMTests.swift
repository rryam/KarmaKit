import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import Testing

@Suite("CoreAgentDeep RLM orchestration")
struct CoreAgentDeepRLMTests {
  @Test("RLM orchestrator decomposes and dispatches subtasks")
  func rlmOrchestratorDecomposesAndDispatchesSubtasks() async throws {
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Handles delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done:\(request.description)"
            )
          }
        ),
      ]
    )
    let orchestrator = CoreAgentDeepRLMOrchestrator(
      decomposer: ClosureCoreAgentDeepRLMDecomposer { request in
        [
          CoreAgentDeepRLMSubtask(
            description: "first",
            subagentType: "worker"
          ),
          CoreAgentDeepRLMSubtask(
            description: "second",
            subagentType: "worker"
          ),
        ]
      },
      taskTool: taskTool,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 2, maximumDelegations: 4)
    )

    let result = try await orchestrator.run(task: "Split the work")

    #expect(result.status == .completed)
    #expect(result.subtaskResults.count == 2)
    #expect(result.summary.contains("done:first"))
    #expect(result.summary.contains("done:second"))
  }

  @Test("RLM orchestrator fails closed when decomposition exceeds delegation budget")
  func rlmOrchestratorFailsClosedWhenDecompositionExceedsDelegationBudget() async throws {
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Handles delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: request.description
            )
          }
        ),
      ]
    )
    let orchestrator = CoreAgentDeepRLMOrchestrator(
      decomposer: ClosureCoreAgentDeepRLMDecomposer { _ in
        [
          CoreAgentDeepRLMSubtask(description: "a", subagentType: "worker"),
          CoreAgentDeepRLMSubtask(description: "b", subagentType: "worker"),
        ]
      },
      taskTool: taskTool,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 2, maximumDelegations: 1)
    )

    let result = try await orchestrator.run(task: "Too many subtasks")

    #expect(result.status == .budgetExceeded)
    #expect(result.subtaskResults.isEmpty)
  }

  @Test("FoundationModels RLM decomposer filters unknown subagents")
  func foundationModelsRLMDecomposerFiltersUnknownSubagents() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: """
        {
          "subtasks": [
            {
              "description": "Research the topic",
              "subagentType": "researcher"
            },
            {
              "description": "Should be ignored",
              "subagentType": "unknown"
            }
          ]
        }
        """),
    ])
    let session = try CoreAgentSession(model: model)
    let decomposer = CoreAgentDeepFoundationModelsRLMDecomposer(session: session)
    let subtasks = try await decomposer.decompose(
      CoreAgentDeepRLMDecompositionRequest(
        task: "Investigate",
        availableSubagents: [
          CoreAgentDeepSubagentDescriptor(name: "researcher", description: "Research")
        ],
        budget: CoreAgentDeepSubagentBudgetState(
          depth: 0,
          maximumDepth: 2,
          delegationsUsed: 0,
          maximumDelegations: 2
        )
      )
    )
    #expect(subtasks.count == 1)
    #expect(subtasks[0].subagentType == "researcher")
  }
}
