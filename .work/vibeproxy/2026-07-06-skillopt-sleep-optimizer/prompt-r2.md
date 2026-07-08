You are reviewing a Swift 6.4 CoreAgent SkillOpt slice. Return one of:

PASS: no blocking correctness/security/API issues found
BLOCK: at least one concrete issue that should be fixed before treating this slice as done

Scope: CoreAgentSkills sleep/recursive optimization loop only. Review for brittle SkillOpt contracts, validation-gate bypass, heldout split leakage, unbounded edit drift, protected slow-update mutation, concurrency/API issues, and tests that assert incidental behavior. Do not block on missing concrete App Intents, OS sandbox backends, model-powered edit proposer, or file-backed skill store; those are future slices.

Relevant latest SkillOpt contract from Microsoft primary docs: skill docs are trainable external state for frozen agents; rollouts feed reflection; edits are bounded text changes; candidates are accepted only through held-out validation gates; rejected-edit buffers plus slow/meta updates prevent prompt drift; export remains a best_skill.md artifact.

Relevant local verification already run: swift test --skip-update --filter CoreAgentSkillsTests passed 10 tests after the red failure on missing sleep optimizer symbols.

--- Sources/CoreAgentSkills/CoreAgentSkills.swift ---
import CoreAgent
import Foundation

public struct CoreAgentSkillID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

public struct CoreAgentSkill: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentSkillID
  public let version: Int
  public let title: String
  public let body: String
  public let tags: [String]
  public let priority: Int
  public let provenance: [CoreAgentSkillProvenance]

  public init(
    id: CoreAgentSkillID,
    version: Int,
    title: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0,
    provenance: [CoreAgentSkillProvenance] = []
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.body = body
    self.tags = tags
    self.priority = priority
    self.provenance = provenance
  }
}

public struct CoreAgentSkillProvenance: Codable, Equatable, Sendable {
  public let acceptedAt: Date
  public let heldoutSuiteID: String
  public let validationScore: Double
  public let notes: String

  public init(
    acceptedAt: Date = Date(),
    heldoutSuiteID: String,
    validationScore: Double,
    notes: String
  ) {
    self.acceptedAt = acceptedAt
    self.heldoutSuiteID = heldoutSuiteID
    self.validationScore = validationScore
    self.notes = notes
  }
}

public struct CoreAgentSkillValidationResult: Codable, Equatable, Sendable {
  public let score: Double
  public let heldoutSuiteID: String
  public let passed: Bool
  public let notes: String

  public init(score: Double, heldoutSuiteID: String, passed: Bool, notes: String) {
    self.score = score
    self.heldoutSuiteID = heldoutSuiteID
    self.passed = passed
    self.notes = notes
  }
}

public struct CoreAgentSkillRolloutEvidence: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let taskID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let verifierFeedback: String
  public let score: Double
  public let metadata: [String: String]

  public init(
    id: String,
    taskID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    verifierFeedback: String,
    score: Double,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.taskID = taskID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.verifierFeedback = verifierFeedback
    self.score = score
    self.metadata = metadata
  }
}

public enum CoreAgentSkillEdit: Codable, Equatable, Sendable {
  case replace(target: String, replacement: String)
  case append(String)

  public func apply(to body: String) throws -> String {
    switch self {
    case .append(let addition):
      return body + addition
    case .replace(let target, let replacement):
      guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyReplacementTarget
      }
      let parts = body.components(separatedBy: target)
      guard parts.count == 2 else {
        throw CoreAgentSkillOptimizationError.replacementTargetNotUnique(target)
      }
      return parts[0] + replacement + parts[1]
    }
  }
}

public enum CoreAgentSkillOptimizationError: Error, Equatable, Sendable {
  case missingSkill(CoreAgentSkillID)
  case emptyReplacementTarget
  case replacementTargetNotUnique(String)
  case missingHarnessEvaluation(String)
  case versionCollision(CoreAgentSkillID, Int)
  case duplicateHarnessCandidate(String)
  case duplicateOptimizationProposal(String)
  case invalidOptimizationPolicy(String)
}

