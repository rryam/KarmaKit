import CoreAgent
import CoreAgentGraph
import Foundation

public enum CoreAgentDeepProjectedEventSource: String, Codable, Equatable, Sendable {
  case coreAgentEvent
  case filesystemAudit
  case toolResultOffload
  case subagentAudit
  case subagentProposal
  case rubricEvaluation
  case todoSnapshot
  case graphInterrupt
  case graphCheckpoint
}

public struct CoreAgentDeepProjectedEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let sequence: Int
  public let source: CoreAgentDeepProjectedEventSource
  public let timestamp: Date?
  public let payload: CoreAgentDeepProjectedEventPayload

  public init(
    id: String,
    sequence: Int,
    source: CoreAgentDeepProjectedEventSource,
    timestamp: Date? = nil,
    payload: CoreAgentDeepProjectedEventPayload
  ) {
    self.id = id
    self.sequence = sequence
    self.source = source
    self.timestamp = timestamp
    self.payload = payload
  }
}

public enum CoreAgentDeepProjectedEventPayload: Codable, Equatable, Sendable {
  case run(CoreAgentDeepRunProjectedEvent)
  case model(CoreAgentDeepModelProjectedEvent)
  case plugin(CoreAgentDeepPluginProjectedEvent)
  case hitl(CoreAgentDeepHITLProjectedEvent)
  case tool(CoreAgentDeepToolProjectedEvent)
  case nativeTool(CoreAgentDeepNativeToolProjectedEvent)
  case checkpoint(CoreAgentDeepCheckpointProjectedEvent)
  case filesystem(CoreAgentDeepFilesystemProjectedEvent)
  case offload(CoreAgentDeepOffloadProjectedEvent)
  case subagent(CoreAgentDeepSubagentProjectedEvent)
  case subagentProposal(CoreAgentDeepSubagentProposalProjectedEvent)
  case rubric(CoreAgentDeepRubricProjectedEvent)
  case todo(CoreAgentDeepTodoProjectedEvent)
  case graphInterrupt(CoreAgentDeepGraphInterruptProjectedEvent)
  case graphCheckpoint(CoreAgentDeepGraphCheckpointProjectedEvent)
}

public enum CoreAgentDeepRunStatus: String, Codable, Equatable, Sendable {
  case started
  case completed
  case failed
}

public struct CoreAgentDeepRunProjectedEvent: Codable, Equatable, Sendable {
  public let runID: UUID
  public let eventKind: CoreAgentEventKind
  public let status: CoreAgentDeepRunStatus?
  public let errorType: String?

  public init(
    runID: UUID,
    eventKind: CoreAgentEventKind,
    status: CoreAgentDeepRunStatus?,
    errorType: String? = nil
  ) {
    self.runID = runID
    self.eventKind = eventKind
    self.status = status
    self.errorType = errorType
  }
}

public struct CoreAgentDeepModelProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let attempt: Int?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let transcriptEntries: Int?
  public let errorType: String?

  public init(
    eventKind: CoreAgentEventKind,
    attempt: Int? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    transcriptEntries: Int? = nil,
    errorType: String? = nil
  ) {
    self.eventKind = eventKind
    self.attempt = attempt
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.transcriptEntries = transcriptEntries
    self.errorType = errorType
  }
}

public struct CoreAgentDeepPluginProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let plugin: String?
  public let pluginEvent: String?
  public let errorType: String?

  public init(
    eventKind: CoreAgentEventKind,
    plugin: String? = nil,
    pluginEvent: String? = nil,
    errorType: String? = nil
  ) {
    self.eventKind = eventKind
    self.plugin = plugin
    self.pluginEvent = pluginEvent
    self.errorType = errorType
  }
}

public struct CoreAgentDeepHITLProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let toolName: String?
  public let toolInvocationID: UUID?
  public let manifestDigest: String?
  public let argumentsSource: String?
  public let requestedArgumentsDigest: String?
  public let executedArgumentsDigest: String?
  public let originalArgumentsDigest: String?
  public let editedArgumentsDigest: String?
  public let errorType: String?

  public init(
    eventKind: CoreAgentEventKind,
    toolName: String? = nil,
    toolInvocationID: UUID? = nil,
    manifestDigest: String? = nil,
    argumentsSource: String? = nil,
    requestedArgumentsDigest: String? = nil,
    executedArgumentsDigest: String? = nil,
    originalArgumentsDigest: String? = nil,
    editedArgumentsDigest: String? = nil,
    errorType: String? = nil
  ) {
    self.eventKind = eventKind
    self.toolName = toolName
    self.toolInvocationID = toolInvocationID
    self.manifestDigest = manifestDigest
    self.argumentsSource = argumentsSource
    self.requestedArgumentsDigest = requestedArgumentsDigest
    self.executedArgumentsDigest = executedArgumentsDigest
    self.originalArgumentsDigest = originalArgumentsDigest
    self.editedArgumentsDigest = editedArgumentsDigest
    self.errorType = errorType
  }
}

