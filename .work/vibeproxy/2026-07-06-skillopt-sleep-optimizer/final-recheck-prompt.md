Final recheck for a Swift 6.4 CoreAgent SkillOpt sleep optimizer slice. Return one of:

PASS: no blocking correctness/security/API issues found
BLOCK: at least one concrete issue that should be fixed before treating this slice as done

Scope: CoreAgentSkills sleep/recursive optimization loop only. Previous valid blockers fixed: unbounded single-edit drift, public optimizer bypassing policy gates, and repeated protected slow-update region bypass. Recheck for concrete remaining blockers. Do not block on missing concrete App Intents, OS sandbox backends, model-powered edit proposer, or file-backed skill store; those are future slices.

Local verification after fixes: swift test --skip-update --filter CoreAgentSkillsTests passed 13 tests.

--- Sources/CoreAgentSkills/CoreAgentSkills.swift ---
import CoreAgent
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
  case duplicateOptimizationProposal(String)
  case invalidOptimizationPolicy(String)
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
}

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

public struct CoreAgentSkillOptimizerMemory: Codable, Equatable, Sendable {
  public var rejectedEdits: [CoreAgentRejectedSkillEdit]
  public var metaObservations: [CoreAgentSkillMetaObservation]

  public init(
    rejectedEdits: [CoreAgentRejectedSkillEdit] = [],
    metaObservations: [CoreAgentSkillMetaObservation] = []
  ) {
    self.rejectedEdits = rejectedEdits
    self.metaObservations = metaObservations
  }
}

public actor InMemoryCoreAgentSkillStore {
  private var historyByID: [CoreAgentSkillID: [CoreAgentSkill]] = [:]
  private var memoryByID: [CoreAgentSkillID: CoreAgentSkillOptimizerMemory] = [:]

  public init() {}

  public func save(_ skill: CoreAgentSkill) async throws {
    if historyByID[skill.id, default: []].contains(where: { $0.version == skill.version }) {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    historyByID[id]?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    historyByID.values
      .compactMap { $0.max { $0.version < $1.version } }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  }

  func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID) {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.rejectedEdits.append(rejected)
    memoryByID[skillID] = memory
  }

  func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.metaObservations.append(observation)
    memoryByID[skillID] = memory
  }
}

public struct CoreAgentSkillCurationQuery: Sendable {
  public let tags: Set<String>
  public let maxCharacters: Int

  public init(tags: Set<String>, maxCharacters: Int) {
    self.tags = tags
    self.maxCharacters = maxCharacters
  }

  public init(tags: [String], maxCharacters: Int) {
    self.init(tags: Set(tags), maxCharacters: maxCharacters)
  }
}

public struct CoreAgentSkillCurator: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func curate(query: CoreAgentSkillCurationQuery) async -> [CoreAgentSkill] {
    var remaining = max(0, query.maxCharacters)
    var selected: [CoreAgentSkill] = []
    for skill in await store.allCurrentSkills() {
      guard !Set(skill.tags).isDisjoint(with: query.tags) else { continue }
      guard skill.body.count <= remaining else { continue }
      selected.append(skill)
      remaining -= skill.body.count
    }
    return selected
  }
}

