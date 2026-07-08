import CoreAgent
import Foundation
import FoundationModels

public protocol CoreAgentDeepSubagentSpawnFactory: Sendable {
  func makeSubagent(
    for proposal: CoreAgentDeepSubagentDescriptorProposal
  ) async throws -> any CoreAgentDeepSubagent
}

public struct CoreAgentDeepDynamicSubagentsAutoApprovalPolicy: Sendable {
  public let approverID: String
  public let allowedNames: Set<String>?

  public init(approverID: String, allowedNames: Set<String>? = nil) {
    self.approverID = approverID
    self.allowedNames = allowedNames
  }

  public func shouldAutoApprove(proposal: CoreAgentDeepSubagentDescriptorProposal) -> Bool {
    guard !approverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    if let allowedNames {
      return allowedNames.contains(proposal.name)
    }
    return true
  }
}

public struct CoreAgentDeepSubagentProposalRegistrar: Sendable {
  private let registry: CoreAgentDeepSubagentApprovedRegistry
  private let spawnFactory: any CoreAgentDeepSubagentSpawnFactory

  public init(
    registry: CoreAgentDeepSubagentApprovedRegistry,
    spawnFactory: any CoreAgentDeepSubagentSpawnFactory
  ) {
    self.registry = registry
    self.spawnFactory = spawnFactory
  }

  public func approve(
    proposal: CoreAgentDeepSubagentDescriptorProposal,
    approverID: String
  ) async throws {
    let trimmedApproverID = approverID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedApproverID.isEmpty else {
      throw CoreAgentDeepSubagentError.emptyDescription
    }
    let subagent = try await spawnFactory.makeSubagent(for: proposal)
    try await registry.register(
      subagent: subagent,
      proposal: proposal,
      approval: CoreAgentDeepSubagentDescriptorApproval(
        proposalID: proposal.proposalID,
        proposalDigest: proposal.proposalDigest,
        approverID: trimmedApproverID
      )
    )
  }
}

public struct ClosureCoreAgentDeepSubagentSpawnFactory: CoreAgentDeepSubagentSpawnFactory {
  private let handler:
    @Sendable (CoreAgentDeepSubagentDescriptorProposal) async throws -> any CoreAgentDeepSubagent

  public init(
    _ handler:
      @escaping @Sendable (CoreAgentDeepSubagentDescriptorProposal) async throws
        -> any CoreAgentDeepSubagent
  ) {
    self.handler = handler
  }

  public func makeSubagent(
    for proposal: CoreAgentDeepSubagentDescriptorProposal
  ) async throws -> any CoreAgentDeepSubagent {
    try await handler(proposal)
  }
}

public struct CoreAgentDeepStaticSubagentSpawnFactory: CoreAgentDeepSubagentSpawnFactory {
  private let subagent: any CoreAgentDeepSubagent

  public init(subagent: any CoreAgentDeepSubagent) {
    self.subagent = subagent
  }

  public func makeSubagent(
    for proposal: CoreAgentDeepSubagentDescriptorProposal
  ) async throws -> any CoreAgentDeepSubagent {
    let trimmedName = subagent.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName == proposal.name else {
      throw CoreAgentDeepSubagentRegistryError.subagentNameMismatch
    }
    return subagent
  }
}

@Generable
public struct CoreAgentDeepProposeSubagentArguments: Sendable {
  public let task_description: String

  public init(task_description: String) {
    self.task_description = task_description
  }
}

public struct CoreAgentDeepProposeSubagentTool: Tool {
  public let name = "propose_subagent"
  public let description: String

  private let generator: any CoreAgentDeepSubagentDescriptorGenerator
  private let proposalStore: CoreAgentDeepSubagentProposalStore
  private let proposalRegistrar: CoreAgentDeepSubagentProposalRegistrar?
  private let autoApprovalPolicy: CoreAgentDeepDynamicSubagentsAutoApprovalPolicy?

