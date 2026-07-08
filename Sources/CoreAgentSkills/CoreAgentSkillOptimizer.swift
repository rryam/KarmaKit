import Foundation

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
  private let store: any CoreAgentSkillStore

  public init(store: any CoreAgentSkillStore) {
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
  private let store: any CoreAgentSkillStore

  public init(store: any CoreAgentSkillStore) {
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
    try validateSkillOptimizationScores(proposal.validation, baselineScore: proposal.baselineScore)
    if let reason = Self.policyRejectionReason(
      proposal,
      current: current,
      policy: policy
    ) {
      return try await reject(proposal, current: current, reason: reason)
    }

    let candidateBody = try applyEdits(
      proposal.candidateEdits,
      to: current.body,
      limits: policy.editLimits
    )

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
  ) async throws -> CoreAgentSkillOptimizationResult {
    try await store.recordRejected(
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
    for region in protectedRegions {
      guard !region.startMarker.isEmpty, !region.endMarker.isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "protected region markers must be non-empty"
        )
      }
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
  private let store: any CoreAgentSkillStore
  private let optimizer: CoreAgentSkillOptimizer

  public init(store: any CoreAgentSkillStore) {
    self.store = store
    self.optimizer = CoreAgentSkillOptimizer(store: store)
  }

  public func run(
    _ request: CoreAgentSkillSleepOptimizationRequest
  ) async throws -> CoreAgentSkillSleepOptimizationReport {
    try request.policy.validate()
    try validateUniqueProposalIDs(request.proposals)
    try await preflight(request)
    var entries: [CoreAgentSkillSleepOptimizationEntry] = []
    var acceptedCount = 0
    for candidate in request.proposals {
      let proposal = candidate.proposal
      guard let current = await store.currentSkill(id: proposal.skillID) else {
        throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
      }
      if acceptedCount >= request.policy.maxAcceptedProposalsPerRun {
        entries.append(
          try await reject(
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
          try await reject(
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
          try await reject(
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
          try await reject(
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
          try await reject(
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
          try await reject(
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
          try await reject(
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

  private func preflight(_ request: CoreAgentSkillSleepOptimizationRequest) async throws {
    var simulatedSkillsByID: [CoreAgentSkillID: CoreAgentSkill] = [:]
    var acceptedCount = 0
    for candidate in request.proposals {
      let proposal = candidate.proposal
      let current: CoreAgentSkill
      if let simulated = simulatedSkillsByID[proposal.skillID] {
        current = simulated
      } else if let stored = await store.currentSkill(id: proposal.skillID) {
        current = stored
      } else {
        throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
      }
      try validateSkillOptimizationScores(
        proposal.validation,
        baselineScore: proposal.baselineScore
      )
      if acceptedCount >= request.policy.maxAcceptedProposalsPerRun {
        continue
      }
      if proposal.candidateEdits.count > request.policy.maxEditsPerProposal {
        continue
      }
      if request.policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
        continue
      }
      if editsProtectedRegion(
        proposal.candidateEdits,
        in: current.body,
        regions: request.policy.protectedRegions
      ) {
        continue
      }
      if editsExceedLimits(
        proposal.candidateEdits,
        body: current.body,
        limits: request.policy.editLimits
      ) {
        continue
      }
      let delta = proposal.validation.score - proposal.baselineScore
      guard proposal.validation.passed,
        proposal.validation.score > proposal.baselineScore,
        delta >= request.policy.minimumScoreDelta
      else {
        continue
      }
      let candidateBody = try applyEdits(
        proposal.candidateEdits,
        to: current.body,
        limits: request.policy.editLimits
      )
      simulatedSkillsByID[proposal.skillID] = CoreAgentSkill(
        id: current.id,
        version: current.version + 1,
        title: current.title,
        body: candidateBody,
        tags: current.tags,
        priority: current.priority,
        provenance: current.provenance
      )
      acceptedCount += 1
    }
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
  ) async throws -> CoreAgentSkillSleepOptimizationEntry {
    try await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: candidate.proposal.candidateEdits,
        validation: candidate.proposal.validation
      ),
      skillID: candidate.proposal.skillID
    )
    try await store.recordMetaObservation(
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
  do {
    _ = try applyEdits(edits, to: body, limits: limits)
    return false
  } catch CoreAgentSkillOptimizationError.editTooLarge,
    CoreAgentSkillOptimizationError.resultingSkillTooLarge
  {
    return true
  } catch {
    return false
  }
}

private func applyEdits(
  _ edits: [CoreAgentSkillEdit],
  to body: String,
  limits: CoreAgentSkillEditLimits
) throws -> String {
  var candidateBody = body
  for edit in edits {
    candidateBody = try edit.apply(to: candidateBody, limits: limits)
  }
  return candidateBody
}

private func validateSkillOptimizationScores(
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

private func editsProtectedRegion(
  _ edits: [CoreAgentSkillEdit],
  in body: String,
  regions: [CoreAgentSkillProtectedRegion]
) -> Bool {
  guard !regions.isEmpty else { return false }
  let protectedRanges = regions.flatMap { protectedRanges(for: $0, in: body) }
  guard !protectedRanges.isEmpty else { return false }
  for edit in edits {
    switch edit {
    case .append:
      if protectedRanges.contains(where: \.isOpenEnded) {
        return true
      }
    case .replace(let target, _):
      guard let targetRange = body.range(of: target) else {
        continue
      }
      if protectedRanges.contains(where: { $0.range.overlaps(targetRange) }) {
        return true
      }
    }
  }
  return false
}

private struct CoreAgentProtectedSkillRange {
  let range: Range<String.Index>
  let isOpenEnded: Bool
}

private func protectedRanges(
  for region: CoreAgentSkillProtectedRegion,
  in body: String
) -> [CoreAgentProtectedSkillRange] {
  guard !region.startMarker.isEmpty, !region.endMarker.isEmpty else {
    return []
  }
  var ranges: [CoreAgentProtectedSkillRange] = []
  var searchStart = body.startIndex
  while searchStart < body.endIndex,
    let start = body.range(of: region.startMarker, range: searchStart..<body.endIndex)
  {
    guard let end = body.range(of: region.endMarker, range: start.upperBound..<body.endIndex)
    else {
      ranges.append(
        CoreAgentProtectedSkillRange(
          range: start.lowerBound..<body.endIndex,
          isOpenEnded: true
        )
      )
      return ranges
    }
    ranges.append(
      CoreAgentProtectedSkillRange(
        range: start.lowerBound..<end.upperBound,
        isOpenEnded: false
      )
    )
    searchStart = end.upperBound
  }
  return ranges
}
