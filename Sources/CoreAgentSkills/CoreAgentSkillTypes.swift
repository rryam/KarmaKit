import Foundation

public struct CoreAgentSkillID:
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

public struct CoreAgentSkill: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentSkillID
  public let version: Int
  public let title: String
  public let body: String
  public let tags: [String]
  public let priority: Int
  public let provenance: [CoreAgentSkillProvenance]

  public init(
    id: CoreAgentSkillID,
    version: Int,
    title: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0,
    provenance: [CoreAgentSkillProvenance] = []
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.body = body
    self.tags = tags
    self.priority = priority
    self.provenance = provenance
  }
}

public struct CoreAgentSkillProvenance: Codable, Equatable, Sendable {
  public let acceptedAt: Date
  public let heldoutSuiteID: String
  public let validationScore: Double
  public let notes: String

  public init(
    acceptedAt: Date = Date(),
    heldoutSuiteID: String,
    validationScore: Double,
    notes: String
  ) {
    self.acceptedAt = acceptedAt
    self.heldoutSuiteID = heldoutSuiteID
    self.validationScore = validationScore
    self.notes = notes
  }
}

public struct CoreAgentSkillValidationResult: Codable, Equatable, Sendable {
  public let score: Double
  public let heldoutSuiteID: String
  public let passed: Bool
  public let notes: String

  public init(score: Double, heldoutSuiteID: String, passed: Bool, notes: String) {
    self.score = score
    self.heldoutSuiteID = heldoutSuiteID
    self.passed = passed
    self.notes = notes
  }
}

public struct CoreAgentSkillRolloutEvidence: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let taskID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let verifierFeedback: String
  public let score: Double
  public let metadata: [String: String]

  public init(
    id: String,
    taskID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    verifierFeedback: String,
    score: Double,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.taskID = taskID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.verifierFeedback = verifierFeedback
    self.score = score
    self.metadata = metadata
  }
}

public struct CoreAgentSkillEditLimits: Codable, Equatable, Sendable {
  public let maxEditCharacters: Int
  public let maxResultCharacters: Int

  public init(maxEditCharacters: Int = 4_000, maxResultCharacters: Int = 20_000) {
    self.maxEditCharacters = maxEditCharacters
    self.maxResultCharacters = maxResultCharacters
  }

  public static let `default` = CoreAgentSkillEditLimits()
}

public enum CoreAgentSkillEdit: Codable, Equatable, Sendable {
  case replace(target: String, replacement: String)
  case append(String)

  public func apply(to body: String) throws -> String {
    try apply(to: body, limits: .default)
  }

  public func apply(to body: String, limits: CoreAgentSkillEditLimits) throws -> String {
    switch self {
    case .append(let addition):
      guard addition.count <= limits.maxEditCharacters else {
        throw CoreAgentSkillOptimizationError.editTooLarge
      }
      let result = body + addition
      guard result.count <= limits.maxResultCharacters else {
        throw CoreAgentSkillOptimizationError.resultingSkillTooLarge
      }
      return result
    case .replace(let target, let replacement):
      guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyReplacementTarget
      }
      guard replacement.count <= limits.maxEditCharacters else {
        throw CoreAgentSkillOptimizationError.editTooLarge
      }
      let parts = body.components(separatedBy: target)
      guard parts.count == 2 else {
        throw CoreAgentSkillOptimizationError.replacementTargetNotUnique(target)
      }
      let result = parts[0] + replacement + parts[1]
      guard result.count <= limits.maxResultCharacters else {
        throw CoreAgentSkillOptimizationError.resultingSkillTooLarge
      }
      return result
    }
  }
}

public enum CoreAgentSkillOptimizationError: Error, Equatable, Sendable {
  case missingSkill(CoreAgentSkillID)
  case emptyReplacementTarget
  case replacementTargetNotUnique(String)
  case missingHarnessEvaluation(String)
  case versionCollision(CoreAgentSkillID, Int)
  case duplicateHarnessCandidate(String)
  case duplicateHarnessObjective(CoreAgentHarnessObjectiveID)
  case duplicateHarnessObjectiveEvaluation(String)
  case duplicateOptimizationProposal(String)
  case duplicateReplayRequest(String)
  case noEligibleHarnessCandidate
  case invalidOptimizationPolicy(String)
  case corruptSkillStore(String)
  case editTooLarge
  case resultingSkillTooLarge
  case invalidValidationScore(Double)
  case emptyHeldoutSuiteID
}

public struct CoreAgentSkillOptimizationProposal: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double
  public let candidateEdits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    skillID: CoreAgentSkillID,
    baselineScore: Double,
    candidateEdits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.skillID = skillID
    self.baselineScore = baselineScore
    self.candidateEdits = candidateEdits
    self.validation = validation
  }
}

public struct CoreAgentSkillOptimizationResult: Equatable, Sendable {
  public let accepted: Bool
  public let skill: CoreAgentSkill
  public let validation: CoreAgentSkillValidationResult
}

public struct CoreAgentRejectedSkillEdit: Codable, Equatable, Sendable {
  public let proposedAt: Date
  public let edits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    proposedAt: Date = Date(),
    edits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.proposedAt = proposedAt
    self.edits = edits
    self.validation = validation
  }
}

public enum CoreAgentSkillOptimizationRejectionReason:
  String, Codable, Equatable, Sendable
{
  case editBudgetExceeded
  case heldoutSplitLeakage
  case protectedRegionMutation
  case validationDidNotImprove
  case maxAcceptedProposalsReached
  case externalMemoryImport
}
