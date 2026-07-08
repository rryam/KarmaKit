import CoreAgentEngine
import CryptoKit
import Foundation

public struct CoreAgentSkillOptimizationRunHarvestConfig: Sendable {
  public let projectID: String
  public let threadID: String?
  public let maximumTotalTokens: Int?

  public init(
    projectID: String,
    threadID: String? = nil,
    maximumTotalTokens: Int? = nil
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.maximumTotalTokens = maximumTotalTokens.map { max(0, $0) }
  }
}

public struct CoreAgentSkillOptimizationRunReplayConfig: Sendable {
  public let generationPolicy: CoreAgentSkillReplayGenerationPolicy
  public let executionPolicy: CoreAgentSkillReplayExecutionPolicy
  public let backend: any CoreAgentSkillReplayBackend

  public init(
    generationPolicy: CoreAgentSkillReplayGenerationPolicy,
    executionPolicy: CoreAgentSkillReplayExecutionPolicy = CoreAgentSkillReplayExecutionPolicy(),
    backend: any CoreAgentSkillReplayBackend
  ) {
    self.generationPolicy = generationPolicy
    self.executionPolicy = executionPolicy
    self.backend = backend
  }
}

public struct CoreAgentSkillOptimizationRunProposalConfig: Sendable {
  public let backend: any CoreAgentSkillModelProposalBackend
  public let maxProposals: Int

  public init(
    backend: any CoreAgentSkillModelProposalBackend,
    maxProposals: Int = 3
  ) {
    self.backend = backend
    self.maxProposals = maxProposals
  }
}

public struct CoreAgentSkillMetaSkillRunConfig: Sendable {
  public let skillID: CoreAgentSkillID
  public let snapshot: CoreAgentSkillMetaSkillBranchSnapshot
  public let previousEpoch: Int

  public init(
    skillID: CoreAgentSkillID,
    snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    previousEpoch: Int
  ) {
    self.skillID = skillID
    self.snapshot = snapshot
    self.previousEpoch = previousEpoch
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierConfig: Sendable {
  public let scores: [CoreAgentSkillMetaEvolutionFrontierScore]
  public let policy: CoreAgentSkillMetaEvolutionFrontierPolicy

  public init(
    scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy =
      CoreAgentSkillMetaEvolutionFrontierPolicy()
  ) {
    self.scores = scores
    self.policy = policy
  }
}

public struct CoreAgentSkillOptimizationRunTarget: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double

  public init(skillID: CoreAgentSkillID, baselineScore: Double) {
    self.skillID = skillID
    self.baselineScore = baselineScore
  }
}

public struct CoreAgentSkillOptimizationRunRequest: Sendable {
  public let runID: String
  public let policy: CoreAgentSkillOptimizationPolicy
  public let harvest: CoreAgentSkillOptimizationRunHarvestConfig?
  public let replay: CoreAgentSkillOptimizationRunReplayConfig?
  public let proposal: CoreAgentSkillOptimizationRunProposalConfig?
  public let memory: CoreAgentSkillRSIMemoryImportConfig?
  public let metaSkill: CoreAgentSkillMetaSkillRunConfig?
  public let frontier: CoreAgentSkillMetaEvolutionFrontierConfig?
  public let targets: [CoreAgentSkillOptimizationRunTarget]
  public let seedEvidence: [CoreAgentSkillRolloutEvidence]
  public let suppliedProposals: [CoreAgentSkillSleepOptimizationProposal]

  public init(
    runID: String,
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(),
    harvest: CoreAgentSkillOptimizationRunHarvestConfig? = nil,
    replay: CoreAgentSkillOptimizationRunReplayConfig? = nil,
    proposal: CoreAgentSkillOptimizationRunProposalConfig? = nil,
    memory: CoreAgentSkillRSIMemoryImportConfig? = nil,
    metaSkill: CoreAgentSkillMetaSkillRunConfig? = nil,
    frontier: CoreAgentSkillMetaEvolutionFrontierConfig? = nil,
    targets: [CoreAgentSkillOptimizationRunTarget] = [],
    seedEvidence: [CoreAgentSkillRolloutEvidence] = [],
    suppliedProposals: [CoreAgentSkillSleepOptimizationProposal] = []
  ) {
    self.runID = runID
    self.policy = policy
    self.harvest = harvest
    self.replay = replay
    self.proposal = proposal
    self.memory = memory
    self.metaSkill = metaSkill
    self.frontier = frontier
    self.targets = targets
    self.seedEvidence = seedEvidence
    self.suppliedProposals = suppliedProposals
  }
}

public enum CoreAgentSkillOptimizationRunPhase: String, Codable, Equatable, Sendable {
  case metaSkillStateRecorded
  case harvested
  case replayGenerated
  case replayExecuted
  case proposalsGenerated
  case memoryImported
  case frontierSelected
  case sleepOptimized
  case metaSkillEvolved
}

public struct CoreAgentSkillOptimizationRunPhaseRecord: Equatable, Sendable {
  public let phase: CoreAgentSkillOptimizationRunPhase
  public let harvestedEvidenceCount: Int
  public let replayRequestCount: Int
  public let replayEvidenceCount: Int
  public let proposalCount: Int
  public let acceptedProposalCount: Int
  public let rejectedProposalCount: Int
  public let importedMemoryEntryCount: Int
  public let metaSkillEvolutionRecordCount: Int