  public init(
    generator: any CoreAgentDeepSubagentDescriptorGenerator,
    proposalStore: CoreAgentDeepSubagentProposalStore,
    proposalRegistrar: CoreAgentDeepSubagentProposalRegistrar? = nil,
    autoApprovalPolicy: CoreAgentDeepDynamicSubagentsAutoApprovalPolicy? = nil,
    description: String? = nil
  ) {
    self.generator = generator
    self.proposalStore = proposalStore
    self.proposalRegistrar = proposalRegistrar
    self.autoApprovalPolicy = autoApprovalPolicy
    self.description =
      description
      ?? "Propose one or more new subagent profiles for host approval before task delegation."
  }

  @concurrent
  public func call(arguments: CoreAgentDeepProposeSubagentArguments) async throws -> String {
    let taskDescription = arguments.task_description.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !taskDescription.isEmpty else {
      throw CoreAgentDeepSubagentError.emptyDescription
    }
    let invocation = CoreAgentToolInvocation.current
    let context = CoreAgentDeepSubagentDescriptorGenerationContext(
      parentRunID: invocation?.runID,
      requestedTaskDescriptionDigest: CoreAgentDeepSubagentDescriptorProposalBuilder
        .proposalDigest(name: "task", description: taskDescription)
    )
    let proposals = try await generator.proposeDescriptors(context: context)
    guard !proposals.isEmpty else {
      return "No subagent proposals were generated."
    }
    await proposalStore.store(proposals)
    if let proposalRegistrar, let autoApprovalPolicy {
      for proposal in proposals where autoApprovalPolicy.shouldAutoApprove(proposal: proposal) {
        try await proposalRegistrar.approve(
          proposal: proposal,
          approverID: autoApprovalPolicy.approverID
        )
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = proposals.map { proposal in
      [
        "proposal_id": proposal.proposalID.uuidString,
        "name": proposal.name,
        "description": proposal.description,
        "proposal_digest": proposal.proposalDigest,
      ]
    }
    let data = try encoder.encode(payload)
    return String(decoding: data, as: UTF8.self)
  }
}

@Generable
public struct CoreAgentDeepApproveSubagentArguments: Sendable {
  public let proposal_id: String
  public let proposal_digest: String
  public let approver_id: String

  public init(
    proposal_id: String,
    proposal_digest: String,
    approver_id: String
  ) {
    self.proposal_id = proposal_id
    self.proposal_digest = proposal_digest
    self.approver_id = approver_id
  }
}

public actor CoreAgentDeepSubagentProposalStore {
  private var proposals: [UUID: CoreAgentDeepSubagentDescriptorProposal] = [:]

  public init() {}

  public func store(_ proposals: [CoreAgentDeepSubagentDescriptorProposal]) {
    for proposal in proposals {
      self.proposals[proposal.proposalID] = proposal
    }
  }

  public func proposal(id: UUID) -> CoreAgentDeepSubagentDescriptorProposal? {
    proposals[id]
  }
}

public struct CoreAgentDeepApproveSubagentTool: Tool {
  public let name = "approve_subagent"
  public let description: String

  private let registry: CoreAgentDeepSubagentApprovedRegistry
  private let proposalStore: CoreAgentDeepSubagentProposalStore
  private let spawnFactory: any CoreAgentDeepSubagentSpawnFactory

  public init(
    registry: CoreAgentDeepSubagentApprovedRegistry,
    proposalStore: CoreAgentDeepSubagentProposalStore,
    spawnFactory: any CoreAgentDeepSubagentSpawnFactory,
    description: String? = nil
  ) {
    self.registry = registry
    self.proposalStore = proposalStore
    self.spawnFactory = spawnFactory
    self.description =
      description
      ?? "Approve a previously proposed subagent profile and register it for task delegation."
  }

  @concurrent
  public func call(arguments: CoreAgentDeepApproveSubagentArguments) async throws -> String {
    let proposalIDString = arguments.proposal_id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let proposalID = UUID(uuidString: proposalIDString) else {
      throw CoreAgentDeepSubagentRegistryError.proposalIDMismatch
    }
    guard let proposal = await proposalStore.proposal(id: proposalID) else {
      throw CoreAgentDeepSubagentRegistryError.proposalIDMismatch
    }
    guard proposal.proposalDigest == arguments.proposal_digest else {
      throw CoreAgentDeepSubagentRegistryError.proposalDigestMismatch
    }
    try await CoreAgentDeepSubagentProposalRegistrar(
      registry: registry,
      spawnFactory: spawnFactory
    ).approve(proposal: proposal, approverID: arguments.approver_id)
    return "Approved subagent \(proposal.name)."
  }
}

public struct CoreAgentDeepRecordingSubagentDescriptorGenerator:
  CoreAgentDeepSubagentDescriptorGenerator
{
  private let proposals: [CoreAgentDeepSubagentDescriptorProposal]

  public init(proposals: [CoreAgentDeepSubagentDescriptorProposal]) {
    self.proposals = proposals
  }

  public func proposeDescriptors(
    context: CoreAgentDeepSubagentDescriptorGenerationContext
  ) async throws -> [CoreAgentDeepSubagentDescriptorProposal] {
    _ = context
    return Array(proposals.prefix(context.maxProposals))
  }
}

public struct CoreAgentDeepDynamicSubagentsPlugin: CoreAgentSessionPlugin {
  public let identifier: String
  public let registry: CoreAgentDeepSubagentApprovedRegistry
  public let proposalStore: CoreAgentDeepSubagentProposalStore
  public let taskTool: CoreAgentDeepTaskTool
  public let proposeTool: CoreAgentDeepProposeSubagentTool
  public let approveTool: CoreAgentDeepApproveSubagentTool

  public var tools: [any Tool] {
    [proposeTool, approveTool, taskTool]
  }

  public init(
    identifier: String = "coreagent.deep.dynamic-subagents",
    staticSubagents: [any CoreAgentDeepSubagent] = [],
    generator: any CoreAgentDeepSubagentDescriptorGenerator,
    spawnFactory: any CoreAgentDeepSubagentSpawnFactory,
    auditStore: CoreAgentDeepSubagentAuditStore = CoreAgentDeepSubagentAuditStore(),
    auditConfiguration: CoreAgentDeepSubagentAuditConfiguration =
      CoreAgentDeepSubagentAuditConfiguration(),
    budget: CoreAgentDeepSubagentBudget = .modelFacingDefault,
    autoApprovalPolicy: CoreAgentDeepDynamicSubagentsAutoApprovalPolicy? = nil
  ) throws {
    self.identifier = identifier
    self.registry = try CoreAgentDeepSubagentApprovedRegistry(staticSubagents: staticSubagents)
    self.proposalStore = CoreAgentDeepSubagentProposalStore()
    let proposalRegistrar = CoreAgentDeepSubagentProposalRegistrar(
      registry: registry,
      spawnFactory: spawnFactory
    )
    self.proposeTool = CoreAgentDeepProposeSubagentTool(
      generator: generator,
      proposalStore: proposalStore,
      proposalRegistrar: proposalRegistrar,
      autoApprovalPolicy: autoApprovalPolicy
    )
    self.approveTool = CoreAgentDeepApproveSubagentTool(
      registry: registry,
      proposalStore: proposalStore,
      spawnFactory: spawnFactory
    )
    let descriptors = staticSubagents.map {
      CoreAgentDeepSubagentDescriptor(name: $0.name, description: $0.description)
    }.sorted { $0.name < $1.name }
    self.taskTool = CoreAgentDeepTaskTool(
      registry: registry,
      descriptors: descriptors,
      auditStore: auditStore,
      auditConfiguration: auditConfiguration,
      budget: budget
    )
  }

  public func prepare(for request: CoreAgentPluginRequest) async throws
    -> CoreAgentPluginPreparation
  {
    _ = request
    return .empty
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

  public func recordGeneratedProposals(
    _ proposals: [CoreAgentDeepSubagentDescriptorProposal]
  ) async {
    await proposalStore.store(proposals)
  }

  public func refreshedDescriptors() async -> [CoreAgentDeepSubagentDescriptor] {
    await taskTool.refreshedDescriptors()
  }
}
