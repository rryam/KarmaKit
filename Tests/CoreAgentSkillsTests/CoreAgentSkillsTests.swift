import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentSkills SkillOpt foundation")
struct CoreAgentSkillsTests {
  @Test("Curates skills by tags priority and context budget")
  func curatesSkillsByTagsPriorityAndContextBudget() async throws {
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(
      Self.skill(id: "planner", body: "Plan carefully.", tags: ["planning"], priority: 10))
    try await store.save(
      Self.skill(id: "swift", body: "Use Swift Testing.", tags: ["swift"], priority: 20))
    try await store.save(
      Self.skill(
        id: "long", body: String(repeating: "x", count: 200), tags: ["swift"], priority: 30))

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

  @Test("Protected-region policy rejects appends into unterminated slow-update blocks")
  func protectedRegionPolicyRejectsAppendsIntoUnterminatedSlowUpdateBlocks() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(
      id: "swift",
      body: """
        Use XCTest.
        <!-- coreagent-slow-update:start -->
        Protected slow-update memory.
        """
    )
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.append("\nOverwrite protected memory.")],
        validation: Self.validation(score: 0.90)
      ),
      policy: CoreAgentSkillOptimizationPolicy(protectedRegions: [.skillOptSlowUpdate])
    )

    let current = try #require(await store.currentSkill(id: base.id))
    #expect(!result.accepted)
    #expect(current.version == 1)
    #expect(!current.body.contains("Overwrite protected memory."))
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

  @Test("File-backed store persists skill history optimizer memory and best_skill export")
  func fileBackedStorePersistsSkillHistoryOptimizerMemoryAndBestSkillExport() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let base = Self.skill(id: "../swift/planner", body: "Use XCTest.", tags: ["swift"])
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let rejected = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.90,
        candidateEdits: [.append("\nAlways force unwrap.")],
        validation: Self.validation(score: 0.10, passed: false)
      )
    )
    let accepted = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
        validation: Self.validation(score: 0.88)
      )
    )

    let resumed = try FileCoreAgentSkillStore(rootDirectory: root)
    let current = try #require(await resumed.currentSkill(id: base.id))
    let memory = await resumed.optimizerMemory(skillID: base.id)
    let exportURL = try await resumed.exportBestSkillMarkdown(
      id: base.id,
      to: root.appending(path: "exports", directoryHint: .isDirectory)
    )
    let markdown = try String(contentsOf: exportURL, encoding: .utf8)

    #expect(!rejected.accepted)
    #expect(accepted.accepted)
    #expect(current.version == 2)
    #expect(current.body == "Use Swift Testing.")
    #expect(memory.rejectedEdits.count == 1)
    #expect(exportURL.lastPathComponent == "best_skill.md")
    #expect(exportURL.path.hasPrefix(root.path))
    #expect(markdown.contains("Version: 2"))
    #expect(markdown.contains("Use Swift Testing."))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appending(path: "swift").path))
    let rootPath = root.resolvingSymlinksInPath().path
    #expect(
      Self.allFiles(under: root).allSatisfy {
        $0.resolvingSymlinksInPath().path.hasPrefix(rootPath)
      })
  }

  @Test("File-backed store rejects duplicate versions after resume")
  func fileBackedStoreRejectsDuplicateVersionsAfterResume() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await FileCoreAgentSkillStore(rootDirectory: root).save(base)
    let skillFile = try #require(Self.skillFile(id: base.id, version: 1, under: root))
    try Data("not-json".utf8).write(to: skillFile, options: [.atomic])
    let resumed = try FileCoreAgentSkillStore(rootDirectory: root)

    await #expect(throws: CoreAgentSkillOptimizationError.versionCollision(base.id, 1)) {
      try await resumed.save(base)
    }
  }

  @Test("File-backed store fails closed on corrupted skill rows")
  func fileBackedStoreFailsClosedOnCorruptedSkillRows() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    try await store.save(base)
    let skillFile = try #require(Self.firstFile(named: "version-1.json", under: root))
    try Data("not-json".utf8).write(to: skillFile, options: [.atomic])
    let resumed = try FileCoreAgentSkillStore(rootDirectory: root)

    #expect(await resumed.currentSkill(id: base.id) == nil)
    #expect(await resumed.allCurrentSkills().isEmpty)
  }

  @Test("File-backed store rejects misplaced rows and filename version mismatches")
  func fileBackedStoreRejectsMisplacedRowsAndFilenameVersionMismatches() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let skillA = Self.skill(id: "skill-a", body: "A")
    let skillB = CoreAgentSkill(
      id: "skill-b",
      version: 2,
      title: "skill-b",
      body: "B"
    )
    try await store.save(skillA)
    let skillAFile = try #require(Self.skillFile(id: skillA.id, version: 1, under: root))
    let skillADirectory = skillAFile.deletingLastPathComponent()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    try encoder.encode(skillB).write(
      to: skillADirectory.appending(path: "version-2.json"),
      options: [.atomic]
    )
    let misplaced = try FileCoreAgentSkillStore(rootDirectory: root)

    #expect(await misplaced.currentSkill(id: skillA.id) == nil)
    #expect(await misplaced.allCurrentSkills().isEmpty)

    try FileManager.default.removeItem(at: root)
    let mismatchRoot = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: mismatchRoot) }
    let mismatchStore = try FileCoreAgentSkillStore(rootDirectory: mismatchRoot)
    let versionMismatch = CoreAgentSkill(
      id: "skill-c",
      version: 99,
      title: "skill-c",
      body: "C"
    )
    try await mismatchStore.save(Self.skill(id: "skill-c", body: "C"))
    let skillCFile = try #require(
      Self.skillFile(id: versionMismatch.id, version: 1, under: mismatchRoot))
    try encoder.encode(versionMismatch).write(to: skillCFile, options: [.atomic])
    let mismatched = try FileCoreAgentSkillStore(rootDirectory: mismatchRoot)

    #expect(await mismatched.currentSkill(id: versionMismatch.id) == nil)
    #expect(await mismatched.allCurrentSkills().isEmpty)
  }

  @Test("File-backed store does not overwrite corrupted optimizer memory")
  func fileBackedStoreDoesNotOverwriteCorruptedOptimizerMemory() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)
    _ = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.90,
        candidateEdits: [.append("\nNever validate.")],
        validation: Self.validation(score: 0.10, passed: false)
      )
    )
    let memoryFile = try #require(Self.firstFile(suffix: "-optimizer-memory.json", under: root))
    try Data("not-json".utf8).write(to: memoryFile, options: [.atomic])

    await #expect(
      throws: CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for swift"
      )
    ) {
      try await store.recordRejected(
        CoreAgentRejectedSkillEdit(
          edits: [.append("\nDirectly rejected.")],
          validation: Self.validation(score: 0.10, passed: false)
        ),
        skillID: base.id
      )
    }
    await #expect(
      throws: CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for swift"
      )
    ) {
      _ = try await optimizer.propose(
        CoreAgentSkillOptimizationProposal(
          skillID: base.id,
          baselineScore: 0.90,
          candidateEdits: [.append("\nStill invalid.")],
          validation: Self.validation(score: 0.10, passed: false)
        )
      )
    }
    await #expect(
      throws: CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for swift"
      )
    ) {
      try await store.recordMetaObservation(
        CoreAgentSkillMetaObservation(
          runID: "sleep",
          proposalID: "proposal",
          reason: .validationDidNotImprove,
          notes: "corrupt"
        ),
        skillID: base.id
      )
    }
    await #expect(
      throws: CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for swift"
      )
    ) {
      try await store.recordMetaSkillSnapshot(
        Self.metaSkillSnapshot(branchID: "branch-corrupt", epoch: 1),
        skillID: base.id
      )
    }
    await #expect(
      throws: CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for swift"
      )
    ) {
      try await store.recordMetaSkillEvolution(
        CoreAgentSkillMetaSkillEvolutionRecord(
          runID: "run-corrupt",
          branchID: "branch-corrupt",
          previousEpoch: 0,
          nextEpoch: 1,
          acceptedProposalIDs: [],
          rejectedProposalIDs: [],
          evidenceDigest: Self.digest(932)
        ),
        skillID: base.id
      )
    }
    #expect(try String(contentsOf: memoryFile, encoding: .utf8) == "not-json")
  }

  @Test("Optimizer memory decodes rows written before meta skill fields")
  func optimizerMemoryDecodesRowsWrittenBeforeMetaSkillFields() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let skill = Self.skill(id: "legacy-memory", body: "Use held-out gates.")
    try await store.save(skill)
    try await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: [],
        validation: Self.validation(score: 0.10, passed: false)
      ),
      skillID: skill.id
    )
    let memoryFile = try #require(Self.firstFile(suffix: "-optimizer-memory.json", under: root))
    try Data(#"{"rejectedEdits":[],"metaObservations":[]}"#.utf8).write(
      to: memoryFile,
      options: [.atomic]
    )

    let legacyMemory = await store.optimizerMemory(skillID: skill.id)
    #expect(legacyMemory.metaSkillSnapshots.isEmpty)
    #expect(legacyMemory.metaSkillEvolutionRecords.isEmpty)

    try await store.recordMetaSkillSnapshot(
      Self.metaSkillSnapshot(branchID: "legacy-branch", epoch: 1),
      skillID: skill.id
    )
    let updatedMemory = await store.optimizerMemory(skillID: skill.id)
    #expect(updatedMemory.metaSkillSnapshots.map(\.branchID) == ["legacy-branch"])
  }

  @Test("File-backed best_skill export supports explicit safe filenames")
  func fileBackedBestSkillExportSupportsExplicitSafeFilenames() async throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let skill = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await store.save(skill)
    let exportDirectory = root.appending(path: "exports", directoryHint: .isDirectory)

    let explicit = try await store.exportBestSkillMarkdown(
      id: skill.id,
      to: exportDirectory,
      filename: "swift_best_skill.md"
    )

    #expect(explicit.lastPathComponent == "swift_best_skill.md")
    for unsafeFilename in [
      "../best_skill.md", "/tmp/best_skill.md", "nested/best_skill.md", "nested\\best_skill.md",
    ] {
      await #expect(
        throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "export filename must be a plain file name"
        )
      ) {
        _ = try await store.exportBestSkillMarkdown(
          id: skill.id,
          to: exportDirectory,
          filename: unsafeFilename
        )
      }
    }
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

  @Test("Optimization policy rejects empty protected-region markers")
  func optimizationPolicyRejectsEmptyProtectedRegionMarkers() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "protected region markers must be non-empty")
    ) {
      _ = try await optimizer.propose(
        CoreAgentSkillOptimizationProposal(
          skillID: base.id,
          baselineScore: 0.70,
          candidateEdits: [.replace(target: "Use XCTest.", replacement: "Use Swift Testing.")],
          validation: Self.validation(score: 0.90)
        ),
        policy: CoreAgentSkillOptimizationPolicy(
          protectedRegions: [
            CoreAgentSkillProtectedRegion(name: "bad", startMarker: "", endMarker: "")
          ]
        )
      )
    }
    let current = try #require(await store.currentSkill(id: base.id))
    #expect(current.version == 1)
  }

  @Test("Whitespace-only replacement targets are rejected")
  func whitespaceOnlyReplacementTargetsAreRejected() throws {
    #expect(throws: CoreAgentSkillOptimizationError.emptyReplacementTarget) {
      _ = try CoreAgentSkillEdit.replace(target: "   ", replacement: "new").apply(
        to: "old value"
      )
    }
  }

  @Test("Harvests Engine traces into SkillOpt evidence without raw event payloads")
  func harvestsEngineTracesIntoSkillOptEvidenceWithoutRawEventPayloads() async throws {
    let engineStore = InMemoryCoreAgentEngineStore()
    let runID = Self.uuid(701)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(
          runID: runID,
          kind: .toolExecutionStarted,
          message: "Started shell with token=harvest-secret",
          attributes: [
            "api_key": "harvest-secret",
            "tool": "shell",
            "arguments": "delete-everything",
          ]
        ),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "Run failed for prompt delete-everything",
          attributes: [
            "error_type": "authorization harvest-secret",
            "tool": "shell delete-everything",
          ]
        ),
      ]
    )
    try await engineStore.ingest(run, projectID: "coreagent", threadID: "thread-a")
    let issues = try await CoreAgentEngineIssueScanner(store: engineStore).scan(
      projectID: "coreagent")
    let issue = try #require(issues.first)

    let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: engineStore)
    let firstHarvest = await harvester.harvest(projectID: "coreagent", threadID: "thread-a")
    let secondHarvest = await harvester.harvest(projectID: "coreagent", threadID: "thread-a")
    let evidence = try #require(firstHarvest.first)
    let encoded =
      String(
        data: try JSONEncoder().encode(evidence),
        encoding: .utf8
      ) ?? ""

    #expect(firstHarvest.count == 1)
    #expect(firstHarvest.map(\.id) == secondHarvest.map(\.id))
    #expect(evidence.id.hasPrefix("engine-trace-"))
    #expect(evidence.taskID.hasPrefix("engine-issue-"))
    #expect(evidence.transcriptDigest.hasPrefix("sha256:"))
    #expect(evidence.toolEventDigest.hasPrefix("sha256:"))
    #expect(evidence.score == 0)
    #expect(evidence.metadata["source"] == "coreagent-engine")
    #expect(evidence.metadata["project_id"] == "coreagent")
    #expect(evidence.metadata["thread_id"] == "thread-a")
    #expect(evidence.metadata["run_id"] == runID.uuidString.lowercased())
    #expect(evidence.metadata["run_status"] == "failed")
    #expect(evidence.metadata["issue_id_digest"]?.hasPrefix("sha256:") == true)
    #expect(evidence.metadata["issue_status"] == CoreAgentEngineIssueStatus.open.rawValue)
    #expect(evidence.verifierFeedback == "engine issue linked")
    #expect(evidence.metadata["error_type"] == nil)
    #expect(evidence.metadata["tool"] == nil)
    #expect(evidence.metadata["issue_fingerprint"] == nil)
    #expect(!encoded.contains("harvest-secret"))
    #expect(!encoded.contains("delete-everything"))
    #expect(!encoded.contains(issue.fingerprint))
  }

  @Test("Harvester filters unverified and non-finalized Engine traces")
  func harvesterFiltersUnverifiedAndNonFinalizedEngineTraces() async throws {
    let validID = Self.uuid(711)
    let tamperedID = Self.uuid(712)
    let partialID = Self.uuid(713)
    let validRun = Self.run(
      id: validID,
      events: [
        Self.event(runID: validID, kind: .runCompleted, message: "done")
      ]
    )
    let originalTamperedRun = Self.run(
      id: tamperedID,
      events: [
        Self.event(runID: tamperedID, kind: .runCompleted, message: "original")
      ]
    )
    let changedTamperedRun = Self.run(
      id: tamperedID,
      events: [
        Self.event(runID: tamperedID, kind: .runFailed, message: "changed")
      ]
    )
    let partialRun = Self.run(
      id: partialID,
      events: [
        Self.event(runID: partialID, kind: .toolExecutionStarted, message: "partial")
      ]
    )
    let store = StaticEngineStore(traces: [
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: validRun,
        receipt: try CoreAgentRunReceipt(run: validRun)
      ),
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: changedTamperedRun,
        receipt: try CoreAgentRunReceipt(run: originalTamperedRun)
      ),
      CoreAgentEngineTrace(
        projectID: "coreagent",
        threadID: nil,
        run: partialRun,
        receipt: try CoreAgentRunReceipt(run: partialRun)
      ),
    ])
    let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: store)

    let evidence = await harvester.harvest(projectID: "coreagent")

    #expect(evidence.map { $0.metadata["run_id"] } == [validID.uuidString.lowercased()])
    #expect(evidence.map(\.score) == [1])
  }

  @Test("Replay generator creates deterministic replay and dream rollout requests")
  func replayGeneratorCreatesDeterministicReplayAndDreamRolloutRequests() throws {
    let failed = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-failed",
      taskID: "issue-authorization",
      transcriptDigest: "sha256:failed-transcript",
      toolEventDigest: "sha256:failed-tools",
      verifierFeedback: "typed failure secret-feedback",
      score: 0,
      metadata: [
        "project_id": "coreagent",
        "run_id": "failed-run",
        "run_status": "failed",
        "suite_id": "source-train",
      ]
    )
    let completed = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-completed",
      taskID: "run-completed",
      transcriptDigest: "sha256:completed-transcript",
      toolEventDigest: "sha256:completed-tools",
      verifierFeedback: "typed success secret-feedback",
      score: 1,
      metadata: [
        "project_id": "coreagent",
        "run_id": "completed-run",
        "run_status": "completed",
        "suite_id": "source-heldout",
      ]
    )
    let generator = CoreAgentSkillReplayGenerator()
    let unknownSuite = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-unknown-suite",
      taskID: "run-unknown-suite",
      transcriptDigest: "sha256:unknown-suite-transcript",
      toolEventDigest: "sha256:unknown-suite-tools",
      verifierFeedback: "unknown suite secret-feedback",
      score: 1,
      metadata: [
        "project_id": "coreagent",
        "run_id": "unknown-suite-run",
        "run_status": "completed",
      ]
    )

    let splitSafe = try generator.generate(
      from: [failed, unknownSuite, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        excludedSourceSuiteIDs: ["source-train"],
        includeDreamRolloutsForFailures: true
      )
    )
    let withDreams = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true
      )
    )
    let withDreamsAgain = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true
      )
    )
    let capped = try generator.generate(
      from: [failed, completed],
      policy: CoreAgentSkillReplayGenerationPolicy(
        heldoutSuiteID: "heldout-replay",
        includeDreamRolloutsForFailures: true,
        maxRequests: 2
      )
    )
    let encoded =
      String(
        data: try JSONEncoder().encode(withDreams),
        encoding: .utf8
      ) ?? ""

    #expect(splitSafe.map(\.sourceEvidenceID) == ["engine-trace-completed"])
    #expect(splitSafe.map(\.mode) == [.replay])
    #expect(splitSafe.first?.heldoutSuiteID == "heldout-replay")
    #expect(splitSafe.first?.metadata["source_suite_id"] == "source-heldout")
    #expect(
      withDreams.map { "\($0.mode.rawValue):\($0.sourceEvidenceID)" } == [
        "replay:engine-trace-failed",
        "dream:engine-trace-failed",
        "replay:engine-trace-completed",
      ])
    #expect(withDreams.map(\.id) == withDreamsAgain.map(\.id))
    #expect(
      capped.map { "\($0.mode.rawValue):\($0.sourceEvidenceID)" } == [
        "replay:engine-trace-failed",
        "dream:engine-trace-failed",
      ])
    #expect(withDreams.allSatisfy { $0.id.hasPrefix("skill-rollout-") })
    #expect(withDreams.allSatisfy { $0.transcriptDigest.hasPrefix("sha256:") })
    #expect(withDreams.allSatisfy { $0.heldoutSuiteID == "heldout-replay" })
    #expect(!encoded.contains("secret-feedback"))
  }

  @Test("Replay generation policy rejects invalid heldout suite and request caps")
  func replayGenerationPolicyRejectsInvalidHeldoutSuiteAndRequestCaps() throws {
    let generator = CoreAgentSkillReplayGenerator()
    let evidence = CoreAgentSkillRolloutEvidence(
      id: "engine-trace-completed",
      taskID: "run-completed",
      transcriptDigest: "sha256:completed-transcript",
      toolEventDigest: "sha256:completed-tools",
      verifierFeedback: "typed success",
      score: 1,
      metadata: ["run_status": "completed"]
    )

    #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try generator.generate(
        from: [evidence],
        policy: CoreAgentSkillReplayGenerationPolicy(heldoutSuiteID: "  ")
      )
    }
    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxRequests must be positive"
      )
    ) {
      _ = try generator.generate(
        from: [evidence],
        policy: CoreAgentSkillReplayGenerationPolicy(
          heldoutSuiteID: "heldout-replay",
          maxRequests: 0
        )
      )
    }
  }

  @Test("Replay executor executes requests into sanitized rollout evidence")
  func replayExecutorExecutesRequestsIntoSanitizedRolloutEvidence() async throws {
    let replayRequest = Self.replayRequest(
      id: "request-replay",
      mode: .replay,
      metadata: [
        "source_project_id": "coreagent",
        "raw_prompt": "do not copy replay-secret",
      ]
    )
    let dreamRequest = Self.replayRequest(id: "request-dream", mode: .dream)
    let backend = StaticReplayBackend(outcomes: [
      replayRequest.id: CoreAgentSkillReplayOutcome(
        requestID: replayRequest.id,
        transcriptDigest: Self.digest(910),
        toolEventDigest: Self.digest(911),
        verifierFeedback: "replay passed with do not copy replay-secret",
        score: 0.75
      ),
      dreamRequest.id: CoreAgentSkillReplayOutcome(
        requestID: dreamRequest.id,
        transcriptDigest: Self.digest(920),
        toolEventDigest: Self.digest(921),
        verifierFeedback: "dream found a safer path with do not copy dream-secret",
        score: 0.55
      ),
    ])
    let executor = CoreAgentSkillReplayExecutor(backend: backend)

    let first = try await executor.execute([replayRequest, dreamRequest])
    let second = try await executor.execute([replayRequest, dreamRequest])
    let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""

    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.map(\.taskID) == ["task-auth", "task-auth"])
    #expect(first.map(\.transcriptDigest) == [Self.digest(910), Self.digest(920)])
    #expect(first.map(\.toolEventDigest) == [Self.digest(911), Self.digest(921)])
    #expect(first.map(\.score) == [0.75, 0.55])
    #expect(
      first.map(\.verifierFeedback) == [
        "replay execution completed",
        "dream execution completed",
      ])
    #expect(first.map { $0.metadata["suite_id"] } == ["heldout-replay", "heldout-replay"])
    #expect(first.map { $0.metadata["replay_mode"] } == ["replay", "dream"])
    #expect(first.map { $0.metadata["replay_request_id"] } == ["request-replay", "request-dream"])
    #expect(first.first?.metadata["source_project_id"] == "coreagent")
    #expect(first.first?.metadata["verifier_feedback_digest"]?.hasPrefix("sha256:") == true)
    #expect(first.first?.metadata["raw_prompt"] == nil)
    #expect(first.allSatisfy { $0.id.hasPrefix("replay-evidence-") })
    #expect(!encoded.contains("replay-secret"))
    #expect(!encoded.contains("dream-secret"))
  }

  @Test("Replay executor validates requests and backend outcomes fail closed")
  func replayExecutorValidatesRequestsAndBackendOutcomesFailClosed() async throws {
    let request = Self.replayRequest(id: "request-replay", mode: .replay)
    let countingBackend = CountingReplayBackend()
    let executor = CoreAgentSkillReplayExecutor(backend: countingBackend)

    await #expect(throws: CoreAgentSkillOptimizationError.duplicateReplayRequest("request-replay"))
    {
      _ = try await executor.execute([request, request])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(throws: CoreAgentSkillOptimizationError.emptyHeldoutSuiteID) {
      _ = try await executor.execute([
        Self.replayRequest(id: "empty-suite", mode: .replay, heldoutSuiteID: " ")
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request digests must be sha256"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "uppercase-digest",
          mode: .replay,
          transcriptDigest: "sha256:\(String(repeating: "A", count: 64))"
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request digests must be sha256"
      )
    ) {
      _ = try await executor.execute([
        request,
        Self.replayRequest(
          id: "later-invalid-digest",
          mode: .replay,
          transcriptDigest: "sha256:\(String(repeating: "0", count: 63))"
        ),
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay request identity fields must be non-empty"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(id: " ", mode: .replay)
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite ID cannot be empty"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "empty-source-suite",
          mode: .replay,
          metadata: ["source_suite_id": " "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite cannot match heldout suite"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "split-leak",
          mode: .replay,
          metadata: ["source_suite_id": "heldout-replay"]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite cannot match heldout suite"
      )
    ) {
      _ = try await executor.execute([
        Self.replayRequest(
          id: "split-leak-whitespace",
          mode: .replay,
          metadata: ["source_suite_id": " heldout-replay "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite is excluded"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: countingBackend,
        policy: CoreAgentSkillReplayExecutionPolicy(excludedSourceSuiteIDs: ["train"])
      ).execute([
        Self.replayRequest(
          id: "excluded-source",
          mode: .replay,
          metadata: ["source_suite_id": "train"]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay source suite is excluded"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: countingBackend,
        policy: CoreAgentSkillReplayExecutionPolicy(excludedSourceSuiteIDs: ["train"])
      ).execute([
        Self.replayRequest(
          id: "excluded-source-whitespace",
          mode: .replay,
          metadata: ["source_suite_id": " train "]
        )
      ])
    }
    #expect(await countingBackend.callCount == 0)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome request ID mismatch"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: "other-request",
            transcriptDigest: Self.digest(930),
            toolEventDigest: Self.digest(931),
            verifierFeedback: "mismatch",
            score: 0.5
          )
        ])
      ).execute([request])
    }

    await #expect(throws: CoreAgentSkillOptimizationError.invalidValidationScore(1.5)) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: Self.digest(940),
            toolEventDigest: Self.digest(941),
            verifierFeedback: "bad score",
            score: 1.5
          )
        ])
      ).execute([request])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome digests must be sha256"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: "raw transcript",
            toolEventDigest: Self.digest(951),
            verifierFeedback: "bad digest",
            score: 0.5
          )
        ])
      ).execute([request])
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome digests must be sha256"
      )
    ) {
      _ = try await CoreAgentSkillReplayExecutor(
        backend: StaticReplayBackend(outcomes: [
          request.id: CoreAgentSkillReplayOutcome(
            requestID: request.id,
            transcriptDigest: "sha256:\(String(repeating: "z", count: 64))",
            toolEventDigest: Self.digest(961),
            verifierFeedback: "bad hex digest",
            score: 0.5
          )
        ])
      ).execute([request])
    }
  }

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

  @Test("FoundationModels proposal backend requires literal edit operation names")
  func foundationModelsProposalBackendRequiresLiteralEditOperationNames() async throws {
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
                    "operation": " replace",
                    "target": "Use XCTest.",
                    "replacement": "Use Swift Testing.",
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
          transcriptDigest: Self.digest(1_130),
          toolEventDigest: Self.digest(1_131),
          score: 0.4
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

  private static func validation(
    score: Double,
    heldoutSuiteID: String = "heldout-swift",
    passed: Bool = true
  ) -> CoreAgentSkillValidationResult {
    CoreAgentSkillValidationResult(
      score: score,
      heldoutSuiteID: heldoutSuiteID,
      passed: passed,
      notes: "validation"
    )
  }

  private static func run(
    id: UUID,
    events: [CoreAgentEvent]
  ) -> CoreAgentRun {
    CoreAgentRun(
      id: id,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      usage: CoreAgentUsage(
        inputTokens: 10,
        cachedInputTokens: 2,
        outputTokens: 4,
        reasoningTokens: 1
      ),
      events: events
    )
  }

  private static func event(
    runID: UUID,
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) -> CoreAgentEvent {
    CoreAgentEvent(
      id: UUID(),
      runID: runID,
      timestamp: Date(timeIntervalSince1970: 1),
      kind: kind,
      message: message,
      attributes: attributes
    )
  }

  private static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "coreagent-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func firstFile(named fileName: String, under root: URL) -> URL? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    for case let url as URL in enumerator where url.lastPathComponent == fileName {
      return url
    }
    return nil
  }

  private static func firstFile(suffix: String, under root: URL) -> URL? {
    allFiles(under: root).first { $0.lastPathComponent.hasSuffix(suffix) }
  }

  private static func skillFile(
    id: CoreAgentSkillID,
    version: Int,
    under root: URL
  ) -> URL? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return allFiles(under: root).first { url in
      guard url.lastPathComponent == "version-\(version).json",
        let data = try? Data(contentsOf: url),
        let skill = try? decoder.decode(CoreAgentSkill.self, from: data)
      else {
        return false
      }
      return skill.id == id && skill.version == version
    }
  }

  private static func allFiles(under root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    else {
      return []
    }
    return enumerator.compactMap { item -> URL? in
      guard let url = item as? URL,
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else {
        return nil
      }
      return url
    }
  }

  private static func replayRequest(
    id: String,
    mode: CoreAgentSkillReplayMode,
    heldoutSuiteID: String = "heldout-replay",
    transcriptDigest: String = Self.digest(900),
    toolEventDigest: String = Self.digest(901),
    metadata: [String: String] = [:]
  ) -> CoreAgentSkillReplayRequest {
    CoreAgentSkillReplayRequest(
      id: id,
      mode: mode,
      sourceEvidenceID: "engine-trace-auth",
      taskID: "task-auth",
      transcriptDigest: transcriptDigest,
      toolEventDigest: toolEventDigest,
      heldoutSuiteID: heldoutSuiteID,
      metadata: metadata
    )
  }

  private static func digest(_ suffix: Int) -> String {
    "sha256:\(String(format: "%064x", suffix))"
  }

  private static func modelProposalCandidate(
    id: String,
    skillID: CoreAgentSkillID,
    baselineScore: Double = 0.5,
    edits: [CoreAgentSkillEdit] = [
      .replace(target: "Use XCTest.", replacement: "Use Swift Testing.")
    ],
    validation: CoreAgentSkillValidationResult = CoreAgentSkillValidationResult(
      score: 0.7,
      heldoutSuiteID: "heldout-swift",
      passed: true,
      notes: "candidate"
    ),
    evidenceIDs: [String] = ["replay-evidence-swift"]
  ) -> CoreAgentSkillModelProposalCandidate {
    CoreAgentSkillModelProposalCandidate(
      id: id,
      skillID: skillID,
      baselineScore: baselineScore,
      candidateEdits: edits,
      validation: validation,
      evidenceIDs: evidenceIDs
    )
  }

  private static func sleepProposal(
    id: String,
    skillID: CoreAgentSkillID = "swift",
    score: Double = 0.7,
    replacement: String = "Use Swift Testing."
  ) -> CoreAgentSkillSleepOptimizationProposal {
    CoreAgentSkillSleepOptimizationProposal(
      id: id,
      proposal: CoreAgentSkillOptimizationProposal(
        skillID: skillID,
        baselineScore: 0.5,
        candidateEdits: [.replace(target: "Use XCTest.", replacement: replacement)],
        validation: CoreAgentSkillValidationResult(
          score: score,
          heldoutSuiteID: "heldout-swift",
          passed: true,
          notes: "candidate"
        )
      )
    )
  }

  private static func frontierScore(
    proposalID: String,
    productivityScore: Double = 0.7,
    noveltyScore: Double = 0.7,
    strictScore: Double = 0.7,
    looseScore: Double = 0.7,
    objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation] = []
  ) -> CoreAgentSkillMetaEvolutionFrontierScore {
    CoreAgentSkillMetaEvolutionFrontierScore(
      proposalID: proposalID,
      productivityScore: productivityScore,
      noveltyScore: noveltyScore,
      strictScore: strictScore,
      looseScore: looseScore,
      objectiveEvaluations: objectiveEvaluations
    )
  }

  private static func metaSkillComponent(
    digest: String,
    policyVersion: String = "policy-v1"
  ) -> CoreAgentSkillMetaSkillComponent {
    CoreAgentSkillMetaSkillComponent(
      componentDigest: digest,
      policyVersion: policyVersion
    )
  }

  private static func metaSkillSnapshot(
    branchID: String,
    epoch: Int,
    analyzerDigest: String = Self.digest(920),
    retrieverDigest: String = Self.digest(921),
    allocatorDigest: String = Self.digest(922),
    proposerDigest: String = Self.digest(923),
    evolverDigest: String = Self.digest(924),
    objectiveDigest: String = Self.digest(925)
  ) -> CoreAgentSkillMetaSkillBranchSnapshot {
    CoreAgentSkillMetaSkillBranchSnapshot(
      branchID: branchID,
      parentBranchID: nil,
      epoch: epoch,
      analyzer: Self.metaSkillComponent(digest: analyzerDigest),
      retriever: Self.metaSkillComponent(digest: retrieverDigest),
      allocator: Self.metaSkillComponent(digest: allocatorDigest),
      proposer: Self.metaSkillComponent(digest: proposerDigest),
      evolver: Self.metaSkillComponent(digest: evolverDigest),
      objectiveDigest: objectiveDigest
    )
  }

  @Test("Meta evolution frontier selector filters hack ratio and ranks deterministically")
  func metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically() throws {
    let proposals = [
      Self.sleepProposal(id: "stable", score: 0.72),
      Self.sleepProposal(id: "productive", score: 0.70),
      Self.sleepProposal(id: "hacked", score: 0.96),
    ]
    let selection = try CoreAgentSkillMetaEvolutionFrontierSelector().select(
      proposals: proposals,
      scores: [
        CoreAgentSkillMetaEvolutionFrontierScore(
          proposalID: "stable",
          productivityScore: 0.30,
          noveltyScore: 0.80,
          strictScore: 0.68,
          looseScore: 0.72
        ),
        CoreAgentSkillMetaEvolutionFrontierScore(
          proposalID: "productive",
          productivityScore: 0.92,
          noveltyScore: 0.90,
          strictScore: 0.70,
          looseScore: 0.76
        ),
        CoreAgentSkillMetaEvolutionFrontierScore(
          proposalID: "hacked",
          productivityScore: 0.95,
          noveltyScore: 0.95,
          strictScore: 0.30,
          looseScore: 0.96
        ),
      ],
      policy: CoreAgentSkillMetaEvolutionFrontierPolicy(
        maxSelectedProposals: 2,
        maximumHackRatio: 2.0
      )
    )

    #expect(selection.selected.map(\.id) == ["productive", "stable"])
    #expect(selection.rejectedProposalIDs == ["hacked"])
    #expect(selection.auditTrail.map(\.proposalID) == ["hacked", "productive", "stable"])
  }

  @Test("Meta evolution frontier selector rejects invalid objective evidence")
  func metaEvolutionFrontierSelectorRejectsInvalidObjectiveEvidence() throws {
    #expect(throws: CoreAgentSkillOptimizationError.invalidValidationScore(1.5)) {
      _ = try CoreAgentSkillMetaEvolutionFrontierSelector().select(
        proposals: [
          Self.sleepProposal(id: "proposal-a")
        ],
        scores: [
          CoreAgentSkillMetaEvolutionFrontierScore(
            proposalID: "proposal-a",
            productivityScore: 0.7,
            noveltyScore: 0.7,
            strictScore: 0.7,
            looseScore: 0.7,
            objectiveEvaluations: [
              CoreAgentHarnessObjectiveEvaluation(
                candidateID: "proposal-a",
                heldoutSuiteID: "heldout-a",
                objectiveID: "strict",
                score: 1.5
              )
            ]
          )
        ]
      )
    }
  }

  @Test("Meta evolution frontier selector rejects mismatched score contracts")
  func metaEvolutionFrontierSelectorRejectsMismatchedScoreContracts() throws {
    let selector = CoreAgentSkillMetaEvolutionFrontierSelector()

    #expect(throws: CoreAgentSkillOptimizationError.duplicateOptimizationProposal("dup")) {
      _ = try selector.select(
        proposals: [
          Self.sleepProposal(id: "dup"),
          Self.sleepProposal(id: "dup"),
        ],
        scores: []
      )
    }

    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier score references unknown proposal stray"
      )
    ) {
      _ = try selector.select(
        proposals: [
          Self.sleepProposal(id: "known")
        ],
        scores: [
          Self.frontierScore(proposalID: "known"),
          Self.frontierScore(proposalID: "stray"),
        ]
      )
    }

    #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier score missing for proposal missing-score"
      )
    ) {
      _ = try selector.select(
        proposals: [
          Self.sleepProposal(id: "known"),
          Self.sleepProposal(id: "missing-score"),
        ],
        scores: [
          Self.frontierScore(proposalID: "known")
        ]
      )
    }
  }

  @Test("Meta skill branch state persists typed components without raw payloads")
  func metaSkillBranchStatePersistsTypedComponentsWithoutRawPayloads() async throws {
    let root = try Self.temporaryDirectory()
    let store = try FileCoreAgentSkillStore(rootDirectory: root)
    let skill = Self.skill(id: "rsi-branch", body: "Use held-out gates.")
    try await store.save(skill)
    let snapshot = Self.metaSkillSnapshot(branchID: "branch-alpha", epoch: 2)

    try await store.recordMetaSkillSnapshot(snapshot, skillID: skill.id)
    try await store.recordMetaSkillEvolution(
      CoreAgentSkillMetaSkillEvolutionRecord(
        runID: "run-meta",
        branchID: "branch-alpha",
        previousEpoch: 1,
        nextEpoch: 2,
        acceptedProposalIDs: ["accepted"],
        rejectedProposalIDs: ["rejected"],
        frontierRejectedProposalIDs: ["rejected"],
        sleepAcceptedProposalIDs: ["accepted"],
        evidenceDigest: Self.digest(930)
      ),
      skillID: skill.id
    )

    let reopened = try FileCoreAgentSkillStore(rootDirectory: root)
    let memory = await reopened.optimizerMemory(skillID: skill.id)

    #expect(memory.metaSkillSnapshots.map(\.branchID) == ["branch-alpha"])
    #expect(memory.metaSkillSnapshots.first?.epoch == 2)
    #expect(memory.metaSkillSnapshots.first?.analyzer.componentDigest == Self.digest(920))
    #expect(memory.metaSkillEvolutionRecords.map(\.runID) == ["run-meta"])
    #expect(memory.metaSkillEvolutionRecords.first?.acceptedProposalIDs == ["accepted"])
    #expect(memory.metaSkillEvolutionRecords.first?.frontierRejectedProposalIDs == ["rejected"])
    #expect(memory.metaSkillEvolutionRecords.first?.sleepAcceptedProposalIDs == ["accepted"])
    #expect(memory.metaSkillEvolutionRecords.first?.sleepRejectedProposalIDs == [])
  }

  @Test("Meta skill branch state rejects invalid identity digest and epochs")
  func metaSkillBranchStateRejectsInvalidIdentityDigestAndEpochs() async throws {
    let skill = Self.skill(id: "rsi-invalid", body: "Body")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill branch ID is invalid"
      )
    ) {
      try await store.recordMetaSkillSnapshot(
        Self.metaSkillSnapshot(branchID: "../branch", epoch: 1),
        skillID: skill.id
      )
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill component digest must be lowercase sha256"
      )
    ) {
      try await store.recordMetaSkillSnapshot(
        Self.metaSkillSnapshot(
          branchID: "branch-beta",
          epoch: 1,
          analyzerDigest: "sha256:BAD"
        ),
        skillID: skill.id
      )
    }

    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill evolution epoch must advance"
      )
    ) {
      try await store.recordMetaSkillEvolution(
        CoreAgentSkillMetaSkillEvolutionRecord(
          runID: "run-invalid",
          branchID: "branch-beta",
          previousEpoch: 2,
          nextEpoch: 2,
          acceptedProposalIDs: [],
          rejectedProposalIDs: [],
          evidenceDigest: Self.digest(931)
        ),
        skillID: skill.id
      )
    }
  }

  @Test("Meta skill branch state rejects duplicate snapshot and evolution identities")
  func metaSkillBranchStateRejectsDuplicateSnapshotAndEvolutionIdentities() async throws {
    let skill = Self.skill(id: "rsi-duplicates", body: "Body")
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(skill)
    let snapshot = Self.metaSkillSnapshot(branchID: "branch-duplicate", epoch: 1)

    try await store.recordMetaSkillSnapshot(snapshot, skillID: skill.id)
    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill snapshot branch epoch already recorded"
      )
    ) {
      try await store.recordMetaSkillSnapshot(snapshot, skillID: skill.id)
    }

    let record = CoreAgentSkillMetaSkillEvolutionRecord(
      runID: "run-duplicate",
      branchID: "branch-duplicate",
      previousEpoch: 0,
      nextEpoch: 1,
      acceptedProposalIDs: ["accepted"],
      rejectedProposalIDs: ["rejected"],
      frontierRejectedProposalIDs: ["rejected"],
      sleepAcceptedProposalIDs: ["accepted"],
      evidenceDigest: Self.digest(933)
    )
    try await store.recordMetaSkillEvolution(record, skillID: skill.id)
    await #expect(
      throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill evolution record already exists"
      )
    ) {
      try await store.recordMetaSkillEvolution(record, skillID: skill.id)
    }
  }

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
}