  public init(
    phase: CoreAgentSkillOptimizationRunPhase,
    harvestedEvidenceCount: Int = 0,
    replayRequestCount: Int = 0,
    replayEvidenceCount: Int = 0,
    proposalCount: Int = 0,
    acceptedProposalCount: Int = 0,
    rejectedProposalCount: Int = 0,
    importedMemoryEntryCount: Int = 0,
    metaSkillEvolutionRecordCount: Int = 0
  ) {
    self.phase = phase
    self.harvestedEvidenceCount = harvestedEvidenceCount
    self.replayRequestCount = replayRequestCount
    self.replayEvidenceCount = replayEvidenceCount
    self.proposalCount = proposalCount
    self.acceptedProposalCount = acceptedProposalCount
    self.rejectedProposalCount = rejectedProposalCount
    self.importedMemoryEntryCount = importedMemoryEntryCount
    self.metaSkillEvolutionRecordCount = metaSkillEvolutionRecordCount
  }
}

public struct CoreAgentSkillOptimizationRunReport: Equatable, Sendable {
  public let runID: String
  public let seedEvidenceIDs: [String]
  public let harvestedEvidenceIDs: [String]
  public let replayRequestIDs: [String]
  public let replayEvidenceIDs: [String]
  public let generatedProposalIDs: [String]
  public let suppliedProposalIDs: [String]
  public let importedMemoryEntryIDs: [String]
  public let frontierSelectedProposalIDs: [String]
  public let frontierRejectedProposalIDs: [String]
  public let metaSkillBranchID: String?
  public let metaSkillEpoch: Int?
  public let metaSkillEvolutionRecordCount: Int
  public let sleepReport: CoreAgentSkillSleepOptimizationReport?
  public let phases: [CoreAgentSkillOptimizationRunPhaseRecord]

  public init(
    runID: String,
    seedEvidenceIDs: [String],
    harvestedEvidenceIDs: [String],
    replayRequestIDs: [String],
    replayEvidenceIDs: [String],
    generatedProposalIDs: [String],
    suppliedProposalIDs: [String],
    importedMemoryEntryIDs: [String] = [],
    frontierSelectedProposalIDs: [String] = [],
    frontierRejectedProposalIDs: [String] = [],
    metaSkillBranchID: String? = nil,
    metaSkillEpoch: Int? = nil,
    metaSkillEvolutionRecordCount: Int = 0,
    sleepReport: CoreAgentSkillSleepOptimizationReport?,
    phases: [CoreAgentSkillOptimizationRunPhaseRecord]
  ) {
    self.runID = runID
    self.seedEvidenceIDs = seedEvidenceIDs
    self.harvestedEvidenceIDs = harvestedEvidenceIDs
    self.replayRequestIDs = replayRequestIDs
    self.replayEvidenceIDs = replayEvidenceIDs
    self.generatedProposalIDs = generatedProposalIDs
    self.suppliedProposalIDs = suppliedProposalIDs
    self.importedMemoryEntryIDs = importedMemoryEntryIDs
    self.frontierSelectedProposalIDs = frontierSelectedProposalIDs
    self.frontierRejectedProposalIDs = frontierRejectedProposalIDs
    self.metaSkillBranchID = metaSkillBranchID
    self.metaSkillEpoch = metaSkillEpoch
    self.metaSkillEvolutionRecordCount = metaSkillEvolutionRecordCount
    self.sleepReport = sleepReport
    self.phases = phases
  }

