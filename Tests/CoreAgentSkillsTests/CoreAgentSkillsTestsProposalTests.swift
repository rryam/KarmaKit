import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
  @Test("Optimization run orchestrator wires harvest replay proposal and sleep phases")
  func optimizationRunOrchestratorWiresHarvestReplayProposalAndSleepPhases() async throws {
    let skill = Self.skill(id: "swift", body: "Use XCTest for all new tests.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)

    let runID = Self.uuid(801)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(runID: runID, kind: .runFailed, message: "failed")
      ]
    )
    let engineStore = StaticEngineStore(traces: [
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: "thread-a",
        run: run,
        receipt: try CoreAgentRunReceipt(run: run)
      )
    ])
    let harvested = try #require(
      await CoreAgentSkillEngineTraceHarvester(engineStore: engineStore)
        .harvest(projectID: "coreagent", threadID: "thread-a")
        .first
    )
    let replayPolicy = CoreAgentSkillReplayGenerationPolicy(
      heldoutSuiteID: "heldout-replay",
      includeDreamRolloutsForFailures: true,
      maxRequests: 2
    )
    let replayRequests = try CoreAgentSkillReplayGenerator().generate(
      from: [harvested],
      policy: replayPolicy
    )
    #expect(replayRequests.count == 2)
    let replayBackend = StaticReplayBackend(
      outcomes: Dictionary(
        uniqueKeysWithValues: replayRequests.enumerated().map { index, request in
          (
            request.id,
            CoreAgentSkillReplayOutcome(
              requestID: request.id,
              transcriptDigest: Self.digest(802 + index),
              toolEventDigest: Self.digest(803 + index),
              verifierFeedback: "replay completed",
              score: 0.45
            )
          )
        }
      )
    )
    let proposalBackend = CapturingModelProposalBackend(candidates: [
      Self.modelProposalCandidate(
        id: "orchestrator-proposal",
        skillID: skill.id,
        baselineScore: 0.40,
        edits: [
          .replace(
            target: "Use XCTest for all new tests.",
            replacement: "Use Swift Testing with typed assertions for all new tests."
          )
        ],
        validation: CoreAgentSkillValidationResult(
          score: 0.72,
          heldoutSuiteID: "heldout-swift",
          passed: true,
          notes: "orchestrator validation"
        ),
        evidenceIDs: [harvested.id]
      )
    ])

    let report = try await CoreAgentSkillOptimizationRunExecutor(
      store: store,
      engineStore: engineStore
    ).run(
      CoreAgentSkillOptimizationRunRequest(
        runID: "optimization-run-1",
        policy: CoreAgentSkillOptimizationPolicy(),
        harvest: CoreAgentSkillOptimizationRunHarvestConfig(
          projectID: "coreagent",
          threadID: "thread-a"
        ),
        replay: CoreAgentSkillOptimizationRunReplayConfig(
          generationPolicy: CoreAgentSkillReplayGenerationPolicy(
            heldoutSuiteID: "heldout-replay",
            includeDreamRolloutsForFailures: true,
            maxRequests: 2
          ),
          backend: replayBackend
        ),
        proposal: CoreAgentSkillOptimizationRunProposalConfig(
          backend: proposalBackend,
          maxProposals: 1
        ),
        targets: [
          CoreAgentSkillOptimizationRunTarget(skillID: skill.id, baselineScore: 0.40)
        ]
      )
    )
    let current = try #require(await store.currentSkill(id: skill.id))

    #expect(report.runID == "optimization-run-1")
    #expect(report.harvestedEvidenceIDs == [harvested.id])
    #expect(report.replayRequestIDs.count == 2)
    #expect(report.replayEvidenceIDs.count == 2)
    #expect(report.generatedProposalIDs == ["orchestrator-proposal"])
    #expect(
      report.phases.map(\.phase) == [
        .harvested,
        .replayGenerated,
        .replayExecuted,
        .proposalsGenerated,
        .sleepOptimized,
      ])
    #expect(report.sleepReport?.acceptedCount == 1)
    #expect(current.version == 2)
    #expect(current.body == "Use Swift Testing with typed assertions for all new tests.")
    #expect(report.uniqueEvidenceCount >= 2)
  }

  @Test("Optimization run orchestrator rejects harvest config without engine store")
  func optimizationRunOrchestratorRejectsHarvestConfigWithoutEngineStore() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let executor = CoreAgentSkillOptimizationRunExecutor(store: store)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "harvest config requires engineStore on executor"
      )
    ) {
      _ = try await executor.run(
        CoreAgentSkillOptimizationRunRequest(
          runID: "optimization-run-2",
          harvest: CoreAgentSkillOptimizationRunHarvestConfig(projectID: "coreagent")
        )
      )
    }
  }

  @Test("Optimization run orchestrator rejects proposal generation without targets")
  func optimizationRunOrchestratorRejectsProposalGenerationWithoutTargets() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let executor = CoreAgentSkillOptimizationRunExecutor(store: store)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal generation requires at least one optimization target"
      )
    ) {
      _ = try await executor.run(
        CoreAgentSkillOptimizationRunRequest(
          runID: "optimization-run-3",
          proposal: CoreAgentSkillOptimizationRunProposalConfig(
            backend: CapturingModelProposalBackend(candidates: [])
          )
        )
      )
    }
  }

  @Test("Optimization run fails closed when harvest exceeds token budget")
  func optimizationRunFailsClosedWhenHarvestExceedsTokenBudget() async throws {
    let skill = Self.skill(id: "swift-budget", body: "Use XCTest.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let runID = Self.uuid(840)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(runID: runID, kind: .runCompleted, message: "completed")
      ]
    )
    let engineStore = StaticEngineStore(traces: [
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: "thread-budget",
        run: run,
        receipt: try CoreAgentRunReceipt(run: run)
      )
    ])
    let proposalBackend = CountingModelProposalBackend()

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "harvested Engine trace token usage 15 exceeds maximumTotalTokens 1"
      )
    ) {
      _ = try await CoreAgentSkillOptimizationRunExecutor(
        store: store,
        engineStore: engineStore
      ).run(
        CoreAgentSkillOptimizationRunRequest(
          runID: "optimization-run-budget",
          harvest: CoreAgentSkillOptimizationRunHarvestConfig(
            projectID: "coreagent",
            threadID: "thread-budget",
            maximumTotalTokens: 1
          ),
          proposal: CoreAgentSkillOptimizationRunProposalConfig(
            backend: proposalBackend,
            maxProposals: 1
          ),
          targets: [
            CoreAgentSkillOptimizationRunTarget(skillID: skill.id, baselineScore: 0.5)
          ],
          suppliedProposals: [
            Self.sleepProposal(
              id: "budget-mutation",
              skillID: skill.id,
              score: 0.9,
              replacement: "Use Swift Testing."
            )
          ]
        )
      )
    }

    let current = try #require(await store.currentSkill(id: skill.id))
    #expect(current.version == 1)
    #expect(current.body == "Use XCTest.")
    #expect(await proposalBackend.callCount == 0)
  }

  @Test("Optimization run does not persist meta-skill snapshot when harvest exceeds token budget")
  func optimizationRunDoesNotPersistMetaSkillSnapshotWhenHarvestExceedsBudget() async throws {
    let skill = Self.skill(id: "swift-budget-meta", body: "Use XCTest.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let runID = Self.uuid(841)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(runID: runID, kind: .runCompleted, message: "completed")
      ]
    )
    let engineStore = StaticEngineStore(traces: [
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: "thread-budget-meta",
        run: run,
        receipt: try CoreAgentRunReceipt(run: run)
      )
    ])
    let snapshot = Self.metaSkillSnapshot(branchID: "branch-budget", epoch: 4)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "harvested Engine trace token usage 15 exceeds maximumTotalTokens 1"
      )
    ) {
      _ = try await CoreAgentSkillOptimizationRunExecutor(
        store: store,
        engineStore: engineStore
      ).run(
        CoreAgentSkillOptimizationRunRequest(
          runID: "optimization-run-budget-meta",
          harvest: CoreAgentSkillOptimizationRunHarvestConfig(
            projectID: "coreagent",
            threadID: "thread-budget-meta",
            maximumTotalTokens: 1
          ),
          metaSkill: CoreAgentSkillMetaSkillRunConfig(
            skillID: skill.id,
            snapshot: snapshot,
            previousEpoch: 3
          )
        )
      )
    }

    // Fail-closed: the token-budget gate runs before `recordMetaSkillSnapshot`, so a
    // rejected run must leave no meta-skill branch bookkeeping behind.
    let memory = await store.optimizerMemory(skillID: skill.id)
    #expect(memory.metaSkillSnapshots.isEmpty)
    #expect(memory.metaSkillEvolutionRecords.isEmpty)
  }

  @Test("Cross-run scheduler plan is deterministic and host triggered")
  func crossRunSchedulerPlanIsDeterministicAndHostTriggered() throws {
    let swiftSkillID = CoreAgentSkillID("swift-scheduler")
    let otherSkillID = CoreAgentSkillID("other-scheduler")
    let plan = CoreAgentSkillOptimizationCrossRunSchedulerPlan(
      policy: CoreAgentSkillOptimizationCrossRunSchedulerPolicy(
        maximumRequestsPerHostInvocation: 2,
        prioritizeRejectedSkillTargets: true
      ),
      backlog: [
        Self.optimizationRunRequest(runID: "carry-other", skillID: otherSkillID),
        Self.optimizationRunRequest(runID: "already-finished", skillID: swiftSkillID),
        CoreAgentSkillOptimizationRunRequest(runID: "carry-empty"),
        Self.optimizationRunRequest(runID: "carry-swift", skillID: swiftSkillID),
      ]
    )
    Self.requireSendable(plan)

    let priorReports = [
      Self.optimizationRunReport(runID: "prior-other"),
      Self.optimizationRunReport(
        runID: "prior-swift",
        sleepReport: CoreAgentSkillSleepOptimizationReport(
          runID: "prior-swift",
          entries: [
            CoreAgentSkillSleepOptimizationEntry(
              proposalID: "swift-rejected",
              skillID: swiftSkillID,
              decision: .rejected(.validationDidNotImprove),
              skillVersionBefore: 1,
              skillVersionAfter: nil,
              baselineScore: 0.5,
              validation: Self.validation(score: 0.4),
              evidenceIDs: ["evidence-swift"]
            )
          ]
        )
      ),
      Self.optimizationRunReport(runID: "already-finished"),
    ]

    let firstDecision = try plan.nextRequests(after: priorReports)
    let secondDecision = try plan.nextRequests(after: priorReports.reversed())

    #expect(plan.trigger == .hostInvoked)
    #expect(firstDecision.requests.map(\.runID) == ["carry-swift", "carry-other"])
    #expect(secondDecision.requests.map(\.runID) == firstDecision.requests.map(\.runID))
    #expect(firstDecision.carryOverRunIDs == ["carry-swift", "carry-other", "carry-empty"])
    #expect(firstDecision.completedRunIDs == ["already-finished", "prior-other", "prior-swift"])
    #expect(firstDecision.prioritizedSkillIDs == [swiftSkillID])
  }

  @Test("Optimization run orchestrator applies meta evolution frontier before sleep")
  func optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep() async throws {
    let skill = Self.skill(id: "swift", body: "Use XCTest.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)

    let report = try await CoreAgentSkillOptimizationRunExecutor(store: store).run(
      CoreAgentSkillOptimizationRunRequest(
        runID: "optimization-run-frontier",
        policy: CoreAgentSkillOptimizationPolicy(maxAcceptedProposalsPerRun: 1),
        frontier: CoreAgentSkillMetaEvolutionFrontierConfig(
          scores: [
            CoreAgentSkillMetaEvolutionFrontierScore(
              proposalID: "first-hacked",
              productivityScore: 0.95,
              noveltyScore: 0.95,
              strictScore: 0.25,
              looseScore: 0.95
            ),
            CoreAgentSkillMetaEvolutionFrontierScore(
              proposalID: "second-productive",
              productivityScore: 0.80,
              noveltyScore: 0.90,
              strictScore: 0.78,
              looseScore: 0.82
            ),
          ],
          policy: CoreAgentSkillMetaEvolutionFrontierPolicy(
            maxSelectedProposals: 1,
            maximumHackRatio: 2.0
          )
        ),
        suppliedProposals: [
          Self.sleepProposal(
            id: "first-hacked",
            replacement: "Use an unsafe shortcut."
          ),
          Self.sleepProposal(
            id: "second-productive",
            replacement: "Use Swift Testing."
          ),
        ]
      )
    )
    let current = try #require(await store.currentSkill(id: skill.id))

    #expect(report.frontierSelectedProposalIDs == ["second-productive"])
    #expect(report.frontierRejectedProposalIDs == ["first-hacked"])
    #expect(report.phases.map(\.phase) == [.frontierSelected, .sleepOptimized])
    #expect(report.sleepReport?.acceptedCount == 1)
    #expect(current.body == "Use Swift Testing.")
  }

  @Test("Optimization run records meta skill branch state around frontier and sleep")
  func optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep() async throws {
    let skill = Self.skill(id: "swift", body: "Use XCTest.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let snapshot = Self.metaSkillSnapshot(branchID: "branch-run", epoch: 4)

    let report = try await CoreAgentSkillOptimizationRunExecutor(store: store).run(
      CoreAgentSkillOptimizationRunRequest(
        runID: "optimization-run-meta-skill",
        policy: CoreAgentSkillOptimizationPolicy(maxAcceptedProposalsPerRun: 1),
        metaSkill: CoreAgentSkillMetaSkillRunConfig(
          skillID: skill.id,
          snapshot: snapshot,
          previousEpoch: 3
        ),
        frontier: CoreAgentSkillMetaEvolutionFrontierConfig(
          scores: [
            Self.frontierScore(
              proposalID: "first-hacked",
              productivityScore: 0.95,
              noveltyScore: 0.95,
              strictScore: 0.25,
              looseScore: 0.95
            ),
            Self.frontierScore(
              proposalID: "second-productive",
              productivityScore: 0.80,
              noveltyScore: 0.90,
              strictScore: 0.78,
              looseScore: 0.82
            ),
          ],
          policy: CoreAgentSkillMetaEvolutionFrontierPolicy(
            maxSelectedProposals: 1,
            maximumHackRatio: 2.0
          )
        ),
        suppliedProposals: [
          Self.sleepProposal(
            id: "first-hacked",
            replacement: "Use an unsafe shortcut."
          ),
          Self.sleepProposal(
            id: "second-productive",
            replacement: "Use Swift Testing."
          ),
        ]
      )
    )
    let memory = await store.optimizerMemory(skillID: skill.id)

    #expect(report.metaSkillBranchID == "branch-run")
    #expect(report.metaSkillEpoch == 4)
    #expect(report.metaSkillEvolutionRecordCount == 1)
    #expect(
      report.phases.map(\.phase) == [
        .metaSkillStateRecorded,
        .frontierSelected,
        .sleepOptimized,
        .metaSkillEvolved,
      ])
    #expect(memory.metaSkillSnapshots.map(\.branchID) == ["branch-run"])
    #expect(memory.metaSkillEvolutionRecords.first?.acceptedProposalIDs == ["second-productive"])
    #expect(memory.metaSkillEvolutionRecords.first?.rejectedProposalIDs == ["first-hacked"])
    #expect(memory.metaSkillEvolutionRecords.first?.frontierRejectedProposalIDs == ["first-hacked"])
    #expect(
      memory.metaSkillEvolutionRecords.first?.sleepAcceptedProposalIDs == ["second-productive"])
    #expect(memory.metaSkillEvolutionRecords.first?.sleepRejectedProposalIDs == [])
  }

  @Test("RSI memory importer records digest-bound optimizer memory without raw payloads")
  func rsiMemoryImporterRecordsDigestBoundOptimizerMemory() async throws {
    let skill = Self.skill(id: "rsi", body: "Always validate held-out suites.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)

    let reference = CoreAgentSkillRSIMemoryReference(
      id: "rqgm-node-1",
      source: .rqgm,
      contentDigest: Self.digest(901),
      metadata: ["memory_kind": "skill-evolution", "graph_digest": Self.digest(902)]
    )
    let report = try await CoreAgentSkillRSIMemoryImporter(store: store).importReferences(
      [reference],
      runID: "rsi-run-1",
      skillID: skill.id
    )
    let memory = await store.optimizerMemory(skillID: skill.id)

    #expect(report.importedEntryIDs == [reference.id])
    #expect(memory.metaObservations.count == 1)
    #expect(memory.metaObservations[0].reason == .externalMemoryImport)
    #expect(memory.metaObservations[0].notes.contains("content_digest=\(reference.contentDigest)"))
    #expect(!memory.metaObservations[0].notes.contains("Always validate"))
  }

  @Test("RSI memory importer rejects non-allowlisted metadata and duplicate entry IDs")
  func rsiMemoryImporterRejectsInvalidMetadataAndDuplicates() async throws {
    let skill = Self.skill(id: "rsi-meta", body: "Body")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let importer = CoreAgentSkillRSIMemoryImporter(store: store)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "RSI memory metadata key is not allowlisted"
      )
    ) {
      _ = try await importer.importReferences(
        [
          CoreAgentSkillRSIMemoryReference(
            id: "entry-1",
            source: .autoMem,
            contentDigest: Self.digest(903),
            metadata: ["raw_payload": "secret"]
          )
        ],
        runID: "rsi-run-2",
        skillID: skill.id
      )
    }

    let first = try await importer.importReferences(
      [
        CoreAgentSkillRSIMemoryReference(
          id: "entry-dup",
          source: .rqgm,
          contentDigest: Self.digest(904)
        )
      ],
      runID: "rsi-run-3",
      skillID: skill.id
    )
    let second = try await importer.importReferences(
      [
        CoreAgentSkillRSIMemoryReference(
          id: "entry-dup",
          source: .rqgm,
          contentDigest: Self.digest(905)
        )
      ],
      runID: "rsi-run-4",
      skillID: skill.id
    )

    #expect(first.importedEntryIDs == ["entry-dup"])
    #expect(second.importedEntryIDs.isEmpty)
    #expect(second.skippedDuplicateEntryIDs == ["entry-dup"])
  }

  @Test("Optimization run orchestrator imports RSI memory before proposal generation")
  func optimizationRunOrchestratorImportsRSIMemoryBeforeProposalGeneration() async throws {
    let skill = Self.skill(id: "rsi-run", body: "Use Swift Testing.")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "seed-rsi",
      taskID: "task-rsi",
      transcriptDigest: Self.digest(906),
      toolEventDigest: Self.digest(907),
      verifierFeedback: "seed",
      score: 0.8
    )
    let adapter = StaticRSIMemoryAdapter(references: [
      CoreAgentSkillRSIMemoryReference(
        id: "memory-node",
        source: .rqgm,
        contentDigest: Self.digest(908)
      )
    ])

    let report = try await CoreAgentSkillOptimizationRunExecutor(store: store).run(
      CoreAgentSkillOptimizationRunRequest(
        runID: "optimization-run-rsi",
        memory: CoreAgentSkillRSIMemoryImportConfig(
          adapter: adapter,
          skillID: skill.id
        ),
        seedEvidence: [evidence]
      )
    )

    #expect(report.importedMemoryEntryIDs == ["memory-node"])
    #expect(report.phases.map(\.phase) == [CoreAgentSkillOptimizationRunPhase.memoryImported])
    let memory = await store.optimizerMemory(skillID: skill.id)
    #expect(memory.metaObservations.count == 1)
  }

  @Test("Optimization run orchestrator dedupes duplicate seed evidence IDs")
  func optimizationRunOrchestratorDedupesDuplicateSeedEvidenceIDs() async throws {
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "seed-evidence-shared",
      taskID: "task-shared",
      transcriptDigest: Self.digest(811),
      toolEventDigest: Self.digest(812),
      verifierFeedback: "seed",
      score: 1,
      metadata: ["source": "seed"]
    )

    let report = try await CoreAgentSkillOptimizationRunExecutor(
      store: InMemoryCoreAgentSkillStore()
    ).run(
      CoreAgentSkillOptimizationRunRequest(
        runID: "optimization-run-4",
        seedEvidence: [
          evidence,
          CoreAgentSkillRolloutEvidence(
            id: evidence.id,
            taskID: "duplicate",
            transcriptDigest: Self.digest(813),
            toolEventDigest: Self.digest(814),
            verifierFeedback: "duplicate",
            score: 0.5
          ),
        ]
      )
    )

    #expect(report.seedEvidenceIDs == [evidence.id])
    #expect(report.uniqueEvidenceCount == 1)
    #expect(report.phases.isEmpty)
    #expect(report.sleepReport == nil)
  }

  private static func optimizationRunRequest(
    runID: String,
    skillID: CoreAgentSkillID
  ) -> CoreAgentSkillOptimizationRunRequest {
    CoreAgentSkillOptimizationRunRequest(
      runID: runID,
      targets: [CoreAgentSkillOptimizationRunTarget(skillID: skillID, baselineScore: 0.5)]
    )
  }

  private static func optimizationRunReport(
    runID: String,
    sleepReport: CoreAgentSkillSleepOptimizationReport? = nil
  ) -> CoreAgentSkillOptimizationRunReport {
    CoreAgentSkillOptimizationRunReport(
      runID: runID,
      seedEvidenceIDs: [],
      harvestedEvidenceIDs: [],
      replayRequestIDs: [],
      replayEvidenceIDs: [],
      generatedProposalIDs: [],
      suppliedProposalIDs: [],
      sleepReport: sleepReport,
      phases: []
    )
  }

  private static func requireSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
