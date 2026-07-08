import CoreAgent
import CoreAgentAgenticKit
import CoreAgentDeep
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentAgenticKitTests {
  @Test("Rubric verdict gates Engine Skills feedback loop")
  func rubricVerdictGatesEngineSkillsFeedbackLoop() async throws {
    let kit = CoreAgentAgenticKit(
      configuration: CoreAgentAgenticKitConfiguration(
        projectID: "feedback",
        threadID: "thread-rubric"
      )
    )
    let session = try kit.makeSession(
      model: RecordedLanguageModel(steps: [.response(text: "answer without required proof")])
    )
    let rubric = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, _, _ in
        CoreAgentDeepRubricEvaluation(
          verdict: .failed,
          iteration: 1,
          criteria: [
            CoreAgentDeepRubricCriterionFeedback(
              criterion: "mentions required proof",
              passed: false,
              feedback: "missing proof"
            )
          ],
          revisionMessage: nil
        )
      }
    )
    let rubricResult = try await rubric.respond(
      session: session,
      to: "Produce an answer with required proof.",
      rubric: "Must mention required proof."
    )
    #expect(rubricResult.status == .failed)
    #expect(
      await kit.engineStore.trace(projectID: "feedback", runID: rubricResult.run.id) != nil
    )

    let skillStore = InMemoryCoreAgentSkillStore()
    let skill = CoreAgentSkill(
      id: "rubric-skill",
      version: 1,
      title: "Rubric skill",
      body: "Use XCTest.",
      tags: ["rubric"]
    )
    try await skillStore.save(skill)
    let loop = CoreAgentAgenticKitFeedbackLoop(
      projectID: "feedback",
      threadID: "thread-rubric",
      engineStore: kit.engineStore,
      skillStore: skillStore
    )

    let missingProofBackend = RubricFeedbackProposalBackend(includesProof: false)
    let missingProof = try await loop.processRubricVerdict(
      rubricResult,
      target: CoreAgentSkillOptimizationRunTarget(skillID: skill.id, baselineScore: 0.50),
      proposalBackend: missingProofBackend,
      policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true),
      maxProposals: 1
    )
    let missingProofRequest = try #require(await missingProofBackend.lastRequest)
    let currentAfterMissingProof = try #require(await skillStore.currentSkill(id: skill.id))
    let missingProofDecisions = missingProof.sleepReport?.entries.map { $0.decision } ?? []

    #expect(missingProof.issue?.contributingRunIDs == [rubricResult.run.id])
    #expect(missingProof.harvestedEvidenceIDs.count == 1)
    #expect(missingProof.generatedProposalIDs == ["rubric-feedback-proposal"])
    #expect(missingProofDecisions == [.rejected(.validationDidNotImprove)])
    #expect(currentAfterMissingProof.version == 1)
    #expect(missingProofRequest.evidence.first?.metadata["source"] == "coreagent-engine")
    #expect(
      missingProofRequest.evidence.first?.metadata["issue_id_digest"]?.hasPrefix("sha256:")
        == true
    )

    let provenBackend = RubricFeedbackProposalBackend(includesProof: true)
    let proven = try await loop.processRubricVerdict(
      rubricResult,
      target: CoreAgentSkillOptimizationRunTarget(skillID: skill.id, baselineScore: 0.50),
      proposalBackend: provenBackend,
      policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true),
      maxProposals: 1
    )
    let currentAfterProof = try #require(await skillStore.currentSkill(id: skill.id))
    let issues = await kit.engineStore.issues(projectID: "feedback", status: .open)

    #expect(proven.issue?.id == missingProof.issue?.id)
    #expect(proven.sleepReport?.acceptedCount == 1)
    #expect(currentAfterProof.version == 2)
    #expect(currentAfterProof.body == "Use Swift Testing with rubric evidence.")
    #expect(issues.count == 1)
    #expect(issues.first?.contributingRunIDs == [rubricResult.run.id])
  }
}

private actor RubricFeedbackProposalBackend: CoreAgentSkillModelProposalBackend {
  let includesProof: Bool
  private(set) var lastRequest: CoreAgentSkillModelProposalRequest?

  init(includesProof: Bool) {
    self.includesProof = includesProof
  }

  func generate(
    _ request: CoreAgentSkillModelProposalRequest
  ) async throws -> [CoreAgentSkillModelProposalCandidate] {
    lastRequest = request
    let evidenceIDs = request.evidence.map(\.id)
    let proof =
      includesProof
      ? CoreAgentSkillHeldoutValidationProof(
        heldoutSuiteID: "heldout-rubric",
        evidenceIDs: evidenceIDs,
        score: 0.90,
        passed: true,
        validatorID: "rlm-rubric",
        proofDigest: request.evidence.first?.transcriptDigest
          ?? "sha256:\(String(repeating: "0", count: 64))"
      )
      : nil
    return [
      CoreAgentSkillModelProposalCandidate(
        id: "rubric-feedback-proposal",
        skillID: request.skill.id,
        baselineScore: request.baselineScore,
        candidateEdits: [
          .replace(
            target: "Use XCTest.",
            replacement: "Use Swift Testing with rubric evidence."
          )
        ],
        validation: CoreAgentSkillValidationResult(
          score: 0.90,
          heldoutSuiteID: "heldout-rubric",
          passed: true,
          notes: "rubric feedback validation",
          heldoutProof: proof
        ),
        evidenceIDs: evidenceIDs
      )
    ]
  }
}