public struct CoreAgentSkillOptimizer: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal
  ) async throws -> CoreAgentSkillOptimizationResult {
    try await propose(proposal, policy: CoreAgentSkillOptimizationPolicy())
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal,
    policy: CoreAgentSkillOptimizationPolicy
  ) async throws -> CoreAgentSkillOptimizationResult {
    try policy.validate()
    guard let current = await store.currentSkill(id: proposal.skillID) else {
      throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
    }
    try Self.validateScores(proposal.validation, baselineScore: proposal.baselineScore)
    if let reason = Self.policyRejectionReason(
      proposal,
      current: current,
      policy: policy
    ) {
      return await reject(proposal, current: current, reason: reason)
    }

    var candidateBody = current.body
    for edit in proposal.candidateEdits {
      candidateBody = try edit.apply(to: candidateBody, limits: policy.editLimits)
    }

    let next = CoreAgentSkill(
      id: current.id,
      version: current.version + 1,
      title: current.title,
      body: candidateBody,
      tags: current.tags,
      priority: current.priority,
      provenance: current.provenance + [
        CoreAgentSkillProvenance(
          heldoutSuiteID: proposal.validation.heldoutSuiteID,
          validationScore: proposal.validation.score,
          notes: proposal.validation.notes
        )
      ]
    )
    try await store.save(next)
    return CoreAgentSkillOptimizationResult(
      accepted: true,
      skill: next,
      validation: proposal.validation
    )
  }

  private func reject(
    _ proposal: CoreAgentSkillOptimizationProposal,
    current: CoreAgentSkill,
    reason _: CoreAgentSkillOptimizationRejectionReason
  ) async -> CoreAgentSkillOptimizationResult {
    await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: proposal.candidateEdits,
        validation: proposal.validation
      ),
      skillID: proposal.skillID
    )
    return CoreAgentSkillOptimizationResult(
      accepted: false,
      skill: current,
      validation: proposal.validation
    )
  }

  private static func validateScores(
    _ validation: CoreAgentSkillValidationResult,
    baselineScore: Double
  ) throws {
    guard baselineScore.isFinite,
      baselineScore >= 0,
      baselineScore <= 1,
      validation.score.isFinite,
      validation.score >= 0,
      validation.score <= 1
    else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(validation.score)
    }
    guard !validation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
    }
  }

  private static func policyRejectionReason(
    _ proposal: CoreAgentSkillOptimizationProposal,
    current: CoreAgentSkill,
    policy: CoreAgentSkillOptimizationPolicy
  ) -> CoreAgentSkillOptimizationRejectionReason? {
    if proposal.candidateEdits.count > policy.maxEditsPerProposal {
      return .editBudgetExceeded
    }
    if policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
      return .heldoutSplitLeakage
    }
    if editsProtectedRegion(
      proposal.candidateEdits,
      in: current.body,
      regions: policy.protectedRegions
    ) {
      return .protectedRegionMutation
    }
    if editsExceedLimits(proposal.candidateEdits, body: current.body, limits: policy.editLimits) {
      return .editBudgetExceeded
    }
    let delta = proposal.validation.score - proposal.baselineScore
    guard proposal.validation.passed,
      proposal.validation.score > proposal.baselineScore,
      delta >= policy.minimumScoreDelta
    else {
      return .validationDidNotImprove
    }
    return nil
  }
}

public struct CoreAgentSkillProtectedRegion: Codable, Equatable, Sendable {
  public let name: String
  public let startMarker: String
  public let endMarker: String

  public init(name: String, startMarker: String, endMarker: String) {
    self.name = name
    self.startMarker = startMarker
    self.endMarker = endMarker
  }

  public static let skillOptSlowUpdate = CoreAgentSkillProtectedRegion(
    name: "skillopt-slow-update",
    startMarker: "<!-- coreagent-slow-update:start -->",
    endMarker: "<!-- coreagent-slow-update:end -->"
  )
}

public struct CoreAgentSkillOptimizationPolicy: Codable, Equatable, Sendable {
  public let maxEditsPerProposal: Int
  public let maxAcceptedProposalsPerRun: Int
  public let minimumScoreDelta: Double
  public let trainingSuiteIDs: Set<String>
  public let protectedRegions: [CoreAgentSkillProtectedRegion]
  public let editLimits: CoreAgentSkillEditLimits

  public init(
    maxEditsPerProposal: Int = 3,
    maxAcceptedProposalsPerRun: Int = 1,
    minimumScoreDelta: Double = 0,
    trainingSuiteIDs: Set<String> = [],
    protectedRegions: [CoreAgentSkillProtectedRegion] = [],
    editLimits: CoreAgentSkillEditLimits = .default
  ) {
    self.maxEditsPerProposal = maxEditsPerProposal
    self.maxAcceptedProposalsPerRun = maxAcceptedProposalsPerRun
    self.minimumScoreDelta = minimumScoreDelta
    self.trainingSuiteIDs = trainingSuiteIDs
    self.protectedRegions = protectedRegions
    self.editLimits = editLimits
  }