  public var uniqueEvidenceCount: Int {
    Set(seedEvidenceIDs + harvestedEvidenceIDs + replayEvidenceIDs).count
  }
}

public struct CoreAgentSkillOptimizationRunExecutor: Sendable {
  private let store: any CoreAgentSkillStore
  private let engineStore: (any CoreAgentEngineStore)?

  public init(
    store: any CoreAgentSkillStore,
    engineStore: (any CoreAgentEngineStore)? = nil
  ) {
    self.store = store
    self.engineStore = engineStore
  }

  public func run(
    _ request: CoreAgentSkillOptimizationRunRequest
  ) async throws -> CoreAgentSkillOptimizationRunReport {
    try Self.validate(request, engineStoreConfigured: engineStore != nil)
    try request.policy.validate()

    if let memory = request.memory {
      guard await store.currentSkill(id: memory.skillID) != nil else {
        throw CoreAgentSkillOptimizationError.missingSkill(memory.skillID)
      }
    }
    if let metaSkill = request.metaSkill {
      guard await store.currentSkill(id: metaSkill.skillID) != nil else {
        throw CoreAgentSkillOptimizationError.missingSkill(metaSkill.skillID)
      }
      guard metaSkill.snapshot.epoch > metaSkill.previousEpoch else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "meta-skill evolution epoch must advance"
        )
      }
    }

    var phases: [CoreAgentSkillOptimizationRunPhaseRecord] = []
    var evidence = try Self.dedupedEvidence(request.seedEvidence)
    let seedEvidenceIDs = evidence.map(\.id)
    var metaSkillBranchID: String?
    var metaSkillEpoch: Int?
    var metaSkillEvolutionRecordCount = 0

