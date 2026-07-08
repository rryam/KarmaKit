import CoreAgent
import CryptoKit
import Foundation
import FoundationModels

@Generable
public struct CoreAgentDeepTaskArguments: Sendable {
  public let description: String
  // swift-format-ignore: AlwaysUseLowerCamelCase
  public let subagent_type: String

  public init(description: String, subagent_type: String) {
    self.description = description
    self.subagent_type = subagent_type
  }

  public var subagentType: String {
    subagent_type
  }
}

public struct CoreAgentDeepTaskTool: Tool, CoreAgentRunLifecycleTool {
  public let name = "task"
  public let description: String
  public let auditStore: CoreAgentDeepSubagentAuditStore

  private let registry: CoreAgentDeepSubagentApprovedRegistry
  private let descriptors: [CoreAgentDeepSubagentDescriptor]
  private let auditConfiguration: CoreAgentDeepSubagentAuditConfiguration
  private let budget: CoreAgentDeepSubagentBudget
  private let budgetRegistry = CoreAgentDeepSubagentBudgetRegistry()
  private let directBudgetRootID = UUID()

  public init(
    subagents: [any CoreAgentDeepSubagent],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault,
    description: String? = nil
  ) throws {
    self.descriptors = try Self.sortedDescriptors(from: subagents)
    self.registry = try CoreAgentDeepSubagentApprovedRegistry(staticSubagents: subagents)
    self.auditStore = auditStore
    self.auditConfiguration = auditConfiguration
    self.budget = budget
    self.description = description ?? Self.defaultDescription(descriptors: descriptors)
  }

  public init(
    registry: CoreAgentDeepSubagentApprovedRegistry,
    descriptors: [CoreAgentDeepSubagentDescriptor],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault,
    description: String? = nil
  ) {
    self.registry = registry
    self.descriptors = descriptors.sorted { $0.name < $1.name }
    self.auditStore = auditStore
    self.auditConfiguration = auditConfiguration
    self.budget = budget
    self.description = description ?? Self.defaultDescription(descriptors: self.descriptors)
  }

  public func availableSubagents() -> [CoreAgentDeepSubagentDescriptor] {
    descriptors
  }

  public func refreshedDescriptors() async -> [CoreAgentDeepSubagentDescriptor] {
    await registry.availableDescriptors()
  }

  public func coreAgentRunDidFinish(_ runID: UUID) async {
    await resetBudget(for: runID)
  }

  public func resetBudget(for rootID: UUID) async {
    await budgetRegistry.removeTracker(for: rootID)
  }

  public func resetBudgetScopes() async {
    await budgetRegistry.removeAll()
  }

  public func activeBudgetScopeCount() async -> Int {
    await budgetRegistry.count()
  }

  @concurrent
  public func call(arguments: CoreAgentDeepTaskArguments) async throws -> String {
    let requestedType = arguments.subagent_type.trimmingCharacters(in: .whitespacesAndNewlines)
    let taskDescription = arguments.description.trimmingCharacters(in: .whitespacesAndNewlines)
    let auditDescription = auditConfiguration.summarize(description: taskDescription)
    let invocation = CoreAgentToolInvocation.current
    let taskID = invocation?.invocationID ?? UUID()
    guard !taskDescription.isEmpty else {
      await appendAuditRecord(
        id: taskID,
        subagentName: CoreAgentDeepSubagentIdentifier.sanitized(
          requestedType,
          fallback: "unknown"
        ),
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: "Task description is empty.",
        errorType: String(reflecting: CoreAgentDeepSubagentError.self),
        startedAt: Date(),
        endedAt: Date()
      )
      throw CoreAgentDeepSubagentError.emptyDescription
    }

    let startedAt = Date()
    let activeBudget = CoreAgentDeepSubagentBudgetContext.current
    let attemptedDepth = (activeBudget?.state.depth ?? 0) + 1
    let budgetTracker: CoreAgentDeepSubagentBudgetTracker
    if let activeBudget {
      budgetTracker = activeBudget.tracker
    } else {
      let rootID = invocation?.runID ?? directBudgetRootID
      budgetTracker = await budgetRegistry.tracker(for: rootID, budget: budget)
    }
    let budgetState: CoreAgentDeepSubagentBudgetState
    do {
      budgetState = try await budgetTracker.reserve(attemptedDepth: attemptedDepth)
    } catch {
      await appendAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: auditConfiguration.summarize(error: error),
        errorType: auditConfiguration.errorType(for: error),
        budget: budgetStateForDeniedBudgetError(
          error,
          attemptedDepth: attemptedDepth,
          inheritedState: activeBudget?.state
        ),
        startedAt: startedAt,
        endedAt: Date()
      )
      throw error
    }
    guard let subagent = await registry.subagent(named: requestedType) else {
      await appendAuditRecord(
        id: taskID,
        subagentName: CoreAgentDeepSubagentIdentifier.sanitized(
          requestedType,
          fallback: "unknown"
        ),
        description: auditDescription,
        parentRunID: invocation?.runID,
        parentToolInvocationID: invocation?.invocationID,
        status: .denied,
        errorDescription: "Requested subagent is not registered.",
        errorType: nil,
        budget: budgetState,
        startedAt: startedAt,
        endedAt: Date()
      )
      return unavailableSubagentMessage(requestedType)
    }

