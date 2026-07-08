import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
  @Test("Engine plugin produces no autonomous mutation")
  func enginePluginProducesNoAutonomousMutation() async throws {
    let engineStore = InMemoryCoreAgentEngineStore()
    let plugin = CoreAgentEnginePlugin(
      store: engineStore,
      projectID: "coreagent",
      threadID: "thread-engine"
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "observed")]),
      plugins: [plugin]
    )

    let response = try await session.respond(to: "capture this run")
    let trace = try #require(
      await engineStore.trace(projectID: "coreagent", runID: response.run.id)
    )
    #expect(trace.receipt.verify())

    let skillStore = InMemoryCoreAgentSkillStore()
    let skill = Self.skill(id: "swift", body: "Use XCTest.")
    try await skillStore.save(skill)
    let evidence = await CoreAgentSkillEngineTraceHarvester(engineStore: engineStore).harvest(
      projectID: "coreagent",
      threadID: "thread-engine"
    )
    let evidenceID = try #require(evidence.first?.id)
    let backend = CapturingModelProposalBackend(candidates: [
      CoreAgentSkillModelProposalCandidate(
        id: "engine-proposed-fix",
        skillID: skill.id,
        baselineScore: 0.80,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
        validation: CoreAgentSkillValidationResult(
          score: 0.70,
          heldoutSuiteID: "heldout-engine",
          passed: false,
          notes: "held-out validation did not improve"
        ),
        evidenceIDs: [evidenceID]
      )
    ])

    let proposals = try await CoreAgentSkillModelProposalGenerator(backend: backend).generate(
      runID: "engine-sleep-run",
      skill: skill,
      baselineScore: 0.80,
      evidence: evidence,
      policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true),
      maxProposals: 1
    )
    let currentAfterGeneration = try #require(await skillStore.currentSkill(id: skill.id))
    let memoryAfterGeneration = await skillStore.optimizerMemory(skillID: skill.id)
    let artifact = try #require(proposals.first?.artifact)

    #expect(proposals.map(\.id) == ["engine-proposed-fix"])
    #expect(artifact.source == .modelProposal)
    #expect(artifact.skillID == skill.id)
    #expect(artifact.evidenceIDs == [evidenceID])
    #expect(currentAfterGeneration.version == 1)
    #expect(currentAfterGeneration.body == "Use XCTest.")
    #expect(memoryAfterGeneration.rejectedEdits.isEmpty)
    #expect(memoryAfterGeneration.metaObservations.isEmpty)

    let report = try await CoreAgentSkillSleepOptimizer(store: skillStore).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "engine-sleep-run",
        proposals: proposals,
        policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true)
      )
    )
    let currentAfterSleep = try #require(await skillStore.currentSkill(id: skill.id))
    let memoryAfterSleep = await skillStore.optimizerMemory(skillID: skill.id)

    #expect(report.acceptedCount == 0)
    #expect(report.entries.map(\.decision) == [.rejected(.validationDidNotImprove)])
    #expect(currentAfterSleep.version == 1)
    #expect(currentAfterSleep.body == "Use XCTest.")
    #expect(memoryAfterSleep.rejectedEdits.count == 1)
    #expect(memoryAfterSleep.metaObservations.map(\.reason) == [.validationDidNotImprove])
  }

  @Test("Held-out proof gate is load-bearing for an improving unproven proposal")
  func heldoutProofGateRejectsImprovingProposalWithoutProof() async throws {
    // Both a missing held-out proof and a score regression surface as
    // `.validationDidNotImprove`, so a test whose proposal *regresses* the score cannot
    // prove the proof gate does anything. This test isolates the gate by using an
    // *improving* proposal (0.90 vs 0.50 baseline, passed) that clears the score-delta
    // guard, so the only thing that can reject it is the held-out proof requirement.
    let improvingValidationWithoutProof = CoreAgentSkillValidationResult(
      score: 0.90,
      heldoutSuiteID: "heldout-proof-gate",
      passed: true,
      notes: "improves score but carries no held-out proof"
    )
    func makeProposal(
      id: String,
      validation: CoreAgentSkillValidationResult
    ) -> CoreAgentSkillSleepOptimizationProposal {
      CoreAgentSkillSleepOptimizationProposal(
        id: id,
        proposal: CoreAgentSkillOptimizationProposal(
          skillID: "proof-gate",
          baselineScore: 0.50,
          candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
          validation: validation
        )
      )
    }

    // Control: with the gate OFF, the same improving-but-unproven proposal is accepted.
    // This proves the score path does not reject it, so any rejection below is the gate.
    let controlStore = InMemoryCoreAgentSkillStore()
    try await controlStore.save(Self.skill(id: "proof-gate", body: "Use XCTest."))
    let controlReport = try await CoreAgentSkillSleepOptimizer(store: controlStore).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "proof-gate-off",
        proposals: [makeProposal(id: "unproven", validation: improvingValidationWithoutProof)],
        policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: false)
      )
    )
    #expect(controlReport.acceptedCount == 1)
    #expect(controlReport.entries.map(\.decision) == [.accepted])
    let controlSkill = try #require(await controlStore.currentSkill(id: "proof-gate"))
    #expect(controlSkill.version == 2)
    #expect(controlSkill.body == "Use Swift Testing.")

    // Gate ON, no proof: the identical improving proposal must fail closed.
    let rejectingStore = InMemoryCoreAgentSkillStore()
    try await rejectingStore.save(Self.skill(id: "proof-gate", body: "Use XCTest."))
    let rejectingReport = try await CoreAgentSkillSleepOptimizer(store: rejectingStore).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "proof-gate-on-missing",
        proposals: [makeProposal(id: "unproven", validation: improvingValidationWithoutProof)],
        policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true)
      )
    )
    #expect(rejectingReport.acceptedCount == 0)
    #expect(rejectingReport.entries.map(\.decision) == [.rejected(.validationDidNotImprove)])
    let rejectingSkill = try #require(await rejectingStore.currentSkill(id: "proof-gate"))
    #expect(rejectingSkill.version == 1)
    #expect(rejectingSkill.body == "Use XCTest.")

    // Gate ON, valid proof: the improving proposal is accepted, proving the gate admits
    // a well-formed held-out proof rather than rejecting unconditionally.
    let acceptingStore = InMemoryCoreAgentSkillStore()
    try await acceptingStore.save(Self.skill(id: "proof-gate", body: "Use XCTest."))
    let provenValidation = CoreAgentSkillValidationResult(
      score: 0.90,
      heldoutSuiteID: "heldout-proof-gate",
      passed: true,
      notes: "improves score with a well-formed held-out proof",
      heldoutProof: CoreAgentSkillHeldoutValidationProof(
        heldoutSuiteID: "heldout-proof-gate",
        evidenceIDs: ["evidence-proof-gate"],
        score: 0.90,
        passed: true,
        validatorID: "rlm-proof-gate",
        proofDigest: Self.digest(0xBEEF)
      )
    )
    let acceptingReport = try await CoreAgentSkillSleepOptimizer(store: acceptingStore).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "proof-gate-on-proven",
        proposals: [makeProposal(id: "proven", validation: provenValidation)],
        policy: CoreAgentSkillOptimizationPolicy(requiresHeldoutValidationProof: true)
      )
    )
    #expect(acceptingReport.acceptedCount == 1)
    #expect(acceptingReport.entries.map(\.decision) == [.accepted])
    let acceptingSkill = try #require(await acceptingStore.currentSkill(id: "proof-gate"))
    #expect(acceptingSkill.version == 2)
    #expect(acceptingSkill.body == "Use Swift Testing.")
  }
}
