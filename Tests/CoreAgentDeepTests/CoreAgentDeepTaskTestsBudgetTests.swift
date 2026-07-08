import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentDeepTaskTests {
  @Test("Nested task calls fail closed when maximum depth is exceeded")
  func nestedTaskCallsFailClosedAtMaximumDepth() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let nestedCalls = CallCounter()
    let nestedTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "nested",
          description: "Nested worker.",
          handler: { request in
            await nestedCalls.increment()
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "must not run"
            )
          }
        )
      ],
      auditStore: auditStore
    )
    let outerTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Delegates recursively.",
          handler: { _ in
            _ = try await nestedTool.call(
              arguments: CoreAgentDeepTaskArguments(
                description: "Nested work.",
                subagent_type: "nested"
              )
            )
            return CoreAgentDeepSubagentResult(subagentName: "worker", content: "done")
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 5)
    )

    await #expect(
      throws: CoreAgentDeepSubagentBudgetError.maxDepthExceeded(
        maximumDepth: 1,
        attemptedDepth: 2
      )
    ) {
      _ = try await outerTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Delegate recursively.",
          subagent_type: "worker"
        )
      )
    }

    let records = await auditStore.records()
    #expect(await nestedCalls.value == 0)
    #expect(records.map(\.subagentName) == ["nested", "worker"])
    #expect(records.map(\.status) == [.denied, .failed])
    #expect(records.first?.budgetDepth == 2)
    #expect(records.first?.budgetDelegationsUsed == 1)
    #expect(records.first?.budgetMaximumDelegations == 5)
  }

  @Test("Nested task calls share the total delegation budget")
  func nestedTaskCallsShareDelegationBudget() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let nestedCalls = CallCounter()
    let nestedTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "nested",
          description: "Nested worker.",
          handler: { request in
            await nestedCalls.increment()
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "must not run"
            )
          }
        )
      ],
      auditStore: auditStore
    )
    let outerTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Delegates recursively.",
          handler: { _ in
            _ = try await nestedTool.call(
              arguments: CoreAgentDeepTaskArguments(
                description: "Nested work.",
                subagent_type: "nested"
              )
            )
            return CoreAgentDeepSubagentResult(subagentName: "worker", content: "done")
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 2, maximumDelegations: 1)
    )

    await #expect(
      throws: CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(
        maximumDelegations: 1
      )
    ) {
      _ = try await outerTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Delegate recursively.",
          subagent_type: "worker"
        )
      )
    }

    let records = await auditStore.records()
    #expect(await nestedCalls.value == 0)
    #expect(records.map(\.subagentName) == ["nested", "worker"])
    #expect(records.map(\.status) == [.denied, .failed])
    #expect(records.first?.budgetDepth == 2)
    #expect(records.first?.budgetDelegationsUsed == 1)
    #expect(records.first?.budgetMaximumDepth == 2)
  }

  @Test("Unknown subagents consume task attempt budget before valid delegation")
  func unknownSubagentsConsumeTaskAttemptBudget() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )

    let unavailable = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Try missing.",
        subagent_type: "missing"
      )
    )
    await #expect(
      throws: CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(
        maximumDelegations: 1
      )
    ) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Do work.",
          subagent_type: "worker"
        )
      )
    }

    #expect(unavailable.contains("COREAGENT_DEEP_SUBAGENT_UNAVAILABLE_V1"))
    let records = await auditStore.records()
    #expect(records.map(\.status) == [.denied, .denied])
    #expect(records.first?.budgetDelegationsUsed == 1)
    #expect(records.last?.budgetDelegationsUsed == 1)
  }

  @Test("Repeated direct task calls share one tool budget scope")
  func repeatedDirectTaskCallsShareBudgetScope() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let workerCalls = CallCounter()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            await workerCalls.increment()
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do first.",
        subagent_type: "worker"
      )
    )
    await #expect(
      throws: CoreAgentDeepSubagentBudgetError.delegationLimitExceeded(
        maximumDelegations: 1
      )
    ) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "Do second.",
          subagent_type: "worker"
        )
      )
    }

    let records = await auditStore.records()
    #expect(await workerCalls.value == 1)
    #expect(records.map(\.status) == [.completed, .denied])
    #expect(records.map(\.budgetDelegationsUsed) == [1, 1])
  }

  @Test("Subagents plugin forwards recursive budget configuration")
  func subagentsPluginForwardsBudgetConfiguration() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let plugin = try CoreAgentDeepSubagentsPlugin(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            #expect(request.budget?.maximumDepth == 1)
            #expect(request.budget?.maximumDelegations == 1)
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "task",
        argumentsJSON: #"{"description":"Do work.","subagent_type":"worker"}"#
      ),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(model: model, plugins: [plugin])

    _ = try await session.respond(to: "Delegate.")

    let record = try #require(await auditStore.records().first)
    #expect(record.budgetMaximumDepth == 1)
    #expect(record.budgetMaximumDelegations == 1)
  }

  @Test("Top-level task calls in one parent run share delegation budget")
  func topLevelTaskCallsInOneParentRunShareDelegationBudget() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let workerCalls = CallCounter()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            await workerCalls.increment()
            return CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        id: "first-task",
        name: "task",
        argumentsJSON: #"{"description":"Do first.","subagent_type":"worker"}"#
      ),
      .toolCall(
        id: "second-task",
        name: "task",
        argumentsJSON: #"{"description":"Do second.","subagent_type":"worker"}"#
      ),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [taskTool],
      toolConfiguration: .init(policy: AllowAllCoreAgentToolPolicy())
    )

    let thrown = await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Delegate twice.")
    }
    let toolCallError = try #require(thrown as? LanguageModelSession.ToolCallError)
    #expect(
      toolCallError.underlyingError as? CoreAgentDeepSubagentBudgetError
        == .delegationLimitExceeded(maximumDelegations: 1)
    )

    let records = await auditStore.records()
    #expect(await workerCalls.value == 1)
    #expect(Set(records.map(\.status)) == [.completed, .denied])
    #expect(records.filter { $0.status == .completed }.first?.budgetDelegationsUsed == 1)
    #expect(records.filter { $0.status == .denied }.first?.budgetDelegationsUsed == 1)
  }

  @Test("CoreAgent run completion clears task budget scopes")
  func coreAgentRunCompletionClearsTaskBudgetScopes() async throws {
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "task",
        argumentsJSON: #"{"description":"Do one.","subagent_type":"worker"}"#
      ),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(
      model: model,
      tools: [taskTool],
      toolConfiguration: .init(policy: AllowAllCoreAgentToolPolicy())
    )

    _ = try await session.respond(to: "Delegate once.")

    #expect(await taskTool.activeBudgetScopeCount() == 0)
  }

  @Test("Subagents plugin completion clears task budget scopes")
  func subagentsPluginCompletionClearsTaskBudgetScopes() async throws {
    let plugin = try CoreAgentDeepSubagentsPlugin(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Completes delegated work.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done"
            )
          }
        )
      ],
      budget: CoreAgentDeepSubagentBudget(maximumDepth: 1, maximumDelegations: 1)
    )
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "task",
        argumentsJSON: #"{"description":"Do one.","subagent_type":"worker"}"#
      ),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(model: model, plugins: [plugin])

    _ = try await session.respond(to: "Delegate once.")

    #expect(await plugin.taskTool.activeBudgetScopeCount() == 0)
  }

  @Test("Approved registry requires matching proposal digest before registration")
  func approvedRegistryRequiresMatchingProposalDigestBeforeRegistration() async throws {
    let proposal = try CoreAgentDeepSubagentDescriptorProposalBuilder.makeProposal(
      name: "reviewer",
      description: "Reviews code changes."
    )
    let registry = try CoreAgentDeepSubagentApprovedRegistry()
    let subagent = ClosureCoreAgentDeepSubagent(
      name: "reviewer",
      description: "Reviews code changes.",
      handler: { request in
        CoreAgentDeepSubagentResult(subagentName: request.subagentType, content: "ok")
      }
    )

    try await registry.register(
      subagent: subagent,
      proposal: proposal,
      approval: CoreAgentDeepSubagentDescriptorApproval(
        proposalID: proposal.proposalID,
        proposalDigest: proposal.proposalDigest,
        approverID: "host"
      )
    )

    await #expect(throws: CoreAgentDeepSubagentRegistryError.proposalDigestMismatch) {
      try await registry.register(
        subagent: subagent,
        proposal: proposal,
        approval: CoreAgentDeepSubagentDescriptorApproval(
          proposalID: proposal.proposalID,
          proposalDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
          approverID: "host"
        )
      )
    }
  }

  @Test("Task tool dispatches dynamically approved subagents from registry")
  func taskToolDispatchesDynamicallyApprovedSubagentsFromRegistry() async throws {
    let registry = try CoreAgentDeepSubagentApprovedRegistry()
    let proposal = try CoreAgentDeepSubagentDescriptorProposalBuilder.makeProposal(
      name: "worker",
      description: "Handles delegated work."
    )
    let subagent = ClosureCoreAgentDeepSubagent(
      name: "worker",
      description: "Handles delegated work.",
      handler: { request in
        CoreAgentDeepSubagentResult(subagentName: request.subagentType, content: "child-output")
      }
    )
    try await registry.register(
      subagent: subagent,
      proposal: proposal,
      approval: CoreAgentDeepSubagentDescriptorApproval(
        proposalID: proposal.proposalID,
        proposalDigest: proposal.proposalDigest,
        approverID: "host"
      )
    )
    let descriptors = await registry.availableDescriptors()
    let taskTool = CoreAgentDeepTaskTool(
      registry: registry,
      descriptors: descriptors
    )
    let output = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "Do work",
        subagent_type: "worker"
      )
    )

    #expect(output.contains("child-output"))
    #expect(output.contains("subagent=worker"))
  }
  @Test("Task tool enforces cumulative token budget across delegations")
  func taskToolEnforcesTokenBudgetAcrossDelegations() async throws {
    let auditStore = CoreAgentDeepSubagentAuditStore()
    let taskTool = try CoreAgentDeepTaskTool(
      subagents: [
        ClosureCoreAgentDeepSubagent(
          name: "worker",
          description: "Returns usage-bearing results.",
          handler: { request in
            CoreAgentDeepSubagentResult(
              subagentName: request.subagentType,
              content: "done",
              usage: CoreAgentUsage(
                inputTokens: 60,
                cachedInputTokens: 0,
                outputTokens: 50,
                reasoningTokens: 0
              )
            )
          }
        )
      ],
      auditStore: auditStore,
      budget: CoreAgentDeepSubagentBudget(maximumDelegations: 4, maximumTotalTokens: 120)
    )

    _ = try await taskTool.call(
      arguments: CoreAgentDeepTaskArguments(
        description: "first",
        subagent_type: "worker"
      )
    )

    await #expect(throws: CoreAgentDeepSubagentBudgetError.self) {
      _ = try await taskTool.call(
        arguments: CoreAgentDeepTaskArguments(
          description: "second",
          subagent_type: "worker"
        )
      )
    }

    let records = await auditStore.records()
    #expect(records.count == 2)
    #expect(records[0].status == .completed)
    #expect(records[0].budgetTotalTokensUsed == 110)
    #expect(records[1].budgetTotalTokensUsed == 220)
    #expect(records[1].status == .failed)
  }

}