public struct CoreAgentDeepToolProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let toolName: String?
  public let toolInvocationID: UUID?
  public let manifestDigest: String?
  public let argumentsSource: String?
  public let requestedArgumentsDigest: String?
  public let executedArgumentsDigest: String?
  public let duration: String?
  public let errorType: String?

  public init(
    eventKind: CoreAgentEventKind,
    toolName: String? = nil,
    toolInvocationID: UUID? = nil,
    manifestDigest: String? = nil,
    argumentsSource: String? = nil,
    requestedArgumentsDigest: String? = nil,
    executedArgumentsDigest: String? = nil,
    duration: String? = nil,
    errorType: String? = nil
  ) {
    self.eventKind = eventKind
    self.toolName = toolName
    self.toolInvocationID = toolInvocationID
    self.manifestDigest = manifestDigest
    self.argumentsSource = argumentsSource
    self.requestedArgumentsDigest = requestedArgumentsDigest
    self.executedArgumentsDigest = executedArgumentsDigest
    self.duration = duration
    self.errorType = errorType
  }
}

public struct CoreAgentDeepNativeToolProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let toolName: String?
  public let nativeToolCallID: String?
  public let toolInvocationID: UUID?
  public let outputSource: String?
  public let argumentsSource: String?
  public let requestedArgumentsDigest: String?
  public let executedArgumentsDigest: String?

  public init(
    eventKind: CoreAgentEventKind,
    toolName: String? = nil,
    nativeToolCallID: String? = nil,
    toolInvocationID: UUID? = nil,
    outputSource: String? = nil,
    argumentsSource: String? = nil,
    requestedArgumentsDigest: String? = nil,
    executedArgumentsDigest: String? = nil
  ) {
    self.eventKind = eventKind
    self.toolName = toolName
    self.nativeToolCallID = nativeToolCallID
    self.toolInvocationID = toolInvocationID
    self.outputSource = outputSource
    self.argumentsSource = argumentsSource
    self.requestedArgumentsDigest = requestedArgumentsDigest
    self.executedArgumentsDigest = executedArgumentsDigest
  }
}

public struct CoreAgentDeepCheckpointProjectedEvent: Codable, Equatable, Sendable {
  public let eventKind: CoreAgentEventKind
  public let historyEntryCount: Int?
  public let artifactCount: Int?
  public let errorType: String?

  public init(
    eventKind: CoreAgentEventKind,
    historyEntryCount: Int? = nil,
    artifactCount: Int? = nil,
    errorType: String? = nil
  ) {
    self.eventKind = eventKind
    self.historyEntryCount = historyEntryCount
    self.artifactCount = artifactCount
    self.errorType = errorType
  }
}

public struct CoreAgentDeepFilesystemProjectedEvent: Codable, Equatable, Sendable {
  public let operation: CoreAgentDeepFilesystemOperation
  public let path: String
  public let decision: CoreAgentDeepFilesystemAuditDecision
  public let ruleIndex: Int?

  public init(
    operation: CoreAgentDeepFilesystemOperation,
    path: String,
    decision: CoreAgentDeepFilesystemAuditDecision,
    ruleIndex: Int? = nil
  ) {
    self.operation = operation
    self.path = path
    self.decision = decision
    self.ruleIndex = ruleIndex
  }
}

public struct CoreAgentDeepOffloadProjectedEvent: Codable, Equatable, Sendable {
  public let path: String
  public let originalCharacterCount: Int

  public init(path: String, originalCharacterCount: Int) {
    self.path = path
    self.originalCharacterCount = originalCharacterCount
  }
}

public struct CoreAgentDeepSubagentProjectedEvent: Codable, Equatable, Sendable {
  public let taskID: UUID
  public let subagentName: String
  public let parentRunID: UUID?
  public let parentToolInvocationID: UUID?
  public let childRunID: UUID?
  public let childReceiptRootHash: String?
  public let checkpointKey: String?
  public let status: CoreAgentDeepSubagentRunStatus
  public let errorType: String?
  public let outputCharacterCount: Int?
  public let budgetDepth: Int?
  public let budgetDelegationsUsed: Int?
  public let budgetMaximumDepth: Int?
  public let budgetMaximumDelegations: Int?

