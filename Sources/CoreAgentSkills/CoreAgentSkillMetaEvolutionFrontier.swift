import Foundation

public struct CoreAgentSkillMetaEvolutionFrontierPolicy:
  Codable, Equatable, Sendable
{
  public let maxSelectedProposals: Int
  public let productivityWeight: Double
  public let noveltyWeight: Double
  public let strictScoreWeight: Double
  public let looseScoreWeight: Double
  public let minimumNoveltyScore: Double?
  public let maximumHackRatio: Double?

  public init(
    maxSelectedProposals: Int = 1,
    productivityWeight: Double = 0.45,
    noveltyWeight: Double = 0.25,
    strictScoreWeight: Double = 0.10,
    looseScoreWeight: Double = 0.20,
    minimumNoveltyScore: Double? = nil,
    maximumHackRatio: Double? = nil
  ) {
    self.maxSelectedProposals = maxSelectedProposals
    self.productivityWeight = productivityWeight
    self.noveltyWeight = noveltyWeight
    self.strictScoreWeight = strictScoreWeight
    self.looseScoreWeight = looseScoreWeight
    self.minimumNoveltyScore = minimumNoveltyScore
    self.maximumHackRatio = maximumHackRatio
  }

  fileprivate func validate() throws {
    guard maxSelectedProposals > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier maxSelectedProposals must be positive"
      )
    }
    let weights = [
      productivityWeight,
      noveltyWeight,
      strictScoreWeight,
      looseScoreWeight,
    ]
    guard weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier weights must be finite and non-negative"
      )
    }
    guard weights.reduce(0, +) > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier weights must not all be zero"
      )
    }
    if let minimumNoveltyScore {
      try validateMetaEvolutionUnitScore(
        minimumNoveltyScore,
        field: "minimumNoveltyScore"
      )
    }
    if let maximumHackRatio {
      guard maximumHackRatio.isFinite, maximumHackRatio > 0 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier maximumHackRatio must be finite and positive"
        )
      }
    }
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierScore:
  Codable, Equatable, Sendable
{
  public let proposalID: String
  public let productivityScore: Double
  public let noveltyScore: Double
  public let strictScore: Double
  public let looseScore: Double
  public let objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation]

  public init(
    proposalID: String,
    productivityScore: Double,
    noveltyScore: Double,
    strictScore: Double,
    looseScore: Double,
    objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation] = []
  ) {
    self.proposalID = proposalID
    self.productivityScore = productivityScore
    self.noveltyScore = noveltyScore
    self.strictScore = strictScore
    self.looseScore = looseScore
    self.objectiveEvaluations = objectiveEvaluations
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierAuditEntry:
  Equatable, Sendable
{
  public let proposalID: String
  public let weightedScore: Double
  public let productivityScore: Double
  public let noveltyScore: Double
  public let strictScore: Double
  public let looseScore: Double
  public let hackRatio: Double
  public let eligible: Bool

  public init(
    proposalID: String,
    weightedScore: Double,
    productivityScore: Double,
    noveltyScore: Double,
    strictScore: Double,
    looseScore: Double,
    hackRatio: Double,
    eligible: Bool
  ) {
    self.proposalID = proposalID
    self.weightedScore = weightedScore
    self.productivityScore = productivityScore
    self.noveltyScore = noveltyScore
    self.strictScore = strictScore
    self.looseScore = looseScore
    self.hackRatio = hackRatio
    self.eligible = eligible
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierSelection:
  Sendable
{
  public let selected: [CoreAgentSkillSleepOptimizationProposal]
  public let rejectedProposalIDs: [String]
  public let auditTrail: [CoreAgentSkillMetaEvolutionFrontierAuditEntry]

  public init(
    selected: [CoreAgentSkillSleepOptimizationProposal],
    rejectedProposalIDs: [String],
    auditTrail: [CoreAgentSkillMetaEvolutionFrontierAuditEntry]
  ) {
    self.selected = selected
    self.rejectedProposalIDs = rejectedProposalIDs
    self.auditTrail = auditTrail
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierSelector: Sendable {
  public init() {}

  public func select(
    proposals: [CoreAgentSkillSleepOptimizationProposal],
    scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy =
      CoreAgentSkillMetaEvolutionFrontierPolicy()
  ) throws -> CoreAgentSkillMetaEvolutionFrontierSelection {
    try policy.validate()
    try validateUniqueFrontierProposals(proposals)
    let scoreByProposalID = try validateFrontierScores(scores, proposals: proposals)

    let proposalByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
    var audit: [CoreAgentSkillMetaEvolutionFrontierAuditEntry] = []
    for proposal in proposals {
      guard let score = scoreByProposalID[proposal.id] else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score missing for proposal \(proposal.id)"
        )
      }
      audit.append(entry(for: score, policy: policy))
    }
    audit.sort { lhs, rhs in
      if lhs.weightedScore != rhs.weightedScore {
        return lhs.weightedScore > rhs.weightedScore
      }
      return lhs.proposalID < rhs.proposalID
    }

    let selectedIDs = Array(audit.filter(\.eligible).prefix(policy.maxSelectedProposals))
      .map(\.proposalID)
    let selected = selectedIDs.compactMap { proposalByID[$0] }
    let selectedIDSet = Set(selectedIDs)
    let rejectedProposalIDs = audit.map(\.proposalID).filter {
      !selectedIDSet.contains($0)
    }

    return CoreAgentSkillMetaEvolutionFrontierSelection(
      selected: selected,
      rejectedProposalIDs: rejectedProposalIDs,
      auditTrail: audit
    )
  }

  private func entry(
    for score: CoreAgentSkillMetaEvolutionFrontierScore,
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy
  ) -> CoreAgentSkillMetaEvolutionFrontierAuditEntry {
    let hackRatio = score.looseScore / max(score.strictScore, 0.0001)
    let weightedScore =
      (score.productivityScore * policy.productivityWeight)
      + (score.noveltyScore * policy.noveltyWeight)
      + (score.strictScore * policy.strictScoreWeight)
      + (score.looseScore * policy.looseScoreWeight)
    let passesNovelty =
      policy.minimumNoveltyScore.map {
        score.noveltyScore >= $0
      } ?? true
    let passesHackRatio =
      policy.maximumHackRatio.map {
        hackRatio <= $0
      } ?? true

    return CoreAgentSkillMetaEvolutionFrontierAuditEntry(
      proposalID: score.proposalID,
      weightedScore: weightedScore,
      productivityScore: score.productivityScore,
      noveltyScore: score.noveltyScore,
      strictScore: score.strictScore,
      looseScore: score.looseScore,
      hackRatio: hackRatio,
      eligible: passesNovelty && passesHackRatio
    )
  }

  private func validateUniqueFrontierProposals(
    _ proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws {
    var seenProposalIDs: Set<String> = []
    for proposal in proposals {
      guard isSafeProposalIdentifier(proposal.id) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier proposal ID is invalid"
        )
      }
      guard seenProposalIDs.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private func validateFrontierScores(
    _ scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws -> [String: CoreAgentSkillMetaEvolutionFrontierScore] {
    let proposalIDs = Set(proposals.map(\.id))
    var scoreByProposalID: [String: CoreAgentSkillMetaEvolutionFrontierScore] = [:]
    for score in scores {
      guard isSafeProposalIdentifier(score.proposalID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score proposal ID is invalid"
        )
      }
      guard proposalIDs.contains(score.proposalID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score references unknown proposal \(score.proposalID)"
        )
      }
      guard scoreByProposalID[score.proposalID] == nil else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(
          score.proposalID
        )
      }
      try validateMetaEvolutionUnitScore(
        score.productivityScore,
        field: "productivityScore"
      )
      try validateMetaEvolutionUnitScore(score.noveltyScore, field: "noveltyScore")
      try validateMetaEvolutionUnitScore(score.strictScore, field: "strictScore")
      try validateMetaEvolutionUnitScore(score.looseScore, field: "looseScore")
      try validateFrontierObjectiveEvaluations(
        score.objectiveEvaluations,
        proposalID: score.proposalID
      )
      scoreByProposalID[score.proposalID] = score
    }
    return scoreByProposalID
  }

  private func validateFrontierObjectiveEvaluations(
    _ evaluations: [CoreAgentHarnessObjectiveEvaluation],
    proposalID: String
  ) throws {
    var seenEvaluations: Set<CoreAgentHarnessObjectiveEvaluationKey> = []
    for evaluation in evaluations {
      guard evaluation.candidateID == proposalID else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier objective evaluation candidate must match proposal"
        )
      }
      guard !evaluation.heldoutSuiteID.isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
      guard !evaluation.objectiveID.rawValue.isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier objective ID must be non-empty"
        )
      }
      guard evaluation.score.isFinite, (0...1).contains(evaluation.score) else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(evaluation.score)
      }
      let key = CoreAgentHarnessObjectiveEvaluationKey(evaluation: evaluation)
      guard seenEvaluations.insert(key).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjectiveEvaluation(
          "\(evaluation.candidateID):\(evaluation.heldoutSuiteID):\(evaluation.objectiveID.rawValue)"
        )
      }
    }
  }
}

