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

}

struct StaticRSIMemoryAdapter: CoreAgentSkillRSIMemoryAdapter {
  let references: [CoreAgentSkillRSIMemoryReference]

  func fetchReferences(
    _ request: CoreAgentSkillRSIMemoryFetchRequest
  ) async throws -> [CoreAgentSkillRSIMemoryReference] {
    _ = request
    return references
  }
}

struct StaticEngineStore: CoreAgentEngineStore {
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

struct StaticReplayBackend: CoreAgentSkillReplayBackend {
  let outcomes: [String: CoreAgentSkillReplayOutcome]

  func execute(_ request: CoreAgentSkillReplayRequest) async throws -> CoreAgentSkillReplayOutcome {
    guard let outcome = outcomes[request.id] else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(request.id)
    }
    return outcome
  }
}

actor CountingReplayBackend: CoreAgentSkillReplayBackend {
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

actor CapturingModelProposalBackend: CoreAgentSkillModelProposalBackend {
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

actor CountingModelProposalBackend: CoreAgentSkillModelProposalBackend {
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
  func containsText(_ expected: String) -> Bool {
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
  func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}