  public init(
    taskID: UUID,
    subagentName: String,
    parentRunID: UUID?,
    parentToolInvocationID: UUID?,
    childRunID: UUID?,
    childReceiptRootHash: String?,
    checkpointKey: String?,
    status: CoreAgentDeepSubagentRunStatus,
    errorType: String? = nil,
    outputCharacterCount: Int? = nil,
    budgetDepth: Int? = nil,
    budgetDelegationsUsed: Int? = nil,
    budgetMaximumDepth: Int? = nil,
    budgetMaximumDelegations: Int? = nil
  ) {
    self.taskID = taskID
    self.subagentName = subagentName
    self.parentRunID = parentRunID
    self.parentToolInvocationID = parentToolInvocationID
    self.childRunID = childRunID
    self.childReceiptRootHash = childReceiptRootHash
    self.checkpointKey = checkpointKey
    self.status = status
    self.errorType = errorType
    self.outputCharacterCount = outputCharacterCount
    self.budgetDepth = budgetDepth
    self.budgetDelegationsUsed = budgetDelegationsUsed
    self.budgetMaximumDepth = budgetMaximumDepth
    self.budgetMaximumDelegations = budgetMaximumDelegations
  }
}

public enum CoreAgentDeepSubagentProposalApprovalStatus: String, Codable, Equatable, Sendable {
  case proposed
  case approved
}

public struct CoreAgentDeepSubagentProposalProjectedEvent: Codable, Equatable, Sendable {
  public let proposalID: UUID
  public let name: String
  public let proposalDigest: String
  public let approvalStatus: CoreAgentDeepSubagentProposalApprovalStatus

  public init(
    proposalID: UUID,
    name: String,
    proposalDigest: String,
    approvalStatus: CoreAgentDeepSubagentProposalApprovalStatus
  ) {
    self.proposalID = proposalID
    self.name = name
    self.proposalDigest = proposalDigest
    self.approvalStatus = approvalStatus
  }
}

public struct CoreAgentDeepRubricProjectedEvent: Codable, Equatable, Sendable {
  public let iteration: Int
  public let verdict: CoreAgentDeepRubricVerdict
  public let passedCriteriaCount: Int
  public let failedCriteriaCount: Int
  public let completionStatus: CoreAgentDeepRubricCompletionStatus?

  public init(
    iteration: Int,
    verdict: CoreAgentDeepRubricVerdict,
    passedCriteriaCount: Int,
    failedCriteriaCount: Int,
    completionStatus: CoreAgentDeepRubricCompletionStatus? = nil
  ) {
    self.iteration = iteration
    self.verdict = verdict
    self.passedCriteriaCount = passedCriteriaCount
    self.failedCriteriaCount = failedCriteriaCount
    self.completionStatus = completionStatus
  }
}

public struct CoreAgentDeepTodoProjectedEvent: Codable, Equatable, Sendable {
  public let totalCount: Int
  public let statusCounts: [CoreAgentDeepTodoStatus: Int]

  public init(totalCount: Int, statusCounts: [CoreAgentDeepTodoStatus: Int]) {
    self.totalCount = totalCount
    self.statusCounts = statusCounts
  }
}

public struct CoreAgentDeepGraphInterruptEvidence: Codable, Equatable, Sendable {
  public let nodeID: CoreAgentGraphNodeID
  public let interruptID: CoreAgentGraphInterruptID
  public let step: Int
  public let reviewBundle: CoreAgentDeepHITLReviewBundle

  public init(
    nodeID: CoreAgentGraphNodeID,
    interruptID: CoreAgentGraphInterruptID,
    step: Int,
    reviewBundle: CoreAgentDeepHITLReviewBundle
  ) {
    self.nodeID = nodeID
    self.interruptID = interruptID
    self.step = step
    self.reviewBundle = reviewBundle
  }
}

public struct CoreAgentDeepGraphInterruptActionProjectedEvent:
  Codable, Equatable, Sendable
{
  public let toolCallID: String
  public let actionName: String
  public let allowedDecisions: Set<CoreAgentDeepHITLDecisionType>

  public init(
    toolCallID: String,
    actionName: String,
    allowedDecisions: Set<CoreAgentDeepHITLDecisionType>
  ) {
    self.toolCallID = toolCallID
    self.actionName = actionName
    self.allowedDecisions = allowedDecisions
  }
}

public struct CoreAgentDeepGraphInterruptProjectedEvent: Codable, Equatable, Sendable {
  public let nodeID: CoreAgentGraphNodeID
  public let interruptID: CoreAgentGraphInterruptID
  public let step: Int
  public let actions: [CoreAgentDeepGraphInterruptActionProjectedEvent]

  public var actionCount: Int {
    actions.count
  }

  public var allowedDecisionsByToolCallID: [String: Set<CoreAgentDeepHITLDecisionType>] {
    actions.reduce(into: [:]) { values, action in
      values[action.toolCallID] = action.allowedDecisions
    }
  }