    // Validate the harvest token budget BEFORE any store write so a budget-exceeded run
    // fails closed without side effects. Otherwise `recordMetaSkillSnapshot` below would
    // persist branch/epoch bookkeeping for a run that then throws, leaving a partial
    // mutation behind. The harvested evidence is reused after the gate to avoid a second
    // harvest pass.
    var pendingHarvestEvidence: [CoreAgentSkillRolloutEvidence]?
    if let harvest = request.harvest {
      guard let engineStore else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "harvest config requires engineStore on executor"
        )
      }
      let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: engineStore)
      let harvested = await harvester.harvest(
        projectID: harvest.projectID,
        threadID: harvest.threadID
      )
      if let maximumTotalTokens = harvest.maximumTotalTokens {
        let harvestableTraces = await engineStore.traces(
          projectID: harvest.projectID,
          threadID: harvest.threadID
        )
        let harvestedTokenUsage = CoreAgentSkillEngineTraceHarvester.totalTokenUsage(
          in: harvestableTraces
        )
        guard harvestedTokenUsage <= maximumTotalTokens else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "harvested Engine trace token usage \(harvestedTokenUsage) exceeds maximumTotalTokens \(maximumTotalTokens)"
          )
        }
      }
      pendingHarvestEvidence = harvested
    }

    if let metaSkill = request.metaSkill {
      try await store.recordMetaSkillSnapshot(metaSkill.snapshot, skillID: metaSkill.skillID)
      metaSkillBranchID = metaSkill.snapshot.branchID
      metaSkillEpoch = metaSkill.snapshot.epoch
      phases.append(CoreAgentSkillOptimizationRunPhaseRecord(phase: .metaSkillStateRecorded))
    }

    var harvestedIDs: [String] = []
    if let harvested = pendingHarvestEvidence {
      harvestedIDs = harvested.map(\.id)
      evidence = try Self.mergedEvidence(evidence, harvested)
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .harvested,
          harvestedEvidenceCount: harvested.count
        )
      )
    }

    var replayRequestIDs: [String] = []
    var replayEvidenceIDs: [String] = []
    if let replay = request.replay {
      let generator = CoreAgentSkillReplayGenerator()
      let replayRequests = try generator.generate(from: evidence, policy: replay.generationPolicy)
      replayRequestIDs = replayRequests.map(\.id)
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .replayGenerated,
          replayRequestCount: replayRequests.count
        )
      )
      if !replayRequests.isEmpty {
        let executor = CoreAgentSkillReplayExecutor(
          backend: replay.backend,
          policy: replay.executionPolicy
        )
        let replayEvidence = try await executor.execute(replayRequests)
        replayEvidenceIDs = replayEvidence.map(\.id)
        evidence = try Self.mergedEvidence(evidence, replayEvidence)
        phases.append(
          CoreAgentSkillOptimizationRunPhaseRecord(
            phase: .replayExecuted,
            replayEvidenceCount: replayEvidence.count
          )
        )
      }
    }

    var importedMemoryEntryIDs: [String] = []
    if let memory = request.memory {
      let evidenceDigestKeys = evidence.flatMap { [$0.transcriptDigest, $0.toolEventDigest] }
      let references = try await memory.adapter.fetchReferences(
        CoreAgentSkillRSIMemoryFetchRequest(
          runID: request.runID,
          skillID: memory.skillID,
          evidenceDigestKeys: evidenceDigestKeys,
          maxEntries: memory.maxEntries
        )
      )
      let importReport = try await CoreAgentSkillRSIMemoryImporter(store: store).importReferences(
        references,
        runID: request.runID,
        skillID: memory.skillID
      )
      importedMemoryEntryIDs = importReport.importedEntryIDs
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .memoryImported,
          importedMemoryEntryCount: importReport.importedEntryIDs.count
        )
      )
    }

    var generatedProposalIDs: [String] = []
    var allProposals = request.suppliedProposals
    if let proposal = request.proposal {
      let generator = CoreAgentSkillModelProposalGenerator(backend: proposal.backend)
      for target in request.targets {
        guard let skill = await store.currentSkill(id: target.skillID) else {
          throw CoreAgentSkillOptimizationError.missingSkill(target.skillID)
        }
        let generated = try await generator.generate(
          runID: request.runID,
          skill: skill,
          baselineScore: target.baselineScore,
          evidence: evidence,
          policy: request.policy,
          maxProposals: proposal.maxProposals
        )
        generatedProposalIDs.append(contentsOf: generated.map(\.id))
        allProposals.append(contentsOf: generated)
      }
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .proposalsGenerated,
          proposalCount: generatedProposalIDs.count
        )
      )
    }

    let suppliedProposalIDs = request.suppliedProposals.map(\.id)
    var frontierSelectedProposalIDs: [String] = []
    var frontierRejectedProposalIDs: [String] = []
    if let frontier = request.frontier {
      let selection = try CoreAgentSkillMetaEvolutionFrontierSelector().select(
        proposals: allProposals,
        scores: frontier.scores,
        policy: frontier.policy
      )
      frontierSelectedProposalIDs = selection.selected.map(\.id)
      frontierRejectedProposalIDs = selection.rejectedProposalIDs
      allProposals = selection.selected
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .frontierSelected,
          proposalCount: frontierSelectedProposalIDs.count,
          rejectedProposalCount: frontierRejectedProposalIDs.count
        )
      )
    }
    var sleepReport: CoreAgentSkillSleepOptimizationReport?
    if !allProposals.isEmpty {
      sleepReport = try await CoreAgentSkillSleepOptimizer(store: store).run(
        CoreAgentSkillSleepOptimizationRequest(
          runID: request.runID,
          proposals: allProposals,
          policy: request.policy
        )
      )
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .sleepOptimized,
          proposalCount: allProposals.count,
          acceptedProposalCount: sleepReport?.acceptedCount ?? 0,
          rejectedProposalCount: sleepReport?.rejectedCount ?? 0
        )
      )
    }
    if let metaSkill = request.metaSkill, let sleepReport {
      let sleepAcceptedProposalIDs = sleepReport.entries.compactMap { entry -> String? in
        entry.decision == .accepted ? entry.proposalID : nil
      }
      let sleepRejectedProposalIDs = sleepReport.entries.compactMap { entry -> String? in
        if case .rejected = entry.decision {
          return entry.proposalID
        }
        return nil
      }
      let rejectedProposalIDs = orderedUnique(
        frontierRejectedProposalIDs + sleepRejectedProposalIDs
      )
      try await store.recordMetaSkillEvolution(
        CoreAgentSkillMetaSkillEvolutionRecord(
          runID: request.runID,
          branchID: metaSkill.snapshot.branchID,
          previousEpoch: metaSkill.previousEpoch,
          nextEpoch: metaSkill.snapshot.epoch,
          acceptedProposalIDs: sleepAcceptedProposalIDs,
          rejectedProposalIDs: rejectedProposalIDs,
          frontierRejectedProposalIDs: frontierRejectedProposalIDs,
          sleepAcceptedProposalIDs: sleepAcceptedProposalIDs,
          sleepRejectedProposalIDs: sleepRejectedProposalIDs,
          evidenceDigest: Self.metaSkillEvolutionEvidenceDigest(
            runID: request.runID,
            branchID: metaSkill.snapshot.branchID,
            previousEpoch: metaSkill.previousEpoch,
            nextEpoch: metaSkill.snapshot.epoch,
            frontierRejectedProposalIDs: frontierRejectedProposalIDs,
            sleepAcceptedProposalIDs: sleepAcceptedProposalIDs,
            sleepRejectedProposalIDs: sleepRejectedProposalIDs
          )
        ),
        skillID: metaSkill.skillID
      )
      metaSkillEvolutionRecordCount = 1
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .metaSkillEvolved,
          acceptedProposalCount: sleepAcceptedProposalIDs.count,
          rejectedProposalCount: rejectedProposalIDs.count,
          metaSkillEvolutionRecordCount: 1
        )
      )
    }

    return CoreAgentSkillOptimizationRunReport(
      runID: request.runID,
      seedEvidenceIDs: seedEvidenceIDs,
      harvestedEvidenceIDs: harvestedIDs,
      replayRequestIDs: replayRequestIDs,
      replayEvidenceIDs: replayEvidenceIDs,
      generatedProposalIDs: generatedProposalIDs,
      suppliedProposalIDs: suppliedProposalIDs,
      importedMemoryEntryIDs: importedMemoryEntryIDs,
      frontierSelectedProposalIDs: frontierSelectedProposalIDs,
      frontierRejectedProposalIDs: frontierRejectedProposalIDs,
      metaSkillBranchID: metaSkillBranchID,
      metaSkillEpoch: metaSkillEpoch,
      metaSkillEvolutionRecordCount: metaSkillEvolutionRecordCount,
      sleepReport: sleepReport,
      phases: phases
    )
  }

  private static func validate(
    _ request: CoreAgentSkillOptimizationRunRequest,
    engineStoreConfigured: Bool
  ) throws {
    guard !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "optimization run ID must be non-empty"
      )
    }
    if request.harvest != nil, !engineStoreConfigured {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "harvest config requires engineStore on executor"
      )
    }
    if request.proposal != nil, request.targets.isEmpty {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal generation requires at least one optimization target"
      )
    }
    if let metaSkill = request.metaSkill, metaSkill.previousEpoch < 0 {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill evolution previous epoch must be non-negative"
      )
    }
    for target in request.targets {
      guard target.baselineScore.isFinite,
        target.baselineScore >= 0,
        target.baselineScore <= 1
      else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(target.baselineScore)
      }
    }
    _ = try dedupedEvidence(request.seedEvidence)
    var seenProposalIDs: Set<String> = []
    for proposal in request.suppliedProposals {
      guard seenProposalIDs.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private static func metaSkillEvolutionEvidenceDigest(
    runID: String,
    branchID: String,
    previousEpoch: Int,
    nextEpoch: Int,
    frontierRejectedProposalIDs: [String],
    sleepAcceptedProposalIDs: [String],
    sleepRejectedProposalIDs: [String]
  ) -> String {
    let payload = [
      "run=\(runID)",
      "branch=\(branchID)",
      "previous=\(previousEpoch)",
      "next=\(nextEpoch)",
      "frontierRejected=\(frontierRejectedProposalIDs.joined(separator: ","))",
      "sleepAccepted=\(sleepAcceptedProposalIDs.joined(separator: ","))",
      "sleepRejected=\(sleepRejectedProposalIDs.joined(separator: ","))",
    ].joined(separator: "\n")
    return "sha256:\(sha256Hex(Data(payload.utf8)))"
  }

  private static func dedupedEvidence(
    _ evidence: [CoreAgentSkillRolloutEvidence]
  ) throws -> [CoreAgentSkillRolloutEvidence] {
    var seen: Set<String> = []
    var result: [CoreAgentSkillRolloutEvidence] = []
    for item in evidence {
      guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "evidence ID must be non-empty"
        )
      }
      guard seen.insert(item.id).inserted else { continue }
      result.append(item)
    }
    return result
  }

  private static func mergedEvidence(
    _ existing: [CoreAgentSkillRolloutEvidence],
    _ incoming: [CoreAgentSkillRolloutEvidence]
  ) throws -> [CoreAgentSkillRolloutEvidence] {
    var seen = Set(existing.map(\.id))
    var merged = existing
    for item in incoming {
      guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "evidence ID must be non-empty"
        )
      }
      guard seen.insert(item.id).inserted else { continue }
      merged.append(item)
    }
    return merged
  }
}

private func orderedUnique(_ values: [String]) -> [String] {
  var seen: Set<String> = []
  var result: [String] = []
  for value in values where seen.insert(value).inserted {
    result.append(value)
  }
  return result
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