public struct CoreAgentSkillOptimizationProposal: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double
  public let candidateEdits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    skillID: CoreAgentSkillID,
    baselineScore: Double,
    candidateEdits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.skillID = skillID
    self.baselineScore = baselineScore
    self.candidateEdits = candidateEdits
    self.validation = validation
  }
}

public struct CoreAgentSkillOptimizationResult: Equatable, Sendable {
  public let accepted: Bool
  public let skill: CoreAgentSkill
  public let validation: CoreAgentSkillValidationResult
}

public struct CoreAgentRejectedSkillEdit: Codable, Equatable, Sendable {
  public let proposedAt: Date
  public let edits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    proposedAt: Date = Date(),
    edits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.proposedAt = proposedAt
    self.edits = edits
    self.validation = validation
  }
}

public enum CoreAgentSkillOptimizationRejectionReason:
  String, Codable, Equatable, Sendable
{
  case editBudgetExceeded
  case heldoutSplitLeakage
  case protectedRegionMutation
  case validationDidNotImprove
  case maxAcceptedProposalsReached
}

public struct CoreAgentSkillMetaObservation: Codable, Equatable, Sendable {
  public let observedAt: Date
  public let runID: String
  public let proposalID: String
  public let reason: CoreAgentSkillOptimizationRejectionReason
  public let notes: String

  public init(
    observedAt: Date = Date(),
    runID: String,
    proposalID: String,
    reason: CoreAgentSkillOptimizationRejectionReason,
    notes: String
  ) {
    self.observedAt = observedAt
    self.runID = runID
    self.proposalID = proposalID
    self.reason = reason
    self.notes = notes
  }
}

public struct CoreAgentSkillOptimizerMemory: Codable, Equatable, Sendable {
  public var rejectedEdits: [CoreAgentRejectedSkillEdit]
  public var metaObservations: [CoreAgentSkillMetaObservation]

  public init(
    rejectedEdits: [CoreAgentRejectedSkillEdit] = [],
    metaObservations: [CoreAgentSkillMetaObservation] = []
  ) {
    self.rejectedEdits = rejectedEdits
    self.metaObservations = metaObservations
  }
}

public actor InMemoryCoreAgentSkillStore {
  private var historyByID: [CoreAgentSkillID: [CoreAgentSkill]] = [:]
  private var memoryByID: [CoreAgentSkillID: CoreAgentSkillOptimizerMemory] = [:]

  public init() {}

  public func save(_ skill: CoreAgentSkill) async throws {
    if historyByID[skill.id, default: []].contains(where: { $0.version == skill.version }) {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    historyByID[id]?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    historyByID.values
      .compactMap { $0.max { $0.version < $1.version } }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  }

  func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID) {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.rejectedEdits.append(rejected)
    memoryByID[skillID] = memory
  }

  func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.metaObservations.append(observation)
    memoryByID[skillID] = memory
  }
}

public struct CoreAgentSkillCurationQuery: Sendable {
  public let tags: Set<String>
  public let maxCharacters: Int

  public init(tags: Set<String>, maxCharacters: Int) {
    self.tags = tags
    self.maxCharacters = maxCharacters
  }

  public init(tags: [String], maxCharacters: Int) {
    self.init(tags: Set(tags), maxCharacters: maxCharacters)
  }
}

public struct CoreAgentSkillCurator: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func curate(query: CoreAgentSkillCurationQuery) async -> [CoreAgentSkill] {
    var remaining = max(0, query.maxCharacters)
    var selected: [CoreAgentSkill] = []
    for skill in await store.allCurrentSkills() {
      guard !Set(skill.tags).isDisjoint(with: query.tags) else { continue }
      guard skill.body.count <= remaining else { continue }
      selected.append(skill)
      remaining -= skill.body.count
    }
    return selected
  }
}