  func validate() throws {
    guard maxEditsPerProposal > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditsPerProposal must be positive"
      )
    }
    guard maxAcceptedProposalsPerRun > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxAcceptedProposalsPerRun must be positive"
      )
    }
    guard minimumScoreDelta >= 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "minimumScoreDelta must be non-negative"
      )
    }
    guard editLimits.maxEditCharacters > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditCharacters must be positive"
      )
    }
    guard editLimits.maxResultCharacters > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxResultCharacters must be positive"
      )
    }
  }
}

public struct CoreAgentSkillSleepOptimizationProposal: Sendable {
  public let id: String
  public let evidence: [CoreAgentSkillRolloutEvidence]
  public let proposal: CoreAgentSkillOptimizationProposal

  public init(
    id: String,
    evidence: [CoreAgentSkillRolloutEvidence] = [],
    proposal: CoreAgentSkillOptimizationProposal
  ) {
    self.id = id
    self.evidence = evidence
    self.proposal = proposal
  }
}

public struct CoreAgentSkillSleepOptimizationRequest: Sendable {
  public let runID: String
  public let proposals: [CoreAgentSkillSleepOptimizationProposal]
  public let policy: CoreAgentSkillOptimizationPolicy

  public init(
    runID: String,
    proposals: [CoreAgentSkillSleepOptimizationProposal],
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy()
  ) {
    self.runID = runID
    self.proposals = proposals
    self.policy = policy
  }
}

public enum CoreAgentSkillOptimizationDecision: Equatable, Sendable {
  case accepted
  case rejected(CoreAgentSkillOptimizationRejectionReason)
}

public struct CoreAgentSkillSleepOptimizationEntry: Equatable, Sendable {
  public let proposalID: String
  public let skillID: CoreAgentSkillID
  public let decision: CoreAgentSkillOptimizationDecision
  public let skillVersionBefore: Int
  public let skillVersionAfter: Int?
  public let baselineScore: Double
  public let validation: CoreAgentSkillValidationResult
  public let evidenceIDs: [String]

  public init(
    proposalID: String,
    skillID: CoreAgentSkillID,
    decision: CoreAgentSkillOptimizationDecision,
    skillVersionBefore: Int,
    skillVersionAfter: Int?,
    baselineScore: Double,
    validation: CoreAgentSkillValidationResult,
    evidenceIDs: [String]
  ) {
    self.proposalID = proposalID
    self.skillID = skillID
    self.decision = decision
    self.skillVersionBefore = skillVersionBefore
    self.skillVersionAfter = skillVersionAfter
    self.baselineScore = baselineScore
    self.validation = validation
    self.evidenceIDs = evidenceIDs
  }
}

public struct CoreAgentSkillSleepOptimizationReport: Equatable, Sendable {
  public let runID: String
  public let entries: [CoreAgentSkillSleepOptimizationEntry]

  public init(runID: String, entries: [CoreAgentSkillSleepOptimizationEntry]) {
    self.runID = runID
    self.entries = entries
  }

  public var acceptedCount: Int {
    entries.filter { $0.decision == .accepted }.count
  }

  public var rejectedCount: Int {
    entries.count - acceptedCount
  }
}

