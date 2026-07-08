import CoreAgent
import CoreAgentDeep
import CoreAgentEngine
import CoreAgentSkills
import CryptoKit
import Foundation

public enum CoreAgentAgenticKitFeedbackLoopError: Error, Equatable, Sendable {
  case missingTargetSkill(CoreAgentSkillID)
  case missingVerifiedEngineTrace(UUID)
  case missingEngineIssueEvidence(UUID)
}

public struct CoreAgentAgenticKitFeedbackLoopReport: Equatable, Sendable {
  public let issue: CoreAgentEngineIssue?
  public let harvestedEvidenceIDs: [String]
  public let generatedProposalIDs: [String]
  public let sleepReport: CoreAgentSkillSleepOptimizationReport?

  public init(
    issue: CoreAgentEngineIssue?,
    harvestedEvidenceIDs: [String],
    generatedProposalIDs: [String],
    sleepReport: CoreAgentSkillSleepOptimizationReport?
  ) {
    self.issue = issue
    self.harvestedEvidenceIDs = harvestedEvidenceIDs
    self.generatedProposalIDs = generatedProposalIDs
    self.sleepReport = sleepReport
  }
}

public struct CoreAgentAgenticKitFeedbackLoop: Sendable {
  private let projectID: String
  private let threadID: String?
  private let engineStore: any CoreAgentEngineStore
  private let skillStore: any CoreAgentSkillStore

  public init(
    projectID: String,
    threadID: String? = nil,
    engineStore: any CoreAgentEngineStore,
    skillStore: any CoreAgentSkillStore
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.engineStore = engineStore
    self.skillStore = skillStore
  }

  public func processRubricVerdict(
    _ rubricResult: CoreAgentDeepRubricResult,
    target: CoreAgentSkillOptimizationRunTarget,
    proposalBackend: any CoreAgentSkillModelProposalBackend,
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(
      requiresHeldoutValidationProof: true
    ),
    maxProposals: Int = 3
  ) async throws -> CoreAgentAgenticKitFeedbackLoopReport {
    guard let skill = await skillStore.currentSkill(id: target.skillID) else {
      throw CoreAgentAgenticKitFeedbackLoopError.missingTargetSkill(target.skillID)
    }
    guard Self.shouldOpenEngineIssue(for: rubricResult) else {
      return CoreAgentAgenticKitFeedbackLoopReport(
        issue: nil,
        harvestedEvidenceIDs: [],
        generatedProposalIDs: [],
        sleepReport: nil
      )
    }
    guard
      await engineStore.trace(
        projectID: projectID,
        runID: rubricResult.run.id
      ) != nil
    else {
      throw CoreAgentAgenticKitFeedbackLoopError.missingVerifiedEngineTrace(
        rubricResult.run.id
      )
    }

    let issue = try await engineStore.upsertIssue(
      Self.issue(for: rubricResult, projectID: projectID)
    )
    let harvested = await CoreAgentSkillEngineTraceHarvester(engineStore: engineStore).harvest(
      projectID: projectID,
      threadID: threadID
    )
    let runID = rubricResult.run.id.uuidString.lowercased()
    let linkedEvidence = harvested.filter {
      $0.metadata["run_id"] == runID && $0.metadata["issue_id_digest"] != nil
    }
    guard !linkedEvidence.isEmpty else {
      throw CoreAgentAgenticKitFeedbackLoopError.missingEngineIssueEvidence(
        rubricResult.run.id
      )
    }

    let proposals = try await CoreAgentSkillModelProposalGenerator(
      backend: proposalBackend
    ).generate(
      runID: "rubric-feedback-\(runID)",
      skill: skill,
      baselineScore: target.baselineScore,
      evidence: linkedEvidence,
      policy: policy,
      maxProposals: maxProposals
    )
    let sleepReport = try await CoreAgentSkillSleepOptimizer(store: skillStore).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "rubric-feedback-\(runID)",
        proposals: proposals,
        policy: policy
      )
    )

    return CoreAgentAgenticKitFeedbackLoopReport(
      issue: issue,
      harvestedEvidenceIDs: linkedEvidence.map(\.id),
      generatedProposalIDs: proposals.map(\.id),
      sleepReport: sleepReport
    )
  }

  private static func shouldOpenEngineIssue(
    for result: CoreAgentDeepRubricResult
  ) -> Bool {
    guard result.status == .satisfied else { return true }
    return result.evaluations.contains { $0.verdict != .satisfied }
  }

  private static func issue(
    for result: CoreAgentDeepRubricResult,
    projectID: String
  ) -> CoreAgentEngineIssue {
    let verdict = result.evaluations.last?.verdict ?? CoreAgentDeepRubricVerdict.failed
    let failedCriteria = result.evaluations.last?.criteria.filter { !$0.passed }.count ?? 0
    let fingerprint = [
      "rubric",
      result.status.rawValue,
      verdict.rawValue,
      "\(failedCriteria)",
    ].map { "\($0.count):\($0)" }.joined(separator: "|")
    return CoreAgentEngineIssue(
      id: issueID(projectID: projectID, fingerprint: fingerprint),
      projectID: projectID,
      fingerprint: fingerprint,
      title: "rubric verdict: \(result.status.rawValue) / \(verdict.rawValue)",
      contributingRunIDs: [result.run.id],
      status: .open,
      firstSeenAt: result.run.startedAt,
      lastSeenAt: result.run.endedAt
    )
  }

  private static func issueID(projectID: String, fingerprint: String) -> String {
    let payload = Data(
      "coreagent-agentickit-rubric-issue-v1\u{0}\(projectID)\u{0}\(fingerprint)".utf8
    )
    return "issue-\(sha256Hex(payload))"
  }
}

extension CoreAgentAgenticKit {
  public func makeFeedbackLoop(
    skillStore: any CoreAgentSkillStore
  ) -> CoreAgentAgenticKitFeedbackLoop {
    CoreAgentAgenticKitFeedbackLoop(
      projectID: configuration.projectID,
      threadID: configuration.threadID,
      engineStore: engineStore,
      skillStore: skillStore
    )
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
