import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
  @Test("Model proposal generator sanitizes evidence and feeds sleep optimizer proposals")
  func modelProposalGeneratorSanitizesEvidenceAndFeedsSleepOptimizerProposals() async throws {
    let skill = CoreAgentSkill(
      id: CoreAgentSkillID("swift"),
      version: 1,
      title: "swift",
      body: "Use XCTest for all new tests.",
      tags: ["swift"],
      provenance: [
        CoreAgentSkillProvenance(
          heldoutSuiteID: "old-heldout",
          validationScore: 0.4,
          notes: "old provenance with proposal-secret"
        )
      ]
    )
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "replay-evidence-auth",
      taskID: "task-auth",
      transcriptDigest: Self.digest(1_000),
      toolEventDigest: Self.digest(1_001),
      verifierFeedback: "backend-visible prose must not include proposal-secret",
      score: 0.4,
      metadata: [
        "source": "coreagent-engine",
        "suite_id": "train",
        "run_status": "failed",
        "raw_prompt": "proposal-secret prompt text",
      ]
    )
    let backend = CapturingModelProposalBackend(candidates: [
      CoreAgentSkillModelProposalCandidate(
        id: "proposal-a",
        skillID: skill.id,
        baselineScore: 0.40,
        candidateEdits: [
          .replace(
            target: "Use XCTest for all new tests.",
            replacement: "Use Swift Testing with typed assertions for all new tests."
          )
        ],
        validation: CoreAgentSkillValidationResult(
          score: 0.72,
          heldoutSuiteID: "heldout-swift",
          passed: true,
          notes: "raw model notes with proposal-secret"
        ),
        evidenceIDs: ["replay-evidence-auth"]
      )
    ])
    let generator = CoreAgentSkillModelProposalGenerator(backend: backend)

    let proposals = try await generator.generate(
      runID: "sleep-run-1",
      skill: skill,
      baselineScore: 0.40,
      evidence: [evidence],
      policy: CoreAgentSkillOptimizationPolicy(trainingSuiteIDs: ["train"]),
      maxProposals: 2
    )
    let request = try #require(await backend.lastRequest)
    let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""

    #expect(proposals.count == 1)
    #expect(proposals.first?.id == "proposal-a")
    #expect(proposals.first?.evidence.map(\.id) == ["replay-evidence-auth"])
    #expect(proposals.first?.evidence.first?.verifierFeedback == "proposal evidence reference")
    #expect(proposals.first?.evidence.first?.metadata["source"] == "coreagent-engine")
    #expect(proposals.first?.evidence.first?.metadata["run_status"] == "failed")
    #expect(proposals.first?.evidence.first?.metadata["raw_prompt"] == nil)
    #expect(proposals.first?.proposal.validation.notes == "model proposal proposal-a validation")
    #expect(!requestJSON.contains("proposal-secret"))
    #expect(!requestJSON.contains("raw_prompt"))
    #expect(request.skill.provenance.isEmpty)

    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let report = try await CoreAgentSkillSleepOptimizer(store: store).run(
      CoreAgentSkillSleepOptimizationRequest(
        runID: "sleep-run-1",
        proposals: proposals,
        policy: CoreAgentSkillOptimizationPolicy(trainingSuiteIDs: ["train"])
      )
    )
    let current = try #require(await store.currentSkill(id: skill.id))

    #expect(report.acceptedCount == 1)
    #expect(current.version == 2)
    #expect(current.body == "Use Swift Testing with typed assertions for all new tests.")
  }

  @Test("Model proposal generator validates backend candidates fail closed")
  func modelProposalGeneratorValidatesBackendCandidatesFailClosed() async throws {
    let skill = Self.skill(id: "swift", body: "Use XCTest.")
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "replay-evidence-swift",
      taskID: "task-swift",
      transcriptDigest: Self.digest(1_010),
      toolEventDigest: Self.digest(1_011),
      verifierFeedback: "safe",
      score: 0.5,
      metadata: ["suite_id": "train"]
    )
    let countingBackend = CountingModelProposalBackend()
    let generator = CoreAgentSkillModelProposalGenerator(backend: countingBackend)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal maxProposals must be positive"
      )
    ) {
      _ = try await generator.generate(
        runID: "sleep-run-1",
        skill: skill,
        baselineScore: 0.5,
        evidence: [evidence],
        maxProposals: 0
      )
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence digests must be sha256"
      )
    ) {
      _ = try await generator.generate(
        runID: "sleep-run-1",
        skill: skill,
        baselineScore: 0.5,
        evidence: [
          CoreAgentSkillRolloutEvidence(
            id: "bad-evidence",
            taskID: "task-swift",
            transcriptDigest: "sha256:\(String(repeating: "Z", count: 64))",
            toolEventDigest: Self.digest(1_012),
            verifierFeedback: "safe",
            score: 0.5
          )
        ]
      )
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditsPerProposal must be positive"
      )
    ) {
      _ = try await generator.generate(
        runID: "sleep-run-1",
        skill: skill,
        baselineScore: 0.5,
        evidence: [evidence],
        policy: CoreAgentSkillOptimizationPolicy(maxEditsPerProposal: 0)
      )
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence IDs must be unique"
      )
    ) {
      _ = try await generator.generate(
        runID: "sleep-run-1",
        skill: skill,
        baselineScore: 0.5,
        evidence: [evidence, evidence]
      )
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal backend exceeded maxProposals"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal-a", skillID: skill.id),
          Self.modelProposalCandidate(id: "proposal-b", skillID: skill.id),
        ])
      ).generate(
        runID: "sleep-run-1",
        skill: skill,
        baselineScore: 0.5,
        evidence: [evidence],
        maxProposals: 1
      )
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal candidate ID is invalid"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal a", skillID: skill.id)
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal candidate ID is invalid"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "../proposal-a", skillID: skill.id)
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.duplicateOptimizationProposal(
        "proposal-a"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal-a", skillID: skill.id),
          Self.modelProposalCandidate(id: "proposal-a", skillID: skill.id),
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal candidate skill must match request skill"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal-a", skillID: CoreAgentSkillID("other"))
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(
            id: "proposal-a",
            skillID: skill.id,
            validation: CoreAgentSkillValidationResult(
              score: 0.7,
              heldoutSuiteID: " ",
              passed: true,
              notes: "candidate"
            )
          )
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence IDs must reference supplied evidence"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(
            id: "proposal-a",
            skillID: skill.id,
            evidenceIDs: ["unknown-evidence"]
          )
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence IDs must reference supplied evidence"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal-a", skillID: skill.id, evidenceIDs: [])
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal candidate evidence IDs must be unique"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(
            id: "proposal-a",
            skillID: skill.id,
            evidenceIDs: ["replay-evidence-swift", "replay-evidence-swift"]
          )
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal candidate edits must be non-empty"
      )
    ) {
      _ = try await CoreAgentSkillModelProposalGenerator(
        backend: CapturingModelProposalBackend(candidates: [
          Self.modelProposalCandidate(id: "proposal-a", skillID: skill.id, edits: [])
        ])
      ).generate(runID: "sleep-run-1", skill: skill, baselineScore: 0.5, evidence: [evidence])
    }
  }

  @Test("FoundationModels proposal backend generates typed SkillOpt candidates")
  func foundationModelsProposalBackendGeneratesTypedSkillOptCandidates() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(
        text: """
          {
            "proposals": [
              {
                "id": "proposal-fm-1",
                "skillID": "swift",
                "baselineScore": 0.4,
                "edits": [
                  {
                    "operation": "replace",
                    "target": "Use XCTest for all new tests.",
                    "replacement": "Use Swift Testing with typed assertions for all new tests.",
                    "appendText": ""
                  }
                ],
                "validationScore": 0.76,
                "validationHeldoutSuiteID": "heldout-swift",
                "validationPassed": true,
                "validationNotes": "raw model notes should not become stored validation prose",
                "evidenceIDs": ["evidence-typed"]
              }
            ]
          }
          """)
    ])
    let session = try CoreAgentSession(model: model)
    let backend = CoreAgentSkillFoundationModelsProposalBackend(session: session)
    let generator = CoreAgentSkillModelProposalGenerator(backend: backend)
    let skill = CoreAgentSkill(
      id: CoreAgentSkillID("swift"),
      version: 3,
      title: "Swift testing skill",
      body: "Use XCTest for all new tests.",
      tags: ["swift"],
      provenance: [
        CoreAgentSkillProvenance(
          heldoutSuiteID: "old-heldout",
          validationScore: 0.5,
          notes: "foundation-secret provenance"
        )
      ]
    )
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "evidence-typed",
      taskID: "task-typed",
      transcriptDigest: Self.digest(1_100),
      toolEventDigest: Self.digest(1_101),
      verifierFeedback: "foundation-secret verifier feedback",
      score: 0.4,
      metadata: [
        "source": "coreagent-engine",
        "run_status": "failed",
        "raw_prompt": "foundation-secret raw prompt",
      ]
    )

    let proposals = try await generator.generate(
      runID: "foundation-run-1",
      skill: skill,
      baselineScore: 0.4,
      evidence: [evidence],
      maxProposals: 2
    )

    let proposal = try #require(proposals.first)
    #expect(proposals.count == 1)
    #expect(proposal.id == "proposal-fm-1")
    #expect(proposal.proposal.skillID == skill.id)
    #expect(
      proposal.proposal.candidateEdits == [
        .replace(
          target: "Use XCTest for all new tests.",
          replacement: "Use Swift Testing with typed assertions for all new tests."
        )
      ])
    #expect(proposal.proposal.validation.score == 0.76)
    #expect(proposal.proposal.validation.heldoutSuiteID == "heldout-swift")
    #expect(proposal.proposal.validation.notes == "model proposal proposal-fm-1 validation")
    #expect(proposal.evidence.map(\.id) == ["evidence-typed"])
    #expect(proposal.evidence.first?.verifierFeedback == "proposal evidence reference")

    let transcript = try #require(model.recorder.capturedTranscripts().first)
    #expect(transcript.containsText("foundation-run-1"))
    #expect(transcript.containsText("Use XCTest for all new tests."))
    #expect(transcript.containsText("evidence-typed"))
    #expect(transcript.containsText("replace"))
    #expect(transcript.containsText("append"))
    #expect(!transcript.containsText("foundation-secret"))
    #expect(!transcript.containsText("raw_prompt"))
  }

  @Test("FoundationModels proposal backend rejects unsupported model edit operations")
  func foundationModelsProposalBackendRejectsUnsupportedModelEditOperations() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(
        text: """
          {
            "proposals": [
              {
                "id": "proposal-fm-1",
                "skillID": "swift",
                "baselineScore": 0.4,
                "edits": [
                  {
                    "operation": "delete",
                    "target": "Use XCTest.",
                    "replacement": "",
                    "appendText": ""
                  }
                ],
                "validationScore": 0.76,
                "validationHeldoutSuiteID": "heldout-swift",
                "validationPassed": true,
                "validationNotes": "candidate",
                "evidenceIDs": ["evidence-typed"]
              }
            ]
          }
          """)
    ])
    let session = try CoreAgentSession(model: model)
    let backend = CoreAgentSkillFoundationModelsProposalBackend(session: session)
    let request = CoreAgentSkillModelProposalRequest(
      runID: "foundation-run-1",
      skill: Self.skill(id: "swift", body: "Use XCTest."),
      baselineScore: 0.4,
      evidence: [
        CoreAgentSkillModelProposalEvidenceReference(
          id: "evidence-typed",
          taskID: "task-typed",
          transcriptDigest: Self.digest(1_120),
          toolEventDigest: Self.digest(1_121),
          score: 0.4,
          metadata: ["source": "coreagent-engine"]
        )
      ],
      maxProposals: 1
    )

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "model proposal edit operation is unsupported"
      )
    ) {
      _ = try await backend.generate(request)
    }
  }

}
