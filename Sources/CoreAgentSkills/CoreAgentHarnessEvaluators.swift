import Foundation

public struct CoreAgentHarnessCandidate: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let parameters: [String: String]

  public init(id: String, parameters: [String: String]) {
    self.id = id
    self.parameters = parameters
  }
}

public struct CoreAgentHarnessEvaluation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let heldoutSuiteID: String
  public let score: Double

  public init(candidateID: String, heldoutSuiteID: String, score: Double) {
    self.candidateID = candidateID
    self.heldoutSuiteID = heldoutSuiteID
    self.score = score
  }
}

public enum CoreAgentHarnessObjectiveDirection: String, Codable, Equatable, Sendable {
  case maximize
  case minimize
}

public struct CoreAgentHarnessObjectiveID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

public struct CoreAgentHarnessObjective: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentHarnessObjectiveID
  public let weight: Double
  public let direction: CoreAgentHarnessObjectiveDirection
  public let requiredMeanScore: Double?

  public init(
    id: CoreAgentHarnessObjectiveID,
    weight: Double = 1,
    direction: CoreAgentHarnessObjectiveDirection = .maximize,
    requiredMeanScore: Double? = nil
  ) {
    self.id = id
    self.weight = weight
    self.direction = direction
    self.requiredMeanScore = requiredMeanScore
  }
}

public struct CoreAgentHarnessObjectiveEvaluation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let heldoutSuiteID: String
  public let objectiveID: CoreAgentHarnessObjectiveID
  public let score: Double

  public init(
    candidateID: String,
    heldoutSuiteID: String,
    objectiveID: CoreAgentHarnessObjectiveID,
    score: Double
  ) {
    self.candidateID = candidateID
    self.heldoutSuiteID = heldoutSuiteID
    self.objectiveID = objectiveID
    self.score = score
  }
}

public struct CoreAgentHarnessAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let meanScore: Double
  public let heldoutSuiteIDs: [String]
}

public struct CoreAgentHarnessObjectiveScore: Equatable, Sendable {
  public let objectiveID: CoreAgentHarnessObjectiveID
  public let meanScore: Double
  public let normalizedMeanScore: Double
  public let weight: Double
  public let weightedScore: Double
  public let heldoutSuiteIDs: [String]
  public let passedRequiredMean: Bool
}

public struct CoreAgentHarnessMultiObjectiveAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let weightedScore: Double
  public let eligible: Bool
  public let heldoutSuiteIDs: [String]
  public let objectiveScores: [CoreAgentHarnessObjectiveScore]
}

public struct CoreAgentHarnessOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessAuditEntry]
}

public struct CoreAgentHarnessMultiObjectiveOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let objectives: [CoreAgentHarnessObjective]
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessMultiObjectiveAuditEntry]
}

public struct CoreAgentHarnessOptimizer: Sendable {
  public init() {}