private struct StaticRSIMemoryAdapter: CoreAgentSkillRSIMemoryAdapter {
  let references: [CoreAgentSkillRSIMemoryReference]

  func fetchReferences(
    _ request: CoreAgentSkillRSIMemoryFetchRequest
  ) async throws -> [CoreAgentSkillRSIMemoryReference] {
    _ = request
    return references
  }
}

private struct StaticEngineStore: CoreAgentEngineStore {
  let traces: [CoreAgentEngineTrace]

  func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String?
  ) async throws -> CoreAgentEngineTrace {
    throw CoreAgentEngineStoreError.nonFinalizedRun(run.id)
  }

  func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    traces.first { $0.projectID == projectID && $0.run.id == runID }
  }

  func traces(projectID: String, threadID: String?) async -> [CoreAgentEngineTrace] {
    traces.filter { $0.projectID == projectID && (threadID == nil || $0.threadID == threadID) }
  }

  func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    issue
  }

  func updateIssueStatus(_ issueID: String, status: CoreAgentEngineIssueStatus) async throws {}

  func issues(projectID: String, status: CoreAgentEngineIssueStatus?) async
    -> [CoreAgentEngineIssue]
  {
    []
  }
}

private struct StaticReplayBackend: CoreAgentSkillReplayBackend {
  let outcomes: [String: CoreAgentSkillReplayOutcome]

