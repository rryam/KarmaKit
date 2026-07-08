import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
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

  @Test("Multi-objective harness optimizer ranks eligible candidates deterministically")
  func multiObjectiveHarnessOptimizerRanksEligibleCandidatesDeterministically() throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let result = try optimizer.selectBest(
      candidates: [
        CoreAgentHarnessCandidate(id: "large", parameters: ["model": "frontier"]),
        CoreAgentHarnessCandidate(id: "small", parameters: ["model": "local"]),
        CoreAgentHarnessCandidate(id: "fast", parameters: ["model": "tiny"]),
      ],
      objectiveEvaluations: [
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "large",
          heldoutSuiteID: "heldout-a",
          objectiveID: "quality",
          score: 0.95
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "large",
          heldoutSuiteID: "heldout-a",
          objectiveID: "latency",
          score: 0.60
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "small",
          heldoutSuiteID: "heldout-a",
          objectiveID: "quality",
          score: 0.85
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "small",
          heldoutSuiteID: "heldout-a",
          objectiveID: "latency",
          score: 0.20
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "fast",
          heldoutSuiteID: "heldout-a",
          objectiveID: "quality",
          score: 0.78
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "fast",
          heldoutSuiteID: "heldout-a",
          objectiveID: "latency",
          score: 0.05
        ),
      ],
      objectives: [
        CoreAgentHarnessObjective(
          id: "quality",
          weight: 0.70,
          direction: .maximize,
          requiredMeanScore: 0.80
        ),
        CoreAgentHarnessObjective(
          id: "latency",
          weight: 0.30,
          direction: .minimize
        ),
      ]
    )

    #expect(result.best.id == "small")
    #expect(result.heldoutSuiteIDs == ["heldout-a"])
    #expect(result.objectives.map(\.id.rawValue) == ["quality", "latency"])
    #expect(result.auditTrail.map(\.candidateID) == ["small", "large", "fast"])
    #expect(result.auditTrail.map(\.eligible) == [true, true, false])
    #expect(abs(result.auditTrail[0].weightedScore - 0.835) < 0.000001)
    #expect(result.auditTrail[0].objectiveScores.map(\.objectiveID) == ["quality", "latency"])
    #expect(
      result.auditTrail[0].objectiveScores.map(\.heldoutSuiteIDs) == [
        ["heldout-a"],
        ["heldout-a"],
      ])
    #expect(result.auditTrail[2].objectiveScores[0].passedRequiredMean == false)
  }

  @Test("Multi-objective harness optimizer rejects ambiguous or ineligible inputs")
  func multiObjectiveHarnessOptimizerRejectsAmbiguousOrIneligibleInputs() throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let candidate = CoreAgentHarnessCandidate(id: "proposal-a", parameters: [:])
    let objective = CoreAgentHarnessObjective(
      id: "quality",
      weight: 1,
      direction: .maximize,
      requiredMeanScore: 0.95
    )
    let evaluation = CoreAgentHarnessObjectiveEvaluation(
      candidateID: candidate.id,
      heldoutSuiteID: "heldout-a",
      objectiveID: objective.id,
      score: 0.90
    )

    #expect(CoreAgentHarnessObjectiveID("quality").rawValue == "quality")
    #expect(
      throws: CoreAgentSkillOptimizationError.duplicateHarnessObjectiveEvaluation(
        "proposal-a:heldout-a:quality"
      )
    ) {
      _ = try optimizer.selectBest(
        candidates: [candidate],
        objectiveEvaluations: [evaluation, evaluation],
        objectives: [objective]
      )
    }
    #expect(throws: CoreAgentSkillOptimizationError.noEligibleHarnessCandidate) {
      _ = try optimizer.selectBest(
        candidates: [candidate],
        objectiveEvaluations: [evaluation],
        objectives: [objective]
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "objective id must be non-empty"
      )
    ) {
      _ = try optimizer.selectBest(
        candidates: [candidate],
        objectiveEvaluations: [
          CoreAgentHarnessObjectiveEvaluation(
            candidateID: candidate.id,
            heldoutSuiteID: "heldout-a",
            objectiveID: "",
            score: 0.90
          )
        ],
        objectives: [CoreAgentHarnessObjective(id: "")]
      )
    }
    #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try optimizer.selectBest(
        candidates: [candidate],
        objectiveEvaluations: [
          CoreAgentHarnessObjectiveEvaluation(
            candidateID: candidate.id,
            heldoutSuiteID: " ",
            objectiveID: objective.id,
            score: 0.90
          )
        ],
        objectives: [CoreAgentHarnessObjective(id: objective.id)]
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "required objective mean score must be between 0 and 1"
      )
    ) {
      _ = try optimizer.selectBest(
        candidates: [candidate],
        objectiveEvaluations: [evaluation],
        objectives: [CoreAgentHarnessObjective(id: objective.id, requiredMeanScore: 1.5)]
      )
    }
  }

  @Test("Multi-objective minimize required scores use normalized values")
  func multiObjectiveMinimizeRequiredScoresUseNormalizedValues() throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let result = try optimizer.selectBest(
      candidates: [
        CoreAgentHarnessCandidate(id: "fast", parameters: [:]),
        CoreAgentHarnessCandidate(id: "slow", parameters: [:]),
      ],
      objectiveEvaluations: [
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "fast",
          heldoutSuiteID: "heldout-a",
          objectiveID: "latency",
          score: 0.10
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "slow",
          heldoutSuiteID: "heldout-a",
          objectiveID: "latency",
          score: 0.30
        ),
      ],
      objectives: [
        CoreAgentHarnessObjective(
          id: "latency",
          direction: .minimize,
          requiredMeanScore: 0.80
        )
      ]
    )

    #expect(result.best.id == "fast")
    #expect(abs(result.auditTrail[0].objectiveScores[0].normalizedMeanScore - 0.90) < 0.000001)
    #expect(result.auditTrail.map(\.eligible) == [true, false])
  }

  @Test("Multi-objective duplicate detection does not collide on delimiter characters")
  func multiObjectiveDuplicateDetectionDoesNotCollideOnDelimiterCharacters() throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let result = try optimizer.selectBest(
      candidates: [
        CoreAgentHarnessCandidate(id: "a:b", parameters: [:]),
        CoreAgentHarnessCandidate(id: "a", parameters: [:]),
      ],
      objectiveEvaluations: [
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "a:b",
          heldoutSuiteID: "c",
          objectiveID: "d",
          score: 0.90
        ),
        CoreAgentHarnessObjectiveEvaluation(
          candidateID: "a",
          heldoutSuiteID: "b:c",
          objectiveID: "d",
          score: 0.80
        ),
      ],
      objectives: [CoreAgentHarnessObjective(id: "d")]
    )

    #expect(result.best.id == "a:b")
    #expect(result.auditTrail.map(\.candidateID) == ["a:b", "a"])
  }

  @Test("Multi-objective evaluator adapter fails closed and returns scalar validation")
  func multiObjectiveEvaluatorAdapterFailsClosedAndReturnsScalarValidation() throws {
    let adapter = CoreAgentSkillMultiObjectiveValidationAdapter()
    let objectives = [
      CoreAgentHarnessObjective(id: "quality", weight: 2, direction: .maximize),
      CoreAgentHarnessObjective(id: "cost", weight: 1, direction: .minimize),
    ]
    let evaluations = [
      CoreAgentHarnessObjectiveEvaluation(
        candidateID: "proposal-a",
        heldoutSuiteID: "heldout-eval",
        objectiveID: "quality",
        score: 0.90
      ),
      CoreAgentHarnessObjectiveEvaluation(
        candidateID: "proposal-a",
        heldoutSuiteID: "heldout-eval",
        objectiveID: "cost",
        score: 0.30
      ),
    ]

    let validation = try adapter.validationResult(
      candidateID: "proposal-a",
      evaluations: evaluations,
      objectives: objectives,
      heldoutSuiteID: "heldout-eval",
      passingScore: 0.80,
      notes: "weighted quality/cost"
    )

    #expect(abs(validation.score - 0.8333333333333334) < 0.000001)
    #expect(validation.passed)
    #expect(validation.heldoutSuiteID == "heldout-eval")
    #expect(validation.notes == "weighted quality/cost")
    #expect(throws: CoreAgentSkillOptimizationError.duplicateHarnessObjective("quality")) {
      _ = try adapter.validationResult(
        candidateID: "proposal-a",
        evaluations: evaluations,
        objectives: [
          CoreAgentHarnessObjective(id: "quality"),
          CoreAgentHarnessObjective(id: "quality"),
        ],
        heldoutSuiteID: "heldout-eval"
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "objective weight must be finite and positive"
      )
    ) {
      _ = try adapter.validationResult(
        candidateID: "proposal-a",
        evaluations: evaluations,
        objectives: [CoreAgentHarnessObjective(id: "quality", weight: 0)],
        heldoutSuiteID: "heldout-eval"
      )
    }
    #expect(throws: CoreAgentSkillOptimizationError.invalidValidationScore(1.5)) {
      _ = try adapter.validationResult(
        candidateID: "proposal-a",
        evaluations: [
          CoreAgentHarnessObjectiveEvaluation(
            candidateID: "proposal-a",
            heldoutSuiteID: "heldout-eval",
            objectiveID: "quality",
            score: 1.5
          )
        ],
        objectives: [CoreAgentHarnessObjective(id: "quality")],
        heldoutSuiteID: "heldout-eval"
      )
    }
    #expect(throws: CoreAgentSkillOptimizationError.missingHarnessEvaluation("proposal-a:cost")) {
      _ = try adapter.validationResult(
        candidateID: "proposal-a",
        evaluations: [evaluations[0]],
        objectives: objectives,
        heldoutSuiteID: "heldout-eval"
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "adapter heldoutSuiteID must match objective evaluation suites"
      )
    ) {
      _ = try adapter.validationResult(
        candidateID: "proposal-a",
        evaluations: evaluations,
        objectives: objectives,
        heldoutSuiteID: "heldout-other"
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
    #expect(
      report.entries.map(\.proposalID) == [
        "too-many-edits",
        "split-leak",
        "slow-region-edit",
        "accepted",
      ])
    #expect(
      report.entries.map(\.decision) == [
        .rejected(.editBudgetExceeded),
        .rejected(.heldoutSplitLeakage),
        .rejected(.protectedRegionMutation),
        .accepted,
      ])
    #expect(report.entries.last?.evidenceIDs == ["trace-a"])
    #expect(memory.rejectedEdits.count == 3)
    #expect(
      memory.metaObservations.map(\.proposalID) == [
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

    await #expect(
      throws: CoreAgentSkillOptimizationError.duplicateOptimizationProposal("duplicate")
    ) {
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

  @Test("Sleep optimizer preflights invalid validation scores before mutating skills")
  func sleepOptimizerPreflightsInvalidValidationScoresBeforeMutatingSkills() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let sleepOptimizer = CoreAgentSkillSleepOptimizer(store: store)

    await #expect(throws: CoreAgentSkillOptimizationError.invalidValidationScore(2.0)) {
      _ = try await sleepOptimizer.run(
        CoreAgentSkillSleepOptimizationRequest(
          runID: "sleep-epoch-invalid-score",
          proposals: [
            CoreAgentSkillSleepOptimizationProposal(
              id: "valid-first",
              proposal: CoreAgentSkillOptimizationProposal(
                skillID: base.id,
                baselineScore: 0.70,
                candidateEdits: [
                  .replace(target: "Use XCTest.", replacement: "Use Swift Testing.")
                ],
                validation: Self.validation(score: 0.90)
              )
            ),
            CoreAgentSkillSleepOptimizationProposal(
              id: "invalid-second",
              proposal: CoreAgentSkillOptimizationProposal(
                skillID: base.id,
                baselineScore: 0.70,
                candidateEdits: [.append("\nPrefer typed assertions.")],
                validation: Self.validation(score: 2.0)
              )
            ),
          ],
          policy: CoreAgentSkillOptimizationPolicy(maxAcceptedProposalsPerRun: 2)
        )
      )
    }
    let current = try #require(await store.currentSkill(id: base.id))
    #expect(current.version == 1)
    #expect(current.body == "Use XCTest.")
  }

  @Test("Sleep optimizer preflights invalid edits before mutating skills")
  func sleepOptimizerPreflightsInvalidEditsBeforeMutatingSkills() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let sleepOptimizer = CoreAgentSkillSleepOptimizer(store: store)

    await #expect(throws: CoreAgentSkillOptimizationError.emptyReplacementTarget) {
      _ = try await sleepOptimizer.run(
        CoreAgentSkillSleepOptimizationRequest(
          runID: "sleep-epoch-invalid-edit",
          proposals: [
            CoreAgentSkillSleepOptimizationProposal(
              id: "valid-first",
              proposal: CoreAgentSkillOptimizationProposal(
                skillID: base.id,
                baselineScore: 0.70,
                candidateEdits: [
                  .replace(target: "Use XCTest.", replacement: "Use Swift Testing.")
                ],
                validation: Self.validation(score: 0.90)
              )
            ),
            CoreAgentSkillSleepOptimizationProposal(
              id: "invalid-second",
              proposal: CoreAgentSkillOptimizationProposal(
                skillID: base.id,
                baselineScore: 0.70,
                candidateEdits: [.replace(target: "   ", replacement: "Never reached.")],
                validation: Self.validation(score: 0.91)
              )
            ),
          ],
          policy: CoreAgentSkillOptimizationPolicy(maxAcceptedProposalsPerRun: 2)
        )
      )
    }
    let current = try #require(await store.currentSkill(id: base.id))
    #expect(current.version == 1)
    #expect(current.body == "Use XCTest.")
  }

}