public struct CoreAgentSkillOptimizer: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal
  ) async throws -> CoreAgentSkillOptimizationResult {
    guard let current = await store.currentSkill(id: proposal.skillID) else {
      throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
    }
    var candidateBody = current.body
    for edit in proposal.candidateEdits {
      candidateBody = try edit.apply(to: candidateBody)
    }

    guard proposal.validation.passed,
      proposal.validation.score > proposal.baselineScore
    else {
      await store.recordRejected(
        CoreAgentRejectedSkillEdit(
          edits: proposal.candidateEdits,
          validation: proposal.validation
        ),
        skillID: proposal.skillID
      )
      return CoreAgentSkillOptimizationResult(
        accepted: false,
        skill: current,
        validation: proposal.validation
      )
    }

    let next = CoreAgentSkill(
      id: current.id,
      version: current.version + 1,
      title: current.title,
      body: candidateBody,
      tags: current.tags,
      priority: current.priority,
      provenance: current.provenance + [
        CoreAgentSkillProvenance(
          heldoutSuiteID: proposal.validation.heldoutSuiteID,
          validationScore: proposal.validation.score,
          notes: proposal.validation.notes
        )
      ]
    )
    try await store.save(next)
    return CoreAgentSkillOptimizationResult(
      accepted: true,
      skill: next,
      validation: proposal.validation
    )
  }
}

public struct CoreAgentSkillProtectedRegion: Codable, Equatable, Sendable {
  public let name: String
  public let startMarker: String
  public let endMarker: String

  public init(name: String, startMarker: String, endMarker: String) {
    self.name = name
    self.startMarker = startMarker
    self.endMarker = endMarker
  }

  public static let skillOptSlowUpdate = CoreAgentSkillProtectedRegion(
    name: "skillopt-slow-update",
    startMarker: "<!-- coreagent-slow-update:start -->",
    endMarker: "<!-- coreagent-slow-update:end -->"
  )
}

public struct CoreAgentSkillOptimizationPolicy: Codable, Equatable, Sendable {
  public let maxEditsPerProposal: Int
  public let maxAcceptedProposalsPerRun: Int
  public let minimumScoreDelta: Double
  public let trainingSuiteIDs: Set<String>
  public let protectedRegions: [CoreAgentSkillProtectedRegion]

  public init(
    maxEditsPerProposal: Int = 3,
    maxAcceptedProposalsPerRun: Int = 1,
    minimumScoreDelta: Double = 0,
    trainingSuiteIDs: Set<String> = [],
    protectedRegions: [CoreAgentSkillProtectedRegion] = []
  ) {
    self.maxEditsPerProposal = maxEditsPerProposal
    self.maxAcceptedProposalsPerRun = maxAcceptedProposalsPerRun
    self.minimumScoreDelta = minimumScoreDelta
    self.trainingSuiteIDs = trainingSuiteIDs
    self.protectedRegions = protectedRegions
  }

  func validate() throws {
    guard maxEditsPerProposal > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditsPerProposal must be positive"
      )
    }
    guard maxAcceptedProposalsPerRun > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxAcceptedProposalsPerRun must be positive"
      )
    }
    guard minimumScoreDelta >= 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "minimumScoreDelta must be non-negative"
      )
    }
  }
}

public struct CoreAgentSkillSleepOptimizationProposal: Sendable {
  public let id: String
  public let evidence: [CoreAgentSkillRolloutEvidence]
  public let proposal: CoreAgentSkillOptimizationProposal

  public init(
    id: String,
    evidence: [CoreAgentSkillRolloutEvidence] = [],
    proposal: CoreAgentSkillOptimizationProposal
  ) {
    self.id = id
    self.evidence = evidence
    self.proposal = proposal
  }
}

public struct CoreAgentSkillSleepOptimizationRequest: Sendable {
  public let runID: String
  public let proposals: [CoreAgentSkillSleepOptimizationProposal]
  public let policy: CoreAgentSkillOptimizationPolicy

