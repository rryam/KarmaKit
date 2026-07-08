import CoreAgent
import Foundation
import FoundationModels

public struct CoreAgentDeepRLMSubtask: Codable, Equatable, Sendable {
  public let description: String
  public let subagentType: String

  public init(description: String, subagentType: String) {
    self.description = description
    self.subagentType = subagentType
  }
}

public struct CoreAgentDeepRLMDecompositionRequest: Sendable {
  public let task: String
  public let availableSubagents: [CoreAgentDeepSubagentDescriptor]
  public let budget: CoreAgentDeepSubagentBudgetState

  public init(
    task: String,
    availableSubagents: [CoreAgentDeepSubagentDescriptor],
    budget: CoreAgentDeepSubagentBudgetState
  ) {
    self.task = task
    self.availableSubagents = availableSubagents
    self.budget = budget
  }
}

public protocol CoreAgentDeepRLMDecomposer: Sendable {
  func decompose(_ request: CoreAgentDeepRLMDecompositionRequest) async throws
    -> [CoreAgentDeepRLMSubtask]
}

public struct ClosureCoreAgentDeepRLMDecomposer: CoreAgentDeepRLMDecomposer {
  private let handler:
    @Sendable (CoreAgentDeepRLMDecompositionRequest) async throws -> [CoreAgentDeepRLMSubtask]

  public init(
    _ handler:
      @escaping @Sendable (CoreAgentDeepRLMDecompositionRequest) async throws
        -> [CoreAgentDeepRLMSubtask]
  ) {
    self.handler = handler
  }

  public func decompose(_ request: CoreAgentDeepRLMDecompositionRequest) async throws
    -> [CoreAgentDeepRLMSubtask]
  {
    try await handler(request)
  }
}

public enum CoreAgentDeepRLMCompletionStatus: String, Codable, Equatable, Sendable {
  case completed
  case budgetExceeded
  case decompositionFailed
}

public struct CoreAgentDeepRLMSubtaskResult: Codable, Equatable, Sendable {
  public let subtask: CoreAgentDeepRLMSubtask
  public let output: String
  public let status: CoreAgentDeepSubagentRunStatus

  public init(
    subtask: CoreAgentDeepRLMSubtask,
    output: String,
    status: CoreAgentDeepSubagentRunStatus
  ) {
    self.subtask = subtask
    self.output = output
    self.status = status
  }
}

public struct CoreAgentDeepRLMResult: Sendable {
  public let summary: String
  public let subtaskResults: [CoreAgentDeepRLMSubtaskResult]
  public let status: CoreAgentDeepRLMCompletionStatus
  public let budget: CoreAgentDeepSubagentBudgetState

  public init(
    summary: String,
    subtaskResults: [CoreAgentDeepRLMSubtaskResult],
    status: CoreAgentDeepRLMCompletionStatus,
    budget: CoreAgentDeepSubagentBudgetState
  ) {
    self.summary = summary
    self.subtaskResults = subtaskResults
    self.status = status
    self.budget = budget
  }
}

public struct CoreAgentDeepRLMOrchestrator: Sendable {
  public let decomposer: any CoreAgentDeepRLMDecomposer
  public let taskTool: CoreAgentDeepTaskTool
  public let budget: CoreAgentDeepSubagentBudget

  public init(
    decomposer: any CoreAgentDeepRLMDecomposer,
    taskTool: CoreAgentDeepTaskTool,
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault
  ) {
    self.decomposer = decomposer
    self.taskTool = taskTool
    self.budget = budget
  }

