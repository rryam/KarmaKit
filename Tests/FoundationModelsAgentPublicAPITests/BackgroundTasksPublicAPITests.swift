import Foundation
import FoundationModelsAgent
import FoundationModelsAgentBackgroundTasks
import Testing

@Suite("Durable background task public API consumer")
struct BackgroundTasksPublicAPITests {
  @Test("Persists canonical run, output, receipt, and attempt evidence")
  func canonicalEvidenceRoundTrip() async throws {
    let parent = AgentRunLineage.root()
    let store = InMemoryBackgroundAgentTaskStore()
    let coordinator = try BackgroundAgentTaskCoordinator(store: store) { record, context in
      let lineage = try #require(record.currentAttemptLineage)
      try await context.recordUsage(turns: 1, tokens: 7)
      let startedAt = record.firstStartedAt ?? record.submittedAt
      let result = try AgentTaskResult(
        lineage: lineage,
        status: .succeeded,
        outputReferences: [
          AgentEvidenceReference(
            id: "artifact:summary",
            kind: .output,
            runID: lineage.runID,
            location: "app://runs/\(lineage.runID)/summary"
          )
        ],
        evidenceReferences: [.run(lineage.runID)],
        usage: FoundationModelsAgentUsage(
          inputTokens: 4,
          cachedInputTokens: 0,
          outputTokens: 3,
          reasoningTokens: 0
        ),
        receipt: AgentReceiptReference(runID: lineage.runID, rootHash: "receipt-root"),
        timing: AgentTaskTiming(
          queuedAt: record.submittedAt,
          startedAt: startedAt,
          endedAt: startedAt
        )
      )
      return BackgroundAgentTaskOutcome(taskResult: result)
    }

    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "Summarize the durable evidence.",
        ownerID: "public-consumer",
        parentLineage: parent,
        metadata: ["checkpointKey": "background-summary"],
        recoveryPolicy: .readOnly
      )
    )
    let settled = try await coordinator.waitForSettlement(of: id)
    let reloaded = try #require(await store.loadSnapshot()?.records.first)

    #expect(settled.state == .completed)
    #expect(settled.taskResult?.lineage.taskID == id.agentTaskID)
    #expect(settled.taskResult?.outputReferences.first?.kind == .output)
    #expect(settled.taskResult?.receipt?.rootHash == "receipt-root")
    #expect(settled.attempts.count == 1)
    #expect(settled.attempts[0].lineage.relationship == .background)
    #expect(settled.attempts[0].terminalCode == .completed)
    #expect(reloaded == settled)
  }

  @Test("Rejects canonical evidence from another task")
  func rejectsMismatchedResult() async throws {
    let parent = AgentRunLineage.root()
    let coordinator = try BackgroundAgentTaskCoordinator(
      store: InMemoryBackgroundAgentTaskStore()
    ) { record, _ in
      let wrongLineage = try parent.descendant(relationship: .background)
      let startedAt = record.firstStartedAt ?? record.submittedAt
      return BackgroundAgentTaskOutcome(
        taskResult: try AgentTaskResult(
          lineage: wrongLineage,
          status: .succeeded,
          timing: AgentTaskTiming(
            queuedAt: record.submittedAt,
            startedAt: startedAt,
            endedAt: startedAt
          )
        )
      )
    }
    let id = try await coordinator.submit(
      BackgroundAgentTaskRequest(
        prompt: "Do not accept unrelated evidence.",
        ownerID: "public-consumer",
        parentLineage: parent,
        recoveryPolicy: .readOnly
      )
    )

    let settled = try await coordinator.waitForSettlement(of: id)

    #expect(settled.state == .failed)
    #expect(settled.taskResult == nil)
    #expect(settled.terminalReason?.detail?.contains("canonical task result") == true)
  }
}