  public init(
    runID: String,
    proposals: [CoreAgentSkillSleepOptimizationProposal],
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy()
  ) {
    self.runID = runID
    self.proposals = proposals
    self.policy = policy
  }
}

public enum CoreAgentSkillOptimizationDecision: Equatable, Sendable {
  case accepted
  case rejected(CoreAgentSkillOptimizationRejectionReason)
}

public struct CoreAgentSkillSleepOptimizationEntry: Equatable, Sendable {
  public let proposalID: String
  public let skillID: CoreAgentSkillID
  public let decision: CoreAgentSkillOptimizationDecision
  public let skillVersionBefore: Int
  public let skillVersionAfter: Int?
  public let baselineScore: Double
  public let validation: CoreAgentSkillValidationResult
  public let evidenceIDs: [String]

  public init(
    proposalID: String,
    skillID: CoreAgentSkillID,
    decision: CoreAgentSkillOptimizationDecision,
    skillVersionBefore: Int,
    skillVersionAfter: Int?,
    baselineScore: Double,
    validation: CoreAgentSkillValidationResult,
    evidenceIDs: [String]
  ) {
    self.proposalID = proposalID
    self.skillID = skillID
    self.decision = decision
    self.skillVersionBefore = skillVersionBefore
    self.skillVersionAfter = skillVersionAfter
    self.baselineScore = baselineScore
    self.validation = validation
    self.evidenceIDs = evidenceIDs
  }
}

public struct CoreAgentSkillSleepOptimizationReport: Equatable, Sendable {
  public let runID: String
  public let entries: [CoreAgentSkillSleepOptimizationEntry]

  public init(runID: String, entries: [CoreAgentSkillSleepOptimizationEntry]) {
    self.runID = runID
    self.entries = entries
  }

  public var acceptedCount: Int {
    entries.filter { $0.decision == .accepted }.count
  }

  public var rejectedCount: Int {
    entries.count - acceptedCount
  }
}

public struct CoreAgentSkillSleepOptimizer: Sendable {
  private let store: InMemoryCoreAgentSkillStore
  private let optimizer: CoreAgentSkillOptimizer

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store

--- Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift ---
import CoreAgentSkills
import Foundation
import Testing

@Suite("CoreAgentSkills SkillOpt foundation")
struct CoreAgentSkillsTests {
  @Test("Curates skills by tags priority and context budget")
  func curatesSkillsByTagsPriorityAndContextBudget() async throws {
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(Self.skill(id: "planner", body: "Plan carefully.", tags: ["planning"], priority: 10))
    try await store.save(Self.skill(id: "swift", body: "Use Swift Testing.", tags: ["swift"], priority: 20))
    try await store.save(Self.skill(id: "long", body: String(repeating: "x", count: 200), tags: ["swift"], priority: 30))

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
    #expect(report.entries.map(\.proposalID) == [
      "too-many-edits",
      "split-leak",
      "slow-region-edit",
      "accepted",
    ])
    #expect(report.entries.map(\.decision) == [
      .rejected(.editBudgetExceeded),
      .rejected(.heldoutSplitLeakage),
      .rejected(.protectedRegionMutation),
      .accepted,
    ])
    #expect(report.entries.last?.evidenceIDs == ["trace-a"])
    #expect(memory.rejectedEdits.count == 3)
    #expect(memory.metaObservations.map(\.proposalID) == [
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

    await #expect(throws: CoreAgentSkillOptimizationError.duplicateOptimizationProposal("duplicate")) {
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

  @Test("Whitespace-only replacement targets are rejected")
  func whitespaceOnlyReplacementTargetsAreRejected() throws {
    #expect(throws: CoreAgentSkillOptimizationError.emptyReplacementTarget) {
      _ = try CoreAgentSkillEdit.replace(target: "   ", replacement: "new").apply(
        to: "old value"
      )
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
}