public struct CoreAgentSkillSleepOptimizer: Sendable {
  private let store: InMemoryCoreAgentSkillStore
  private let optimizer: CoreAgentSkillOptimizer

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
    self.optimizer = CoreAgentSkillOptimizer(store: store)
  }

  public func run(
    _ request: CoreAgentSkillSleepOptimizationRequest
  ) async throws -> CoreAgentSkillSleepOptimizationReport {
    try request.policy.validate()
    try validateUniqueProposalIDs(request.proposals)
    var entries: [CoreAgentSkillSleepOptimizationEntry] = []
    var acceptedCount = 0
    for candidate in request.proposals {
      let proposal = candidate.proposal
      guard let current = await store.currentSkill(id: proposal.skillID) else {
        throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
      }
      if acceptedCount >= request.policy.maxAcceptedProposalsPerRun {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .maxAcceptedProposalsReached
          )
        )
        continue
      }
      if proposal.candidateEdits.count > request.policy.maxEditsPerProposal {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .editBudgetExceeded
          )
        )
        continue
      }
      if request.policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .heldoutSplitLeakage
          )
        )
        continue
      }
      if editsProtectedRegion(
        proposal.candidateEdits,
        in: current.body,
        regions: request.policy.protectedRegions
      ) {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .protectedRegionMutation
          )
        )
        continue
      }
      if editsExceedLimits(
        proposal.candidateEdits,
        body: current.body,
        limits: request.policy.editLimits
      ) {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .editBudgetExceeded
          )
        )
        continue
      }
      let delta = proposal.validation.score - proposal.baselineScore
      guard proposal.validation.passed,
        proposal.validation.score > proposal.baselineScore,
        delta >= request.policy.minimumScoreDelta
      else {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .validationDidNotImprove
          )
        )
        continue
      }

      let result = try await optimizer.propose(proposal, policy: request.policy)
      if result.accepted {
        acceptedCount += 1
        entries.append(
          CoreAgentSkillSleepOptimizationEntry(
            proposalID: candidate.id,
            skillID: proposal.skillID,
            decision: .accepted,
            skillVersionBefore: current.version,
            skillVersionAfter: result.skill.version,
            baselineScore: proposal.baselineScore,
            validation: proposal.validation,
            evidenceIDs: candidate.evidence.map(\.id)
          )
        )
      } else {
        entries.append(
          await reject(
            candidate,
            current: current,
            request: request,
            reason: .validationDidNotImprove
          )
        )
      }
    }
    return CoreAgentSkillSleepOptimizationReport(runID: request.runID, entries: entries)
  }

  private func validateUniqueProposalIDs(
    _ proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws {
    var seen: Set<String> = []
    for proposal in proposals {
      guard seen.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private func reject(
    _ candidate: CoreAgentSkillSleepOptimizationProposal,
    current: CoreAgentSkill,
    request: CoreAgentSkillSleepOptimizationRequest,
    reason: CoreAgentSkillOptimizationRejectionReason
  ) async -> CoreAgentSkillSleepOptimizationEntry {
    await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: candidate.proposal.candidateEdits,
        validation: candidate.proposal.validation
      ),
      skillID: candidate.proposal.skillID
    )
    await store.recordMetaObservation(
      CoreAgentSkillMetaObservation(
        runID: request.runID,
        proposalID: candidate.id,
        reason: reason,
        notes: candidate.proposal.validation.notes
      ),
      skillID: candidate.proposal.skillID
    )
    return CoreAgentSkillSleepOptimizationEntry(
      proposalID: candidate.id,
      skillID: candidate.proposal.skillID,
      decision: .rejected(reason),
      skillVersionBefore: current.version,
      skillVersionAfter: nil,
      baselineScore: candidate.proposal.baselineScore,
      validation: candidate.proposal.validation,
      evidenceIDs: candidate.evidence.map(\.id)
    )
  }

}

private func editsExceedLimits(
  _ edits: [CoreAgentSkillEdit],
  body: String,
  limits: CoreAgentSkillEditLimits
) -> Bool {
  var candidateBody = body
  for edit in edits {
    do {
      candidateBody = try edit.apply(to: candidateBody, limits: limits)
    } catch CoreAgentSkillOptimizationError.editTooLarge,
      CoreAgentSkillOptimizationError.resultingSkillTooLarge
    {
      return true
    } catch {
      return false
    }
  }
  return false
}