  public func run(task: String) async throws -> CoreAgentDeepRLMResult {
    let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTask.isEmpty else {
      throw CoreAgentDeepSubagentError.emptyDescription
    }

    let availableSubagents = await taskTool.refreshedDescriptors()
    let initialBudget = CoreAgentDeepSubagentBudgetState(
      depth: 0,
      maximumDepth: budget.maximumDepth,
      delegationsUsed: 0,
      maximumDelegations: budget.maximumDelegations,
      totalTokensUsed: 0,
      maximumTotalTokens: budget.maximumTotalTokens
    )
    let subtasks: [CoreAgentDeepRLMSubtask]
    do {
      subtasks = try await decomposer.decompose(
        CoreAgentDeepRLMDecompositionRequest(
          task: trimmedTask,
          availableSubagents: availableSubagents,
          budget: initialBudget
        )
      )
    } catch {
      return CoreAgentDeepRLMResult(
        summary: "",
        subtaskResults: [],
        status: .decompositionFailed,
        budget: initialBudget
      )
    }

    guard !subtasks.isEmpty else {
      return CoreAgentDeepRLMResult(
        summary: trimmedTask,
        subtaskResults: [],
        status: .completed,
        budget: initialBudget
      )
    }

    if let maximumDelegations = budget.maximumDelegations,
      subtasks.count > maximumDelegations
    {
      return CoreAgentDeepRLMResult(
        summary: "",
        subtaskResults: [],
        status: .budgetExceeded,
        budget: initialBudget
      )
    }

    var results: [CoreAgentDeepRLMSubtaskResult] = []
    for subtask in subtasks {
      let output: String
      do {
        output = try await taskTool.call(
          arguments: CoreAgentDeepTaskArguments(
            description: subtask.description,
            subagent_type: subtask.subagentType
          )
        )
      } catch is CoreAgentDeepSubagentBudgetError {
        return CoreAgentDeepRLMResult(
          summary: joinedSummary(results),
          subtaskResults: results,
          status: .budgetExceeded,
          budget: CoreAgentDeepSubagentBudgetState(
            depth: 1,
            maximumDepth: budget.maximumDepth,
            delegationsUsed: results.count,
            maximumDelegations: budget.maximumDelegations,
      totalTokensUsed: 0,
      maximumTotalTokens: budget.maximumTotalTokens
          )
        )
      }
      results.append(
        CoreAgentDeepRLMSubtaskResult(
          subtask: subtask,
          output: output,
          status: .completed
        )
      )
    }

    return CoreAgentDeepRLMResult(
      summary: joinedSummary(results),
      subtaskResults: results,
      status: .completed,
      budget: CoreAgentDeepSubagentBudgetState(
        depth: 1,
        maximumDepth: budget.maximumDepth,
        delegationsUsed: results.count,
        maximumDelegations: budget.maximumDelegations,
      totalTokensUsed: 0,
      maximumTotalTokens: budget.maximumTotalTokens
      )
    )
  }

  private func joinedSummary(_ results: [CoreAgentDeepRLMSubtaskResult]) -> String {
    results.map { "[\($0.subtask.subagentType)]\n\($0.output)" }.joined(separator: "\n\n")
  }
}

@Generable
private struct CoreAgentDeepFoundationModelsRLMSubtaskDraft: Sendable {
  let description: String
  let subagentType: String
}

@Generable
private struct CoreAgentDeepFoundationModelsRLMEnvelope: Sendable {
  let subtasks: [CoreAgentDeepFoundationModelsRLMSubtaskDraft]
}

public struct CoreAgentDeepFoundationModelsRLMDecomposer: CoreAgentDeepRLMDecomposer {
  private let session: CoreAgentSession

  public init(session: CoreAgentSession) {
    self.session = session
  }

  public func decompose(_ request: CoreAgentDeepRLMDecompositionRequest) async throws
    -> [CoreAgentDeepRLMSubtask]
  {
    let response = try await session.respond(
      to: Self.prompt(for: request),
      generating: CoreAgentDeepFoundationModelsRLMEnvelope.self
    )
    return try Self.subtasks(from: response.content, request: request)
  }

  private static func prompt(for request: CoreAgentDeepRLMDecompositionRequest) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let available = request.availableSubagents.map { ["name": $0.name, "description": $0.description] }
    let availableJSON = (try? String(data: encoder.encode(available), encoding: .utf8)) ?? "[]"
    let budgetJSON: String
    if let maximumDelegations = request.budget.maximumDelegations {
      budgetJSON = "{\"maximumDelegations\": \(maximumDelegations)}"
    } else {
      budgetJSON = "{\"maximumDelegations\": null}"
    }
    return """
      Decompose the task into an ordered list of subtasks for registered subagents.
      Use only subagent_type values from the available subagents list.
      Respect the delegation budget and return at most maximumDelegations subtasks when set.
      Task:
      \(request.task)
      Available subagents JSON:
      \(availableJSON)
      Budget JSON:
      \(budgetJSON)
      """
  }

  private static func subtasks(
    from envelope: CoreAgentDeepFoundationModelsRLMEnvelope,
    request: CoreAgentDeepRLMDecompositionRequest
  ) throws -> [CoreAgentDeepRLMSubtask] {
    let allowed = Set(request.availableSubagents.map(\.name))
    var seen: Set<String> = []
    var subtasks: [CoreAgentDeepRLMSubtask] = []
    for draft in envelope.subtasks {
      let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
      let subagentType = draft.subagentType.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !description.isEmpty, !subagentType.isEmpty else { continue }
      guard allowed.contains(subagentType) else {
        continue  // skip unknown subagent types from model output
      }
      guard seen.insert(subagentType).inserted else { continue }
      subtasks.append(CoreAgentDeepRLMSubtask(description: description, subagentType: subagentType))
      if let maximumDelegations = request.budget.maximumDelegations,
        subtasks.count > maximumDelegations
      {
        throw CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(maximumDelegations: maximumDelegations)
      }
    }
    return subtasks
  }
}
