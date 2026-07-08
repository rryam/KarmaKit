import CoreAgent
import CoreAgentEngine
import CoreAgentSkills
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

extension CoreAgentSkillsTests {
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

  static func skill(
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

  static func validation(
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

  static func run(
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

  static func event(
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

  static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "coreagent-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func firstFile(named fileName: String, under root: URL) -> URL? {
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

  static func firstFile(suffix: String, under root: URL) -> URL? {
    allFiles(under: root).first { $0.lastPathComponent.hasSuffix(suffix) }
  }

  static func skillFile(
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

  static func allFiles(under root: URL) -> [URL] {
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

  static func replayRequest(
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

  static func digest(_ suffix: Int) -> String {
    "sha256:\(String(format: "%064x", suffix))"
  }

  static func modelProposalCandidate(
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

  static func sleepProposal(
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

  static func frontierScore(
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

  static func metaSkillComponent(
    digest: String,
    policyVersion: String = "policy-v1"
  ) -> CoreAgentSkillMetaSkillComponent {
    CoreAgentSkillMetaSkillComponent(
      componentDigest: digest,
      policyVersion: policyVersion
    )
  }

  static func metaSkillSnapshot(
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

}
