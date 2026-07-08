import CoreAgent
import CoreAgentDeep
import CoreAgentGraph
import Foundation
import Testing

@Suite("CoreAgentDeep event projection")
struct CoreAgentDeepEventProjectionTests {
  @Test("Projects CoreAgent run events into typed Deep lifecycle evidence")
  func projectsRunEvents() throws {
    let runID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let invocationID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let started = Date(timeIntervalSince1970: 10)
    let run = CoreAgentRun(
      id: runID,
      startedAt: started,
      endedAt: Date(timeIntervalSince1970: 20),
      usage: nil,
      events: [
        CoreAgentEvent(
          id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 11),
          kind: .runStarted,
          message: "started"
        ),
        CoreAgentEvent(
          id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 12),
          kind: .toolInterventionEdited,
          message: "edited",
          attributes: [
            "tool": "write_file",
            "invocation_id": invocationID.uuidString.lowercased(),
            "arguments_source": "intervention_edit",
            "requested_arguments_digest": "requested-digest",
            "executed_arguments_digest": "executed-digest",
          ]
        ),
        CoreAgentEvent(
          id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 13),
          kind: .nativeToolOutputRecorded,
          message: "output",
          attributes: [
            "tool": "write_file",
            "native_call_id": "native-1",
            "tool_invocation_id": invocationID.uuidString.lowercased(),
            "output_source": "tool_execution",
            "arguments_source": "intervention_edit",
            "requested_arguments_digest": "requested-digest",
            "executed_arguments_digest": "executed-digest",
          ]
        ),
        CoreAgentEvent(
          id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa4")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 14),
          kind: .transcriptCheckpointed,
          message: "checkpoint",
          attributes: [
            "history_entries": "7",
            "artifacts": "2",
          ]
        ),
      ]
    )

    let projection = CoreAgentDeepEventProjector.project(run: run)

    #expect(projection.runID == runID)
    #expect(projection.events.map(\.sequence) == [0, 1, 2, 3])

    let hitl = try #require(projection.hitlEvents.first)
    #expect(hitl.eventKind == .toolInterventionEdited)
    #expect(hitl.toolName == "write_file")
    #expect(hitl.toolInvocationID == invocationID)
    #expect(hitl.argumentsSource == "intervention_edit")
    #expect(hitl.requestedArgumentsDigest == "requested-digest")
    #expect(hitl.executedArgumentsDigest == "executed-digest")

    let nativeTool = try #require(projection.nativeToolEvents.first)
    #expect(nativeTool.eventKind == .nativeToolOutputRecorded)
    #expect(nativeTool.toolName == "write_file")
    #expect(nativeTool.nativeToolCallID == "native-1")
    #expect(nativeTool.outputSource == "tool_execution")
    #expect(nativeTool.toolInvocationID == invocationID)

    let checkpoint = try #require(projection.checkpointEvents.first)
    #expect(checkpoint.eventKind == .transcriptCheckpointed)
    #expect(checkpoint.historyEntryCount == 7)
    #expect(checkpoint.artifactCount == 2)
  }

  @Test("Projects Deep audit snapshots without scraping model-facing text")
  func projectsDeepAuditSnapshots() throws {
    let parentRunID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let taskID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let childRunID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    let projection = CoreAgentDeepEventProjector.project(
      filesystemEvents: [
        CoreAgentDeepFilesystemAuditEvent(
          operation: .write,
          path: "/workspace/report.md",
          decision: .allowed,
          ruleIndex: 1
        )
      ],
      offloads: [
        CoreAgentDeepToolResultOffload(
          path: "/large_tool_results/tool-1",
          originalCharacterCount: 120_000,
          preview: "preview",
          message: "model-facing recovery text that must not be parsed"
        )
      ],
      subagentRecords: [
        CoreAgentDeepSubagentAuditRecord(
          id: taskID,
          subagentName: "researcher",
          description: "Summarize current sources",
          parentRunID: parentRunID,
          parentToolInvocationID: taskID,
          childRunID: childRunID,
          childReceiptRootHash: "receipt-root",
          checkpointKey: "coreagent-deep/subagents/researcher/task-1",
          status: .completed,
          errorDescription: nil,
          outputCharacterCount: 42,
          startedAt: Date(timeIntervalSince1970: 30),
          endedAt: Date(timeIntervalSince1970: 31)
        )
      ],
      todos: [
        CoreAgentDeepTodo(content: "Plan", status: .completed),
        CoreAgentDeepTodo(content: "Review", status: .pending),
        CoreAgentDeepTodo(content: "Ship", status: .pending),
      ]
    )

    let filesystem = try #require(projection.filesystemEvents.first)
    #expect(filesystem.operation == .write)
    #expect(filesystem.path == "/workspace/report.md")
    #expect(filesystem.decision == .allowed)
    #expect(filesystem.ruleIndex == 1)

    let offload = try #require(projection.offloadEvents.first)
    #expect(offload.path == "/large_tool_results/tool-1")
    #expect(offload.originalCharacterCount == 120_000)

    let subagent = try #require(projection.subagentEvents.first)
    #expect(subagent.subagentName == "researcher")
    #expect(subagent.parentRunID == parentRunID)
    #expect(subagent.childRunID == childRunID)
    #expect(subagent.status == .completed)
    #expect(subagent.checkpointKey == "coreagent-deep/subagents/researcher/task-1")

    let todos = try #require(projection.todoEvents.first)
    #expect(todos.totalCount == 3)
    #expect(todos.statusCounts[.completed] == 1)
    #expect(todos.statusCounts[.pending] == 2)
    #expect(todos.statusCounts[.inProgress] == nil)
  }

  @Test("Projects graph interrupts and checkpoints as Deep timeline evidence")
  func projectsGraphEvidence() throws {
    let bundle = CoreAgentDeepHITLReviewBundle(
      actionRequests: [
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/workspace/report.md"}"#,
          description: "Review write",
          toolCallID: "tool-1"
        ),
        CoreAgentDeepHITLActionRequest(
          name: "write_file",
          argsJSON: #"{"path":"/workspace/notes.md"}"#,
          description: "Review second write",
          toolCallID: "tool-2"
        )
      ],
      reviewConfigs: [
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.approve, .edit],
          description: "Human review"
        ),
        CoreAgentDeepHITLReviewConfig(
          actionName: "write_file",
          allowedDecisions: [.respond],
          description: "Human review"
        )
      ]
    )

    let projection = CoreAgentDeepEventProjector.project(
      graphInterrupts: [
        CoreAgentDeepGraphInterruptEvidence(
          nodeID: "review",
          interruptID: "deep-hitl",
          step: 4,
          reviewBundle: bundle
        )
      ],
      graphCheckpoints: [
        CoreAgentDeepGraphCheckpointEvidence(
          checkpointID: "checkpoint-1",
          parentCheckpointID: "checkpoint-0",
          threadID: "thread-1",
          namespace: "default",
          step: 4,
          nextNodeIDs: ["review"],
          pendingWriteCount: 1
        )
      ]
    )

    let interrupt = try #require(projection.graphInterruptEvents.first)
    #expect(interrupt.nodeID == "review")
    #expect(interrupt.interruptID == "deep-hitl")
    #expect(interrupt.step == 4)
    #expect(interrupt.actionCount == 2)
    #expect(interrupt.actions.map(\.toolCallID) == ["tool-1", "tool-2"])
    #expect(interrupt.actions.map(\.actionName) == ["write_file", "write_file"])
    #expect(interrupt.actions.map(\.allowedDecisions) == [[.approve, .edit], [.respond]])
    #expect(interrupt.allowedDecisionsByToolCallID["tool-1"] == [.approve, .edit])
    #expect(interrupt.allowedDecisionsByToolCallID["tool-2"] == [.respond])

    let encoded = try JSONEncoder().encode(projection)
    let encodedJSON = String(decoding: encoded, as: UTF8.self)
    #expect(!encodedJSON.contains("allowedDecisionsByToolCallID"))

    let decoded = try JSONDecoder().decode(CoreAgentDeepEventProjection.self, from: encoded)
    let decodedInterrupt = try #require(decoded.graphInterruptEvents.first)
    #expect(decodedInterrupt.actions.map(\.toolCallID) == ["tool-1", "tool-2"])
    #expect(decodedInterrupt.allowedDecisionsByToolCallID["tool-1"] == [.approve, .edit])
    #expect(decodedInterrupt.allowedDecisionsByToolCallID["tool-2"] == [.respond])

    let checkpoint = try #require(projection.graphCheckpointEvents.first)
    #expect(checkpoint.checkpointID == "checkpoint-1")
    #expect(checkpoint.parentCheckpointID == "checkpoint-0")
    #expect(checkpoint.threadID == "thread-1")
    #expect(checkpoint.nextNodeIDs == ["review"])
    #expect(checkpoint.pendingWriteCount == 1)
  }
  @Test("Projects rubric evaluations and subagent proposals without scraping revision prose")
  func projectsRubricAndSubagentProposalEvidence() throws {
    let proposalID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let proposal = CoreAgentDeepSubagentDescriptorProposal(
      proposalID: proposalID,
      name: "researcher",
      description: "Find sources",
      proposalDigest: "digest-1"
    )
    let rubricResult = CoreAgentDeepRubricResult(
      content: "answer",
      run: CoreAgentRun(
        id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        startedAt: Date(timeIntervalSince1970: 40),
        endedAt: Date(timeIntervalSince1970: 41),
        usage: nil,
        events: []
      ),
      evaluations: [
        CoreAgentDeepRubricEvaluation(
          verdict: .needsRevision,
          iteration: 1,
          criteria: [
            CoreAgentDeepRubricCriterionFeedback(
              criterion: "mentions token",
              passed: false,
              feedback: "model-facing revision prose"
            )
          ],
          revisionMessage: "model-facing revision prose"
        ),
        CoreAgentDeepRubricEvaluation(
          verdict: .satisfied,
          iteration: 2,
          criteria: [
            CoreAgentDeepRubricCriterionFeedback(
              criterion: "mentions token",
              passed: true,
              feedback: nil
            )
          ],
          revisionMessage: nil
        ),
      ],
      status: .satisfied,
      iterationCount: 2
    )

    let projection = CoreAgentDeepEventProjector.project(
      subagentProposals: [proposal],
      subagentProposalApprovals: [proposalID],
      rubricResult: rubricResult
    )

    let proposalEvent = try #require(projection.subagentProposalEvents.first)
    #expect(proposalEvent.proposalID == proposalID)
    #expect(proposalEvent.name == "researcher")
    #expect(proposalEvent.proposalDigest == "digest-1")
    #expect(proposalEvent.approvalStatus == .approved)

    #expect(projection.rubricEvents.count == 3)
    #expect(projection.rubricEvents[0].iteration == 1)
    #expect(projection.rubricEvents[0].verdict == .needsRevision)
    #expect(projection.rubricEvents[0].failedCriteriaCount == 1)
    #expect(projection.rubricEvents[2].completionStatus == .satisfied)
  }

}