  func execute(_ request: CoreAgentSkillReplayRequest) async throws -> CoreAgentSkillReplayOutcome {
    guard let outcome = outcomes[request.id] else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(request.id)
    }
    return outcome
  }
}

private actor CountingReplayBackend: CoreAgentSkillReplayBackend {
  private var count = 0

  var callCount: Int {
    count
  }

  func execute(_ request: CoreAgentSkillReplayRequest) async throws -> CoreAgentSkillReplayOutcome {
    count += 1
    return CoreAgentSkillReplayOutcome(
      requestID: request.id,
      transcriptDigest: "sha256:\(String(format: "%064x", 990))",
      toolEventDigest: "sha256:\(String(format: "%064x", 991))",
      verifierFeedback: "called",
      score: 0.5
    )
  }
}

private actor CapturingModelProposalBackend: CoreAgentSkillModelProposalBackend {
  let candidates: [CoreAgentSkillModelProposalCandidate]
  private(set) var lastRequest: CoreAgentSkillModelProposalRequest?

  init(candidates: [CoreAgentSkillModelProposalCandidate]) {
    self.candidates = candidates
  }

  func generate(
    _ request: CoreAgentSkillModelProposalRequest
  ) async throws -> [CoreAgentSkillModelProposalCandidate] {
    lastRequest = request
    return candidates
  }
}

private actor CountingModelProposalBackend: CoreAgentSkillModelProposalBackend {
  private var count = 0

  var callCount: Int {
    count
  }

  func generate(
    _ request: CoreAgentSkillModelProposalRequest
  ) async throws -> [CoreAgentSkillModelProposalCandidate] {
    count += 1
    return []
  }
}

extension Transcript {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { entry in
      switch entry {
      case .instructions(let instructions):
        instructions.segments.containsText(expected)
      case .prompt(let prompt):
        prompt.segments.containsText(expected)
      case .toolOutput(let output):
        output.segments.containsText(expected)
      case .response(let response):
        response.segments.containsText(expected)
      case .reasoning(let reasoning):
        reasoning.segments.containsText(expected)
      case .toolCalls(let calls):
        calls.contains { $0.arguments.jsonString.contains(expected) }
      @unknown default:
        false
      }
    }
  }
}

extension [Transcript.Segment] {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}
