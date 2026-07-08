import Foundation

public struct CoreAgentSkillMetaObservation: Codable, Equatable, Sendable {
  public let observedAt: Date
  public let runID: String
  public let proposalID: String
  public let reason: CoreAgentSkillOptimizationRejectionReason
  public let notes: String

  public init(
    observedAt: Date = Date(),
    runID: String,
    proposalID: String,
    reason: CoreAgentSkillOptimizationRejectionReason,
    notes: String
  ) {
    self.observedAt = observedAt
    self.runID = runID
    self.proposalID = proposalID
    self.reason = reason
    self.notes = notes
  }
}

public struct CoreAgentSkillMetaSkillComponent: Codable, Equatable, Sendable {
  public let componentDigest: String
  public let policyVersion: String

  public init(componentDigest: String, policyVersion: String) {
    self.componentDigest = componentDigest
    self.policyVersion = policyVersion
  }
}

public struct CoreAgentSkillMetaSkillBranchSnapshot: Codable, Equatable, Sendable {
  public let branchID: String
  public let parentBranchID: String?
  public let epoch: Int
  public let analyzer: CoreAgentSkillMetaSkillComponent
  public let retriever: CoreAgentSkillMetaSkillComponent
  public let allocator: CoreAgentSkillMetaSkillComponent
  public let proposer: CoreAgentSkillMetaSkillComponent
  public let evolver: CoreAgentSkillMetaSkillComponent
  public let objectiveDigest: String

  public init(
    branchID: String,
    parentBranchID: String? = nil,
    epoch: Int,
    analyzer: CoreAgentSkillMetaSkillComponent,
    retriever: CoreAgentSkillMetaSkillComponent,
    allocator: CoreAgentSkillMetaSkillComponent,
    proposer: CoreAgentSkillMetaSkillComponent,
    evolver: CoreAgentSkillMetaSkillComponent,
    objectiveDigest: String
  ) {
    self.branchID = branchID
    self.parentBranchID = parentBranchID
    self.epoch = epoch
    self.analyzer = analyzer
    self.retriever = retriever
    self.allocator = allocator
    self.proposer = proposer
    self.evolver = evolver
    self.objectiveDigest = objectiveDigest
  }
}

public struct CoreAgentSkillMetaSkillEvolutionRecord: Codable, Equatable, Sendable {
  public let runID: String
  public let branchID: String
  public let previousEpoch: Int
  public let nextEpoch: Int
  public let acceptedProposalIDs: [String]
  public let rejectedProposalIDs: [String]
  public let frontierRejectedProposalIDs: [String]
  public let sleepAcceptedProposalIDs: [String]
  public let sleepRejectedProposalIDs: [String]
  public let evidenceDigest: String

  public init(
    runID: String,
    branchID: String,
    previousEpoch: Int,
    nextEpoch: Int,
    acceptedProposalIDs: [String],
    rejectedProposalIDs: [String],
    frontierRejectedProposalIDs: [String] = [],
    sleepAcceptedProposalIDs: [String]? = nil,
    sleepRejectedProposalIDs: [String] = [],
    evidenceDigest: String
  ) {
    self.runID = runID
    self.branchID = branchID
    self.previousEpoch = previousEpoch
    self.nextEpoch = nextEpoch
    self.acceptedProposalIDs = acceptedProposalIDs
    self.rejectedProposalIDs = rejectedProposalIDs
    self.frontierRejectedProposalIDs = frontierRejectedProposalIDs
    self.sleepAcceptedProposalIDs = sleepAcceptedProposalIDs ?? acceptedProposalIDs
    self.sleepRejectedProposalIDs = sleepRejectedProposalIDs
    self.evidenceDigest = evidenceDigest
  }

  private enum CodingKeys: String, CodingKey {
    case runID
    case branchID
    case previousEpoch
    case nextEpoch
    case acceptedProposalIDs
    case rejectedProposalIDs
    case frontierRejectedProposalIDs
    case sleepAcceptedProposalIDs
    case sleepRejectedProposalIDs
    case evidenceDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runID = try container.decode(String.self, forKey: .runID)
    branchID = try container.decode(String.self, forKey: .branchID)
    previousEpoch = try container.decode(Int.self, forKey: .previousEpoch)
    nextEpoch = try container.decode(Int.self, forKey: .nextEpoch)
    acceptedProposalIDs = try container.decode([String].self, forKey: .acceptedProposalIDs)
    rejectedProposalIDs = try container.decode([String].self, forKey: .rejectedProposalIDs)
    frontierRejectedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .frontierRejectedProposalIDs)
      ?? rejectedProposalIDs
    sleepAcceptedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .sleepAcceptedProposalIDs)
      ?? acceptedProposalIDs
    sleepRejectedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .sleepRejectedProposalIDs)
      ?? []
    evidenceDigest = try container.decode(String.self, forKey: .evidenceDigest)
  }
}

public struct CoreAgentSkillOptimizerMemory: Codable, Equatable, Sendable {
  public var rejectedEdits: [CoreAgentRejectedSkillEdit]
  public var metaObservations: [CoreAgentSkillMetaObservation]
  public var metaSkillSnapshots: [CoreAgentSkillMetaSkillBranchSnapshot]
  public var metaSkillEvolutionRecords: [CoreAgentSkillMetaSkillEvolutionRecord]

  public init(
    rejectedEdits: [CoreAgentRejectedSkillEdit] = [],
    metaObservations: [CoreAgentSkillMetaObservation] = [],
    metaSkillSnapshots: [CoreAgentSkillMetaSkillBranchSnapshot] = [],
    metaSkillEvolutionRecords: [CoreAgentSkillMetaSkillEvolutionRecord] = []
  ) {
    self.rejectedEdits = rejectedEdits
    self.metaObservations = metaObservations
    self.metaSkillSnapshots = metaSkillSnapshots
    self.metaSkillEvolutionRecords = metaSkillEvolutionRecords
  }

  private enum CodingKeys: String, CodingKey {
    case rejectedEdits
    case metaObservations
    case metaSkillSnapshots
    case metaSkillEvolutionRecords
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rejectedEdits =
      try container.decodeIfPresent([CoreAgentRejectedSkillEdit].self, forKey: .rejectedEdits) ?? []
    metaObservations =
      try container.decodeIfPresent([CoreAgentSkillMetaObservation].self, forKey: .metaObservations)
      ?? []
    metaSkillSnapshots =
      try container.decodeIfPresent(
        [CoreAgentSkillMetaSkillBranchSnapshot].self, forKey: .metaSkillSnapshots)
      ?? []
    metaSkillEvolutionRecords =
      try container.decodeIfPresent(
        [CoreAgentSkillMetaSkillEvolutionRecord].self, forKey: .metaSkillEvolutionRecords)
      ?? []
  }
}