private func editsProtectedRegion(
  _ edits: [CoreAgentSkillEdit],
  in body: String,
  regions: [CoreAgentSkillProtectedRegion]
) -> Bool {
  guard !regions.isEmpty else { return false }
  let protectedRanges = regions.flatMap { protectedRanges(for: $0, in: body) }
  guard !protectedRanges.isEmpty else { return false }
  for edit in edits {
    guard case .replace(let target, _) = edit,
      let targetRange = body.range(of: target)
    else {
      continue
    }
    if protectedRanges.contains(where: { $0.overlaps(targetRange) }) {
      return true
    }
  }
  return false
}

private func protectedRanges(
  for region: CoreAgentSkillProtectedRegion,
  in body: String
) -> [Range<String.Index>] {
  var ranges: [Range<String.Index>] = []
  var searchStart = body.startIndex
  while searchStart < body.endIndex,
    let start = body.range(of: region.startMarker, range: searchStart..<body.endIndex)
  {
    guard let end = body.range(of: region.endMarker, range: start.upperBound..<body.endIndex)
    else {
      ranges.append(start.lowerBound..<body.endIndex)
      return ranges
    }
    ranges.append(start.lowerBound..<end.upperBound)
    searchStart = end.upperBound
  }
  return ranges
}

public enum CoreAgentSkillExporter {
  public static func bestSkillMarkdown(_ skill: CoreAgentSkill) -> String {
    var lines: [String] = [
      "# \(skill.title)",
      "",
      "Version: \(skill.version)",
      "Tags: \(skill.tags.joined(separator: ", "))",
      "",
      skill.body,
    ]
    if let latest = skill.provenance.last {
      lines.append("")
      lines.append("Heldout Suite: \(latest.heldoutSuiteID)")
      lines.append("Validation Score: \(latest.validationScore)")
    }
    return lines.joined(separator: "\n")
  }
}

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

public struct CoreAgentHarnessAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let meanScore: Double
  public let heldoutSuiteIDs: [String]
}

public struct CoreAgentHarnessOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessAuditEntry]
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
}

--- Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift ---
import CoreAgentSkills
import Foundation
import Testing

@Suite("CoreAgentSkills SkillOpt foundation")
struct CoreAgentSkillsTests {
  @Test("Curates skills by tags priority and context budget")
  func curatesSkillsByTagsPriorityAndContextBudget() async throws {
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(Self.skill(id: "planner", body: "Plan carefully.", tags: ["planning"], priority: 10))
    try await store.save(Self.skill(id: "swift", body: "Use Swift Testing.", tags: ["swift"], priority: 20))
    try await store.save(Self.skill(id: "long", body: String(repeating: "x", count: 200), tags: ["swift"], priority: 30))

    let curator = CoreAgentSkillCurator(store: store)
    let curated = await curator.curate(
      query: CoreAgentSkillCurationQuery(tags: ["swift", "planning"], maxCharacters: 60)
    )

    #expect(curated.map(\.id.rawValue) == ["swift", "planner"])
    #expect(curated.reduce(0) { $0 + $1.body.count } <= 60)
  }