  public init(
    nodeID: CoreAgentGraphNodeID,
    interruptID: CoreAgentGraphInterruptID,
    step: Int,
    actions: [CoreAgentDeepGraphInterruptActionProjectedEvent]
  ) {
    self.nodeID = nodeID
    self.interruptID = interruptID
    self.step = step
    self.actions = actions
  }
}

public struct CoreAgentDeepGraphCheckpointEvidence: Codable, Equatable, Sendable {
  public let checkpointID: CoreAgentGraphCheckpointID
  public let parentCheckpointID: CoreAgentGraphCheckpointID?
  public let threadID: CoreAgentGraphThreadID
  public let namespace: CoreAgentGraphCheckpointNamespace
  public let step: Int
  public let nextNodeIDs: [CoreAgentGraphNodeID]
  public let pendingWriteCount: Int

  public init(
    checkpointID: CoreAgentGraphCheckpointID,
    parentCheckpointID: CoreAgentGraphCheckpointID?,
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    step: Int,
    nextNodeIDs: [CoreAgentGraphNodeID],
    pendingWriteCount: Int
  ) {
    self.checkpointID = checkpointID
    self.parentCheckpointID = parentCheckpointID
    self.threadID = threadID
    self.namespace = namespace
    self.step = step
    self.nextNodeIDs = nextNodeIDs
    self.pendingWriteCount = pendingWriteCount
  }
}

public struct CoreAgentDeepGraphCheckpointProjectedEvent: Codable, Equatable, Sendable {
  public let checkpointID: CoreAgentGraphCheckpointID
  public let parentCheckpointID: CoreAgentGraphCheckpointID?
  public let threadID: CoreAgentGraphThreadID
  public let namespace: CoreAgentGraphCheckpointNamespace
  public let step: Int
  public let nextNodeIDs: [CoreAgentGraphNodeID]
  public let pendingWriteCount: Int

  public init(
    checkpointID: CoreAgentGraphCheckpointID,
    parentCheckpointID: CoreAgentGraphCheckpointID?,
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    step: Int,
    nextNodeIDs: [CoreAgentGraphNodeID],
    pendingWriteCount: Int
  ) {
    self.checkpointID = checkpointID
    self.parentCheckpointID = parentCheckpointID
    self.threadID = threadID
    self.namespace = namespace
    self.step = step
    self.nextNodeIDs = nextNodeIDs
    self.pendingWriteCount = pendingWriteCount
  }
}

public struct CoreAgentDeepEventProjection: Codable, Equatable, Sendable {
  public let runID: UUID?
  public let events: [CoreAgentDeepProjectedEvent]

  public init(runID: UUID?, events: [CoreAgentDeepProjectedEvent]) {
    self.runID = runID
    self.events = events
  }

  public var hitlEvents: [CoreAgentDeepHITLProjectedEvent] {
    events.compactMap {
      guard case .hitl(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var toolEvents: [CoreAgentDeepToolProjectedEvent] {
    events.compactMap {
      guard case .tool(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var nativeToolEvents: [CoreAgentDeepNativeToolProjectedEvent] {
    events.compactMap {
      guard case .nativeTool(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var checkpointEvents: [CoreAgentDeepCheckpointProjectedEvent] {
    events.compactMap {
      guard case .checkpoint(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var filesystemEvents: [CoreAgentDeepFilesystemProjectedEvent] {
    events.compactMap {
      guard case .filesystem(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var offloadEvents: [CoreAgentDeepOffloadProjectedEvent] {
    events.compactMap {
      guard case .offload(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var subagentEvents: [CoreAgentDeepSubagentProjectedEvent] {
    events.compactMap {
      guard case .subagent(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var subagentProposalEvents: [CoreAgentDeepSubagentProposalProjectedEvent] {
    events.compactMap {
      guard case .subagentProposal(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var rubricEvents: [CoreAgentDeepRubricProjectedEvent] {
    events.compactMap {
      guard case .rubric(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var todoEvents: [CoreAgentDeepTodoProjectedEvent] {
    events.compactMap {
      guard case .todo(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var graphInterruptEvents: [CoreAgentDeepGraphInterruptProjectedEvent] {
    events.compactMap {
      guard case .graphInterrupt(let event) = $0.payload else { return nil }
      return event
    }
  }

  public var graphCheckpointEvents: [CoreAgentDeepGraphCheckpointProjectedEvent] {
    events.compactMap {
      guard case .graphCheckpoint(let event) = $0.payload else { return nil }
      return event
    }
  }
}

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
      entries.append(contentsOf: run.events.enumerated().map { index, event in
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