  public func selectBest(
    candidates: [CoreAgentHarnessCandidate],
    evaluations: [CoreAgentHarnessEvaluation]
  ) throws -> CoreAgentHarnessOptimizationResult {
    var seenCandidates: Set<String> = []
    for candidate in candidates {
      guard seenCandidates.insert(candidate.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessCandidate(candidate.id)
      }
    }
    let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    var audit: [CoreAgentHarnessAuditEntry] = []
    for candidate in candidates {
      let scores = evaluations.filter { $0.candidateID == candidate.id }
      guard !scores.isEmpty else {
        throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidate.id)
      }
      let meanScore = scores.map(\.score).reduce(0, +) / Double(scores.count)
      audit.append(
        CoreAgentHarnessAuditEntry(
          candidateID: candidate.id,
          meanScore: meanScore,
          heldoutSuiteIDs: Array(Set(scores.map(\.heldoutSuiteID))).sorted()
        )
      )
    }
    audit.sort { lhs, rhs in
      if lhs.meanScore != rhs.meanScore {
        return lhs.meanScore > rhs.meanScore
      }
      return lhs.candidateID < rhs.candidateID
    }
    guard let bestEntry = audit.first,
      let best = candidateByID[bestEntry.candidateID]
    else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation("all")
    }
    return CoreAgentHarnessOptimizationResult(
      best: best,
      heldoutSuiteIDs: Array(Set(evaluations.map(\.heldoutSuiteID))).sorted(),
      auditTrail: audit
    )
  }

  public func selectBest(
    candidates: [CoreAgentHarnessCandidate],
    objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation],
    objectives: [CoreAgentHarnessObjective]
  ) throws -> CoreAgentHarnessMultiObjectiveOptimizationResult {
    try validateUniqueCandidates(candidates)
    try validateObjectives(objectives)
    let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    let objectiveIDs = Set(objectives.map(\.id))
    try validateObjectiveEvaluations(
      objectiveEvaluations,
      candidateIDs: Set(candidateByID.keys),
      objectiveIDs: objectiveIDs
    )

    let totalWeight = objectives.map(\.weight).reduce(0, +)
    var audit: [CoreAgentHarnessMultiObjectiveAuditEntry] = []
    for candidate in candidates {
      var objectiveScores: [CoreAgentHarnessObjectiveScore] = []
      var heldoutSuiteIDs: Set<String> = []
      for objective in objectives {
        let evaluations = objectiveEvaluations.filter {
          $0.candidateID == candidate.id && $0.objectiveID == objective.id
        }
        guard !evaluations.isEmpty else {
          throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(
            "\(candidate.id):\(objective.id.rawValue)"
          )
        }
        let meanScore = evaluations.map(\.score).reduce(0, +) / Double(evaluations.count)
        let normalizedMeanScore: Double
        switch objective.direction {
        case .maximize:
          normalizedMeanScore = meanScore
        case .minimize:
          normalizedMeanScore = 1 - meanScore
        }
        let suites = Array(Set(evaluations.map(\.heldoutSuiteID))).sorted()
        heldoutSuiteIDs.formUnion(suites)
        let passedRequiredMean =
          objective.requiredMeanScore.map {
            normalizedMeanScore >= $0
          } ?? true
        objectiveScores.append(
          CoreAgentHarnessObjectiveScore(
            objectiveID: objective.id,
            meanScore: meanScore,
            normalizedMeanScore: normalizedMeanScore,
            weight: objective.weight,
            weightedScore: normalizedMeanScore * objective.weight,
            heldoutSuiteIDs: suites,
            passedRequiredMean: passedRequiredMean
          )
        )
      }
      let weightedScore = objectiveScores.map(\.weightedScore).reduce(0, +) / totalWeight
      audit.append(
        CoreAgentHarnessMultiObjectiveAuditEntry(
          candidateID: candidate.id,
          weightedScore: weightedScore,
          eligible: objectiveScores.allSatisfy(\.passedRequiredMean),
          heldoutSuiteIDs: Array(heldoutSuiteIDs).sorted(),
          objectiveScores: objectiveScores
        )
      )
    }
    audit.sort { lhs, rhs in
      if lhs.eligible != rhs.eligible {
        return lhs.eligible && !rhs.eligible
      }
      if lhs.weightedScore != rhs.weightedScore {
        return lhs.weightedScore > rhs.weightedScore
      }
      return lhs.candidateID < rhs.candidateID
    }
    guard let bestEntry = audit.first(where: \.eligible),
      let best = candidateByID[bestEntry.candidateID]
    else {
      throw CoreAgentSkillOptimizationError.noEligibleHarnessCandidate
    }
    return CoreAgentHarnessMultiObjectiveOptimizationResult(
      best: best,
      objectives: objectives,
      heldoutSuiteIDs: Array(Set(objectiveEvaluations.map(\.heldoutSuiteID))).sorted(),
      auditTrail: audit
    )
  }

  private func validateUniqueCandidates(_ candidates: [CoreAgentHarnessCandidate]) throws {
    var seenCandidates: Set<String> = []
    for candidate in candidates {
      guard seenCandidates.insert(candidate.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessCandidate(candidate.id)
      }
    }
  }

  private func validateObjectives(_ objectives: [CoreAgentHarnessObjective]) throws {
    guard !objectives.isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "at least one objective is required"
      )
    }
    var seenObjectives: Set<CoreAgentHarnessObjectiveID> = []
    for objective in objectives {
      guard !objective.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "objective id must be non-empty"
        )
      }
      guard seenObjectives.insert(objective.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjective(objective.id)
      }
      guard objective.weight.isFinite, objective.weight > 0 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "objective weight must be finite and positive"
        )
      }
      if let requiredMeanScore = objective.requiredMeanScore {
        guard requiredMeanScore.isFinite,
          requiredMeanScore >= 0,
          requiredMeanScore <= 1
        else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "required objective mean score must be between 0 and 1"
          )
        }
      }
    }
  }

  private func validateObjectiveEvaluations(
    _ evaluations: [CoreAgentHarnessObjectiveEvaluation],
    candidateIDs: Set<String>,
    objectiveIDs: Set<CoreAgentHarnessObjectiveID>
  ) throws {
    var seenEvaluations: Set<CoreAgentHarnessObjectiveEvaluationKey> = []
    for evaluation in evaluations {
      guard candidateIDs.contains(evaluation.candidateID) else {
        throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(evaluation.candidateID)
      }
      guard objectiveIDs.contains(evaluation.objectiveID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "unknown objective \(evaluation.objectiveID.rawValue)"
        )
      }
      guard !evaluation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
      guard evaluation.score.isFinite, evaluation.score >= 0, evaluation.score <= 1 else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(evaluation.score)
      }
      let evaluationKey = CoreAgentHarnessObjectiveEvaluationKey(evaluation: evaluation)
      guard seenEvaluations.insert(evaluationKey).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjectiveEvaluation(
          evaluationKey.stableDescription
        )
      }
    }
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

public struct CoreAgentSkillMultiObjectiveValidationAdapter: Sendable {
  private let optimizer: CoreAgentHarnessOptimizer

  public init(optimizer: CoreAgentHarnessOptimizer = CoreAgentHarnessOptimizer()) {
    self.optimizer = optimizer
  }

  public func validationResult(
    candidateID: String,
    evaluations: [CoreAgentHarnessObjectiveEvaluation],
    objectives: [CoreAgentHarnessObjective],
    heldoutSuiteID: String,
    passingScore: Double = 0,
    notes: String = ""
  ) throws -> CoreAgentSkillValidationResult {
    guard !heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
    }
    guard passingScore.isFinite, passingScore >= 0, passingScore <= 1 else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(passingScore)
    }
    for evaluation in evaluations {
      guard !evaluation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
    }
    let evaluationSuiteIDs = Set(evaluations.map(\.heldoutSuiteID))
    if !evaluationSuiteIDs.isEmpty, evaluationSuiteIDs != Set([heldoutSuiteID]) {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "adapter heldoutSuiteID must match objective evaluation suites"
      )
    }
    let result = try optimizer.selectBest(
      candidates: [CoreAgentHarnessCandidate(id: candidateID, parameters: [:])],
      objectiveEvaluations: evaluations,
      objectives: objectives
    )
    guard let entry = result.auditTrail.first else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidateID)
    }
    return CoreAgentSkillValidationResult(
      score: entry.weightedScore,
      heldoutSuiteID: heldoutSuiteID,
      passed: entry.eligible && entry.weightedScore >= passingScore,
      notes: notes
    )
  }
}