private func validateMetaEvolutionUnitScore(_ score: Double, field: String) throws {
  guard score.isFinite, (0...1).contains(score) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "frontier \(field) must be finite and in 0...1"
    )
  }
}

private struct CoreAgentHarnessObjectiveEvaluationKey: Hashable {
  let candidateID: String
  let heldoutSuiteID: String
  let objectiveID: CoreAgentHarnessObjectiveID

  init(evaluation: CoreAgentHarnessObjectiveEvaluation) {
    self.candidateID = evaluation.candidateID
    self.heldoutSuiteID = evaluation.heldoutSuiteID
    self.objectiveID = evaluation.objectiveID
  }

  var stableDescription: String {
    [
      candidateID,
      heldoutSuiteID,
      objectiveID.rawValue,
    ].joined(separator: ":")
  }
}

private func isSafeProposalIdentifier(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard !scalars.isEmpty, scalars.count <= 128 else { return false }
  guard isASCIIIdentifierHead(scalars[0]) else { return false }
  return scalars.allSatisfy { scalar in
    let value = Int(scalar.value)
    return isASCIIIdentifierHead(scalar) || (48...57).contains(value)
      || value == 45 || value == 46 || value == 58 || value == 95
  }
}

private func isASCIIIdentifierHead(_ scalar: Unicode.Scalar) -> Bool {
  (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
}