  @Test("Validation-gated edits improve score before mutating current skill")
  func validationGatedEditsImproveScoreBeforeMutatingCurrentSkill() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [
          .replace(
            target: "Use XCTest.",
            replacement: "Use Swift Testing with typed assertions."
          )
        ],
        validation: CoreAgentSkillValidationResult(
          score: 0.82,
          heldoutSuiteID: "heldout-swift",
          passed: true,
          notes: "Improves the heldout suite."
        )
      )
    )

    let current = try #require(await store.currentSkill(id: base.id))
    #expect(result.accepted)
    #expect(current.version == 2)
    #expect(current.body == "Use Swift Testing with typed assertions.")
    #expect(current.provenance.last?.heldoutSuiteID == "heldout-swift")
  }

  @Test("Rejected edits are retained as optimizer memory without mutating the skill")
  func rejectedEditsAreRetainedAsOptimizerMemoryWithoutMutatingSkill() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.90,
        candidateEdits: [.append("\nAlways force unwrap.")],
        validation: CoreAgentSkillValidationResult(
          score: 0.40,
          heldoutSuiteID: "heldout-safety",
          passed: false,
          notes: "Introduces unsafe code."
        )
      )
    )

    let current = try #require(await store.currentSkill(id: base.id))
    let memory = await store.optimizerMemory(skillID: base.id)
    #expect(!result.accepted)
    #expect(current.body == base.body)
    #expect(memory.rejectedEdits.count == 1)
    #expect(memory.rejectedEdits.first?.validation.heldoutSuiteID == "heldout-safety")
  }

  @Test("Direct optimizer enforces policy gates and edit size budgets")
  func directOptimizerEnforcesPolicyGatesAndEditSizeBudgets() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(
      id: "swift",
      body: """
        Use XCTest.
        <!-- coreagent-slow-update:start -->
        Preserve slow update memory.
        <!-- coreagent-slow-update:end -->
        """
    )
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)
    let policy = CoreAgentSkillOptimizationPolicy(
      maxEditsPerProposal: 1,
      maxAcceptedProposalsPerRun: 1,
      minimumScoreDelta: 0.05,
      trainingSuiteIDs: ["train-swift"],
      protectedRegions: [.skillOptSlowUpdate],
      editLimits: CoreAgentSkillEditLimits(maxEditCharacters: 40, maxResultCharacters: 180)
    )

    let oversized = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.append(String(repeating: "x", count: 41))],
        validation: Self.validation(score: 0.90)
      ),
      policy: policy
    )
    let splitLeak = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
        validation: Self.validation(score: 0.90, heldoutSuiteID: "train-swift")
      ),
      policy: policy
    )
    let protectedEdit = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [
          .replace(
            target: "Preserve slow update memory.",
            replacement: "Overwrite protected memory."
          )
        ],
        validation: Self.validation(score: 0.90)
      ),
      policy: policy
    )
    let valid = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
        validation: Self.validation(score: 0.86)
      ),
      policy: policy
    )

    let current = try #require(await store.currentSkill(id: base.id))
    let memory = await store.optimizerMemory(skillID: base.id)
    #expect(!oversized.accepted)
    #expect(!splitLeak.accepted)
    #expect(!protectedEdit.accepted)
    #expect(valid.accepted)
    #expect(current.version == 2)
    #expect(current.body.contains("Use Swift Testing."))
    #expect(current.body.contains("Preserve slow update memory."))
    #expect(memory.rejectedEdits.count == 3)
  }

  @Test("Edit limits reject oversized standalone edits")
  func editLimitsRejectOversizedStandaloneEdits() throws {
    let limits = CoreAgentSkillEditLimits(maxEditCharacters: 3, maxResultCharacters: 10)

    #expect(throws: CoreAgentSkillOptimizationError.editTooLarge) {
      _ = try CoreAgentSkillEdit.append("1234").apply(to: "base", limits: limits)
    }
    #expect(throws: CoreAgentSkillOptimizationError.resultingSkillTooLarge) {
      _ = try CoreAgentSkillEdit.append("123").apply(to: "basebase", limits: limits)
    }
  }

  @Test("Protected-region policy covers repeated slow-update blocks")
  func protectedRegionPolicyCoversRepeatedSlowUpdateBlocks() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(
      id: "swift",
      body: """
        <!-- coreagent-slow-update:start -->
        Protected A
        <!-- coreagent-slow-update:end -->

        Use XCTest.

        <!-- coreagent-slow-update:start -->
        Protected B
        <!-- coreagent-slow-update:end -->
        """
    )
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.replace(target: "Protected B", replacement: "Overwrite")],
        validation: Self.validation(score: 0.90)
      ),
      policy: CoreAgentSkillOptimizationPolicy(protectedRegions: [.skillOptSlowUpdate])
    )

    let current = try #require(await store.currentSkill(id: base.id))
    #expect(!result.accepted)
    #expect(current.version == 1)
    #expect(current.body.contains("Protected B"))
  }

  @Test("Rejects duplicate skill versions instead of silently losing updates")
  func rejectsDuplicateSkillVersionsInsteadOfSilentlyLosingUpdates() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await store.save(base)

    await #expect(throws: CoreAgentSkillOptimizationError.versionCollision(base.id, 1)) {
      try await store.save(base)
    }
  }

  @Test("Exports the current best skill as best_skill markdown")
  func exportsCurrentBestSkillMarkdown() async throws {
    let skill = Self.skill(
      id: "swift",
      body: "Use Swift Testing.",
      tags: ["swift", "testing"],
      priority: 5
    )

    let markdown = CoreAgentSkillExporter.bestSkillMarkdown(skill)

    #expect(markdown.contains("# swift"))
    #expect(markdown.contains("Version: 1"))
    #expect(markdown.contains("Tags: swift, testing"))
    #expect(markdown.contains("Use Swift Testing."))
  }

  @Test("Harness optimizer selects the best heldout configuration")
  func harnessOptimizerSelectsBestHeldoutConfiguration() async throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let result = try optimizer.selectBest(
      candidates: [
        CoreAgentHarnessCandidate(id: "small", parameters: ["temperature": "0.2"]),
        CoreAgentHarnessCandidate(id: "large", parameters: ["temperature": "0.0"]),
      ],
      evaluations: [
        CoreAgentHarnessEvaluation(candidateID: "small", heldoutSuiteID: "heldout-a", score: 0.74),
        CoreAgentHarnessEvaluation(candidateID: "large", heldoutSuiteID: "heldout-a", score: 0.91),
      ]
    )

    #expect(result.best.id == "large")
    #expect(result.heldoutSuiteIDs == ["heldout-a"])
    #expect(result.auditTrail.map(\.candidateID) == ["large", "small"])
  }

  @Test("Harness optimizer rejects duplicate candidate IDs without crashing")
  func harnessOptimizerRejectsDuplicateCandidateIDsWithoutCrashing() throws {
    let optimizer = CoreAgentHarnessOptimizer()

    #expect(throws: CoreAgentSkillOptimizationError.duplicateHarnessCandidate("same")) {
      _ = try optimizer.selectBest(
        candidates: [
          CoreAgentHarnessCandidate(id: "same", parameters: ["temperature": "0.2"]),
          CoreAgentHarnessCandidate(id: "same", parameters: ["temperature": "0.0"]),
        ],
        evaluations: [
          CoreAgentHarnessEvaluation(candidateID: "same", heldoutSuiteID: "heldout-a", score: 0.74)
        ]
      )
    }
  }

  @Test("Sleep optimizer enforces learning rate split and protected-region policy")
  func sleepOptimizerEnforcesLearningRateSplitAndProtectedRegionPolicy() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(
      id: "swift",
      body: """
        Use XCTest.
        <!-- coreagent-slow-update:start -->
        Keep hard-won rollout memory.
        <!-- coreagent-slow-update:end -->
        """,
      tags: ["swift", "testing"]
    )
    try await store.save(base)
    let sleepOptimizer = CoreAgentSkillSleepOptimizer(store: store)

    let report = try await sleepOptimizer.run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "sleep-epoch-1",
        proposals: [
          CoreAgentSkillSleepOptimizationProposal(
            id: "too-many-edits",
            proposal: CoreAgentSkillOptimizationProposal(
              skillID: base.id,
              baselineScore: 0.70,
              candidateEdits: [
                .replace(target: "Use XCTest.", replacement: "Use Swift Testing."),
                .append("\nPrefer typed assertions."),
              ],
              validation: Self.validation(score: 0.90)
            )
          ),
          CoreAgentSkillSleepOptimizationProposal(
            id: "split-leak",
            proposal: CoreAgentSkillOptimizationProposal(
              skillID: base.id,
              baselineScore: 0.70,
              candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
              validation: Self.validation(score: 0.90, heldoutSuiteID: "train-swift")
            )
          ),
          CoreAgentSkillSleepOptimizationProposal(
            id: "slow-region-edit",
            proposal: CoreAgentSkillOptimizationProposal(
              skillID: base.id,
              baselineScore: 0.70,
              candidateEdits: [
                .replace(
                  target: "Keep hard-won rollout memory.",
                  replacement: "Overwrite slow memory."
                )
              ],
              validation: Self.validation(score: 0.90)
            )
          ),
          CoreAgentSkillSleepOptimizationProposal(
            id: "accepted",
            evidence: [
              CoreAgentSkillRolloutEvidence(
                id: "trace-a",
                taskID: "task-1",
                transcriptDigest: "sha256:transcript",
                toolEventDigest: "sha256:tools",
                verifierFeedback: "XCTest remained in the answer.",
                score: 0.40,
                metadata: ["issue": "testing-framework"]
              )
            ],
            proposal: CoreAgentSkillOptimizationProposal(
              skillID: base.id,
              baselineScore: 0.70,
              candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
              validation: Self.validation(score: 0.86)
            )
          ),
        ],
        policy: CoreAgentSkillOptimizationPolicy(
          maxEditsPerProposal: 1,
          maxAcceptedProposalsPerRun: 1,
          minimumScoreDelta: 0.05,
          trainingSuiteIDs: ["train-swift"],
          protectedRegions: [.skillOptSlowUpdate]
        )
      )
    )

    let current = try #require(await store.currentSkill(id: base.id))
    let memory = await store.optimizerMemory(skillID: base.id)
    #expect(current.version == 2)
    #expect(current.body.contains("Use Swift Testing."))
    #expect(current.body.contains("Keep hard-won rollout memory."))
    #expect(report.acceptedCount == 1)
    #expect(report.rejectedCount == 3)
    #expect(report.entries.map(\.proposalID) == [
      "too-many-edits",
      "split-leak",
      "slow-region-edit",
      "accepted",
    ])
    #expect(report.entries.map(\.decision) == [
      .rejected(.editBudgetExceeded),
      .rejected(.heldoutSplitLeakage),
      .rejected(.protectedRegionMutation),
      .accepted,
    ])
    #expect(report.entries.last?.evidenceIDs == ["trace-a"])
    #expect(memory.rejectedEdits.count == 3)
    #expect(memory.metaObservations.map(\.proposalID) == [
      "too-many-edits",
      "split-leak",
      "slow-region-edit",
    ])
  }

  @Test("Sleep optimizer rejects duplicate proposal IDs before mutating skills")
  func sleepOptimizerRejectsDuplicateProposalIDsBeforeMutatingSkills() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let sleepOptimizer = CoreAgentSkillSleepOptimizer(store: store)
    let proposal = CoreAgentSkillSleepOptimizationProposal(
      id: "duplicate",
      proposal: CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
        validation: Self.validation(score: 0.90)
      )
    )

    await #expect(throws: CoreAgentSkillOptimizationError.duplicateOptimizationProposal("duplicate")) {
      _ = try await sleepOptimizer.run(
        CoreAgentSkillSleepOptimizationRequest(
          runID: "sleep-epoch-duplicates",
          proposals: [proposal, proposal]
        )
      )
    }
    let current = try #require(await store.currentSkill(id: base.id))
    #expect(current.version == 1)
    #expect(current.body == "Use XCTest.")
  }

  @Test("Whitespace-only replacement targets are rejected")
  func whitespaceOnlyReplacementTargetsAreRejected() throws {
    #expect(throws: CoreAgentSkillOptimizationError.emptyReplacementTarget) {
      _ = try CoreAgentSkillEdit.replace(target: "   ", replacement: "new").apply(
        to: "old value"
      )
    }
  }

  private static func skill(
    id: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0
  ) -> CoreAgentSkill {
    CoreAgentSkill(
      id: CoreAgentSkillID(id),
      version: 1,
      title: id,
      body: body,
      tags: tags,
      priority: priority
    )
  }
