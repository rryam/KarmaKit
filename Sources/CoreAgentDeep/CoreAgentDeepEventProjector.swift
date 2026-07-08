import CoreAgent
import CoreAgentGraph
import Foundation

public enum CoreAgentDeepEventProjector {
  public static func project(
    run: CoreAgentRun? = nil,
    filesystemEvents: [CoreAgentDeepFilesystemAuditEvent] = [],
    offloads: [CoreAgentDeepToolResultOffload] = [],
    subagentRecords: [CoreAgentDeepSubagentAuditRecord] = [],
    subagentProposals: [CoreAgentDeepSubagentDescriptorProposal] = [],
    subagentProposalApprovals: Set<UUID> = [],
    rubricResult: CoreAgentDeepRubricResult? = nil,
    todos: [CoreAgentDeepTodo] = [],
    graphInterrupts: [CoreAgentDeepGraphInterruptEvidence] = [],
    graphCheckpoints: [CoreAgentDeepGraphCheckpointEvidence] = []
  ) -> CoreAgentDeepEventProjection {
    var entries: [CoreAgentDeepProjectedEvent] = []

    if let run {
      entries.append(
        contentsOf: run.events.enumerated().map { index, event in
          CoreAgentDeepProjectedEvent(
            id: "coreagent-event:\(event.id.uuidString.lowercased())",
            sequence: entries.count + index,
            source: .coreAgentEvent,
            timestamp: event.timestamp,
            payload: payload(for: event)
          )
        })
    }

    for event in filesystemEvents {
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "filesystem-audit:\(entries.count)",
          sequence: entries.count,
          source: .filesystemAudit,
          payload: .filesystem(
            CoreAgentDeepFilesystemProjectedEvent(
              operation: event.operation,
              path: event.path,
              decision: event.decision,
              ruleIndex: event.ruleIndex
            )
          )
        )
      )
    }

    for offload in offloads {
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "tool-result-offload:\(entries.count)",
          sequence: entries.count,
          source: .toolResultOffload,
          payload: .offload(
            CoreAgentDeepOffloadProjectedEvent(
              path: offload.path,
              originalCharacterCount: offload.originalCharacterCount
            )
          )
        )
      )
    }

    for record in subagentRecords {
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "subagent-audit:\(record.id.uuidString.lowercased())",
          sequence: entries.count,
          source: .subagentAudit,
          timestamp: record.startedAt,
          payload: .subagent(
            CoreAgentDeepSubagentProjectedEvent(
              taskID: record.id,
              subagentName: record.subagentName,
              parentRunID: record.parentRunID,
              parentToolInvocationID: record.parentToolInvocationID,
              childRunID: record.childRunID,
              childReceiptRootHash: record.childReceiptRootHash,
              checkpointKey: record.checkpointKey,
              status: record.status,
              errorType: record.errorType,
              outputCharacterCount: record.outputCharacterCount,
              budgetDepth: record.budgetDepth,
              budgetDelegationsUsed: record.budgetDelegationsUsed,
              budgetMaximumDepth: record.budgetMaximumDepth,
              budgetMaximumDelegations: record.budgetMaximumDelegations
            )
          )
        )
      )
    }

    for proposal in subagentProposals {
      let approvalStatus: CoreAgentDeepSubagentProposalApprovalStatus =
        subagentProposalApprovals.contains(proposal.proposalID) ? .approved : .proposed
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "subagent-proposal:\(proposal.proposalID.uuidString.lowercased())",
          sequence: entries.count,
          source: .subagentProposal,
          payload: .subagentProposal(
            CoreAgentDeepSubagentProposalProjectedEvent(
              proposalID: proposal.proposalID,
              name: proposal.name,
              proposalDigest: proposal.proposalDigest,
              approvalStatus: approvalStatus
            )
          )
        )
      )
    }

    if let rubricResult {
      for evaluation in rubricResult.evaluations {
        let passed = evaluation.criteria.filter(\.passed).count
        let failed = evaluation.criteria.count - passed
        entries.append(
          CoreAgentDeepProjectedEvent(
            id: "rubric-evaluation:\(evaluation.iteration)",
            sequence: entries.count,
            source: .rubricEvaluation,
            payload: .rubric(
              CoreAgentDeepRubricProjectedEvent(
                iteration: evaluation.iteration,
                verdict: evaluation.verdict,
                passedCriteriaCount: passed,
                failedCriteriaCount: failed
              )
            )
          )
        )
      }
      if let lastEvaluation = rubricResult.evaluations.last {
        let passed = lastEvaluation.criteria.filter(\.passed).count
        let failed = lastEvaluation.criteria.count - passed
        entries.append(
          CoreAgentDeepProjectedEvent(
            id: "rubric-result:\(rubricResult.status.rawValue)",
            sequence: entries.count,
            source: .rubricEvaluation,
            payload: .rubric(
              CoreAgentDeepRubricProjectedEvent(
                iteration: rubricResult.iterationCount,
                verdict: lastEvaluation.verdict,
                passedCriteriaCount: passed,
                failedCriteriaCount: failed,
                completionStatus: rubricResult.status
              )
            )
          )
        )
      } else if rubricResult.evaluations.isEmpty {
        entries.append(
          CoreAgentDeepProjectedEvent(
            id: "rubric-result:\(rubricResult.status.rawValue)",
            sequence: entries.count,
            source: .rubricEvaluation,
            payload: .rubric(
              CoreAgentDeepRubricProjectedEvent(
                iteration: rubricResult.iterationCount,
                verdict: .satisfied,
                passedCriteriaCount: 0,
                failedCriteriaCount: 0,
                completionStatus: rubricResult.status
              )
            )
          )
        )
      }
    }

    if !todos.isEmpty {
      var statusCounts: [CoreAgentDeepTodoStatus: Int] = [:]
      for todo in todos {
        statusCounts[todo.status, default: 0] += 1
      }
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "todo-snapshot:\(entries.count)",
          sequence: entries.count,
          source: .todoSnapshot,
          payload: .todo(
            CoreAgentDeepTodoProjectedEvent(
              totalCount: todos.count,
              statusCounts: statusCounts
            )
          )
        )
      )
    }

    for interrupt in graphInterrupts {
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "graph-interrupt:\(interrupt.interruptID.rawValue):\(interrupt.step)",
          sequence: entries.count,
          source: .graphInterrupt,
          payload: .graphInterrupt(
            CoreAgentDeepGraphInterruptProjectedEvent(
              nodeID: interrupt.nodeID,
              interruptID: interrupt.interruptID,
              step: interrupt.step,
              actions: projectedActions(in: interrupt.reviewBundle)
            )
          )
        )
      )
    }

    for checkpoint in graphCheckpoints {
      entries.append(
        CoreAgentDeepProjectedEvent(
          id: "graph-checkpoint:\(checkpoint.checkpointID.rawValue)",
          sequence: entries.count,
          source: .graphCheckpoint,
          payload: .graphCheckpoint(
            CoreAgentDeepGraphCheckpointProjectedEvent(
              checkpointID: checkpoint.checkpointID,
              parentCheckpointID: checkpoint.parentCheckpointID,
              threadID: checkpoint.threadID,
              namespace: checkpoint.namespace,
              step: checkpoint.step,
              nextNodeIDs: checkpoint.nextNodeIDs,
              pendingWriteCount: checkpoint.pendingWriteCount
            )
          )
        )
      )
    }

    return CoreAgentDeepEventProjection(runID: run?.id, events: entries)
  }

  private static func payload(for event: CoreAgentEvent) -> CoreAgentDeepProjectedEventPayload {
    switch event.kind {
    case .runStarted, .runCompleted, .runFailed:
      return .run(
        CoreAgentDeepRunProjectedEvent(
          runID: event.runID,
          eventKind: event.kind,
          status: runStatus(for: event.kind),
          errorType: event.attributes["error_type"]
        )
      )
    case .modelAttemptStarted, .modelAttemptFailed, .modelResponseCompleted:
      return .model(
        CoreAgentDeepModelProjectedEvent(
          eventKind: event.kind,
          attempt: intAttribute("attempt", in: event),
          inputTokens: intAttribute("input_tokens", in: event),
          outputTokens: intAttribute("output_tokens", in: event),
          transcriptEntries: intAttribute("transcript_entries", in: event),
          errorType: event.attributes["error_type"]
        )
      )
    case .pluginPreparationStarted,
      .pluginPreparationCompleted,
      .pluginPreparationFailed,
      .pluginCompletionStarted,
      .pluginCompletionCompleted,
      .pluginCompletionFailed,
      .pluginEvent,
      .profileToolAuditBestEffort:
      return .plugin(
        CoreAgentDeepPluginProjectedEvent(
          eventKind: event.kind,
          plugin: event.attributes["plugin"],
          pluginEvent: event.attributes["plugin_event"],
          errorType: event.attributes["error_type"]
        )
      )
    case .toolInterventionStarted,
      .toolInterventionApproved,
      .toolInterventionEdited,
      .toolInterventionRejected,
      .toolInterventionResponded,
      .toolInterventionCancelled,
      .toolInterventionFailed:
      return .hitl(
        CoreAgentDeepHITLProjectedEvent(
          eventKind: event.kind,
          toolName: event.attributes["tool"],
          toolInvocationID: uuidAttribute(["invocation_id", "tool_invocation_id"], in: event),
          manifestDigest: event.attributes["manifest_digest"],
          argumentsSource: event.attributes["arguments_source"],
          requestedArgumentsDigest: event.attributes["requested_arguments_digest"],
          executedArgumentsDigest: event.attributes["executed_arguments_digest"],
          originalArgumentsDigest: event.attributes["original_arguments_digest"],
          editedArgumentsDigest: event.attributes["edited_arguments_digest"],
          errorType: event.attributes["error_type"]
        )
      )
    case .toolAuthorizationStarted,
      .toolAuthorizationSucceeded,
      .toolAuthorizationDenied,
      .toolAuthorizationCancelled,
      .toolAuthorizationFailed,
      .toolExecutionStarted,
      .toolExecutionCompleted,
      .toolExecutionFailed:
      return .tool(
        CoreAgentDeepToolProjectedEvent(
          eventKind: event.kind,
          toolName: event.attributes["tool"],
          toolInvocationID: uuidAttribute(["invocation_id", "tool_invocation_id"], in: event),
          manifestDigest: event.attributes["manifest_digest"],
          argumentsSource: event.attributes["arguments_source"],
          requestedArgumentsDigest: event.attributes["requested_arguments_digest"],
          executedArgumentsDigest: event.attributes["executed_arguments_digest"],
          duration: event.attributes["duration"],
          errorType: event.attributes["error_type"]
        )
      )
    case .nativeToolCallRecorded, .nativeToolOutputRecorded:
      return .nativeTool(
        CoreAgentDeepNativeToolProjectedEvent(
          eventKind: event.kind,
          toolName: event.attributes["tool"],
          nativeToolCallID: event.attributes["native_call_id"],
          toolInvocationID: uuidAttribute(["tool_invocation_id", "invocation_id"], in: event),
          outputSource: event.attributes["output_source"],
          argumentsSource: event.attributes["arguments_source"],
          requestedArgumentsDigest: event.attributes["requested_arguments_digest"],
          executedArgumentsDigest: event.attributes["executed_arguments_digest"]
        )
      )
    case .transcriptCheckpointed,
      .transcriptCheckpointFailed,
      .transcriptActiveSessionCompacted:
      return .checkpoint(
        CoreAgentDeepCheckpointProjectedEvent(
          eventKind: event.kind,
          historyEntryCount: intAttribute("history_entries", in: event),
          artifactCount: intAttribute("artifacts", in: event),
          errorType: event.attributes["error_type"]
        )
      )
    }
  }

  private static func runStatus(for eventKind: CoreAgentEventKind) -> CoreAgentDeepRunStatus? {
    switch eventKind {
    case .runStarted:
      .started
    case .runCompleted:
      .completed
    case .runFailed:
      .failed
    default:
      nil
    }
  }

  private static func intAttribute(_ key: String, in event: CoreAgentEvent) -> Int? {
    guard let value = event.attributes[key] else { return nil }
    return Int(value)
  }

  private static func uuidAttribute(_ keys: [String], in event: CoreAgentEvent) -> UUID? {
    for key in keys {
      if let value = event.attributes[key], let uuid = UUID(uuidString: value) {
        return uuid
      }
    }
    return nil
  }

  private static func projectedActions(
    in bundle: CoreAgentDeepHITLReviewBundle
  ) -> [CoreAgentDeepGraphInterruptActionProjectedEvent] {
    zip(bundle.actionRequests, bundle.reviewConfigs).map { action, config in
      CoreAgentDeepGraphInterruptActionProjectedEvent(
        toolCallID: action.toolCallID,
        actionName: action.name,
        allowedDecisions: config.allowedDecisions
      )
    }
  }
}