    let request = CoreAgentDeepSubagentRequest(
      taskID: taskID,
      subagentType: requestedType,
      description: taskDescription,
      parentRunID: invocation?.runID,
      parentToolInvocationID: invocation?.invocationID,
      budget: budgetState
    )
    let result: CoreAgentDeepSubagentResult
    do {
      result = try await CoreAgentDeepSubagentBudgetContext.$current.withValue(
        CoreAgentDeepSubagentBudgetContext.Active(
          state: budgetState,
          tracker: budgetTracker
        )
      ) {
        try await subagent.run(request: request)
      }
    } catch {
      let endedAt = Date()
      let failure = error as? CoreAgentDeepSubagentFailure
      await auditStore.append(
        CoreAgentDeepSubagentAuditRecord(
          id: taskID,
          subagentName: requestedType,
          description: auditDescription,
          parentRunID: request.parentRunID,
          parentToolInvocationID: request.parentToolInvocationID,
          childRunID: failure?.childRunID,
          childReceiptRootHash: failure?.childReceiptRootHash,
          checkpointKey: failure?.checkpointKey,
          status: .failed,
          errorDescription: auditConfiguration.summarize(error: error),
          errorType: auditConfiguration.errorType(for: error),
          outputCharacterCount: nil,
          budget: budgetState,
          startedAt: startedAt,
          endedAt: endedAt
        )
      )
      throw error
    }

    let recordedBudgetState: CoreAgentDeepSubagentBudgetState
    do {
      recordedBudgetState = try await budgetTracker.recordUsage(
        result.usage,
        depth: budgetState.depth
      )
    } catch {
      let endedAt = Date()
      let budgetAfterFailure = await budgetTracker.currentState(depth: budgetState.depth)
      await appendAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: request.parentRunID,
        parentToolInvocationID: request.parentToolInvocationID,
        status: .failed,
        errorDescription: auditConfiguration.summarize(error: error),
        errorType: auditConfiguration.errorType(for: error),
        budget: budgetAfterFailure,
        startedAt: startedAt,
        endedAt: endedAt
      )
      throw error
    }

    let endedAt = Date()
    await auditStore.append(
      CoreAgentDeepSubagentAuditRecord(
        id: taskID,
        subagentName: requestedType,
        description: auditDescription,
        parentRunID: request.parentRunID,
        parentToolInvocationID: request.parentToolInvocationID,
        childRunID: result.childRunID,
        childReceiptRootHash: result.childReceiptRootHash,
        checkpointKey: result.checkpointKey,
        status: .completed,
        errorDescription: nil,
        errorType: nil,
        outputCharacterCount: result.content.count,
        budget: recordedBudgetState,
        startedAt: startedAt,
        endedAt: endedAt
      )
    )
    return resultMessage(for: result, canonicalSubagentName: requestedType)
  }

  private static func sortedDescriptors(
    from subagents: [any CoreAgentDeepSubagent]
  ) throws -> [CoreAgentDeepSubagentDescriptor] {
    var byName: [String: CoreAgentDeepSubagentDescriptor] = [:]
    for subagent in subagents {
      let name = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw CoreAgentDeepSubagentError.emptyName
      }
      guard CoreAgentDeepSubagentIdentifier.isValid(name) else {
        throw CoreAgentDeepSubagentError.invalidName(name)
      }
      guard byName[name] == nil else {
        throw CoreAgentDeepSubagentError.duplicateName(name)
      }
      byName[name] = CoreAgentDeepSubagentDescriptor(
        name: name,
        description: subagent.description
      )
    }
    return byName.values.sorted { $0.name < $1.name }
  }

  private static func defaultDescription(
    descriptors: [CoreAgentDeepSubagentDescriptor]
  ) -> String {
    let agents =
      descriptors
      .map { "- \($0.name): \($0.description)" }
      .joined(separator: "\n")
    return """
      Launches a short-lived isolated subagent and returns one final result.
      Use this for complex, independent tasks where intermediate tool calls should stay out of the parent context.
      Arguments: description, subagent_type.

      Available subagent types:
      \(agents)
      """
  }

  private func unavailableSubagentMessage(_ requestedType: String) -> String {
    let allowed = descriptors.map(\.name).joined(separator: ", ")
    return """
      COREAGENT_DEEP_SUBAGENT_UNAVAILABLE_V1 requested=\(CoreAgentDeepSubagentIdentifier.sanitized(requestedType, fallback: "unknown"))
      Allowed subagent types: \(allowed)
      """
  }

  private func resultMessage(
    for result: CoreAgentDeepSubagentResult,
    canonicalSubagentName: String
  ) -> String {
    var metadata = [
      "COREAGENT_DEEP_SUBAGENT_RESULT_V1 subagent=\(canonicalSubagentName)"
    ]
    if let childRunID = result.childRunID {
      metadata.append("child_run_id=\(childRunID.uuidString.lowercased())")
    }
    if let childReceiptRootHash = result.childReceiptRootHash {
      metadata.append("child_receipt_root_hash=\(childReceiptRootHash)")
    }
    if let checkpointKey = result.checkpointKey {
      metadata.append("checkpoint_key=\(checkpointKey)")
    }
    return """
      \(metadata.joined(separator: " "))
      \(result.content)
      """
  }

  private func appendAuditRecord(
    id: UUID,
    subagentName: String,
    description: String,
    parentRunID: UUID?,
    parentToolInvocationID: UUID?,
    status: CoreAgentDeepSubagentRunStatus,
    errorDescription: String?,
    errorType: String?,
    budget: CoreAgentDeepSubagentBudgetState? = nil,
    startedAt: Date,
    endedAt: Date
  ) async {
    await auditStore.append(
      CoreAgentDeepSubagentAuditRecord(
        id: id,
        subagentName: subagentName,
        description: description,
        parentRunID: parentRunID,
        parentToolInvocationID: parentToolInvocationID,
        childRunID: nil,
        childReceiptRootHash: nil,
        checkpointKey: nil,
        status: status,
        errorDescription: errorDescription,
        errorType: errorType,
        outputCharacterCount: nil,
        budget: budget,
        startedAt: startedAt,
        endedAt: endedAt
      )
    )
  }

  private func budgetStateForDeniedBudgetError(
    _ error: any Error,
    attemptedDepth: Int,
    inheritedState: CoreAgentDeepSubagentBudgetState?
  ) -> CoreAgentDeepSubagentBudgetState? {
    switch error {
    case .maxDepthExceeded(let maximumDepth, _) as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: maximumDepth,
        delegationsUsed: inheritedState?.delegationsUsed ?? 0,
        maximumDelegations: inheritedState?.maximumDelegations ?? budget.maximumDelegations,
        totalTokensUsed: inheritedState?.totalTokensUsed ?? 0,
        maximumTotalTokens: inheritedState?.maximumTotalTokens ?? budget.maximumTotalTokens
      )
    case .delegationLimitExceeded(let maximumDelegations) as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: inheritedState?.maximumDepth ?? budget.maximumDepth,
        delegationsUsed: maximumDelegations,
        maximumDelegations: maximumDelegations,
        totalTokensUsed: inheritedState?.totalTokensUsed ?? 0,
        maximumTotalTokens: inheritedState?.maximumTotalTokens ?? budget.maximumTotalTokens
      )
    case .tokenBudgetExceeded(let maximumTotalTokens, let totalTokensUsed)
      as CoreAgentDeepSubagentBudgetError:
      CoreAgentDeepSubagentBudgetState(
        depth: attemptedDepth,
        maximumDepth: inheritedState?.maximumDepth ?? budget.maximumDepth,
        delegationsUsed: inheritedState?.delegationsUsed ?? 0,
        maximumDelegations: inheritedState?.maximumDelegations ?? budget.maximumDelegations,
        totalTokensUsed: totalTokensUsed,
        maximumTotalTokens: maximumTotalTokens
      )
    default:
      nil
    }
  }
}

public struct CoreAgentDeepSubagentsPlugin: CoreAgentSessionPlugin {
  public let identifier: String
  public let taskTool: CoreAgentDeepTaskTool

  public var tools: [any Tool] {
    [taskTool]
  }

  public init(
    identifier: String = "coreagent.deep.subagents",
    subagents: [any CoreAgentDeepSubagent],
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault
  ) throws {
    self.identifier = identifier
    self.taskTool = try CoreAgentDeepTaskTool(
      subagents: subagents,
      auditStore: auditStore,
      auditConfiguration: auditConfiguration,
      budget: budget
    )
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    await taskTool.resetBudget(for: completion.runID)
    return []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    await taskTool.resetBudget(for: failure.runID)
    return []
  }
}
