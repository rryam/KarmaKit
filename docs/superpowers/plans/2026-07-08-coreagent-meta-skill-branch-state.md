# CoreAgent Meta-Skill Branch State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add typed branch-local meta-skill state for MetaSkill-Evolve-style RSI without introducing an autonomous scheduler or bypassing existing SkillOpt mutation gates.

**Status:** Implemented and verified. The slice adds typed branch snapshots,
typed evolution records, run-executor meta-skill audit phases, explicit
frontier-vs-sleep proposal buckets, corrupt-store coverage, and legacy
optimizer-memory decode coverage. Repo-wide swift-format lint still fails on
pre-existing files outside this slice; touched-file lint passes.

**Architecture:** Store branch-local meta-skill snapshots and evolution records inside `CoreAgentSkillOptimizerMemory`, keyed by skill ID and validated before persistence. `CoreAgentSkillOptimizationRunExecutor` may record a snapshot before proposal/frontier/sleep work and record an evolution audit after sleep, but it cannot mutate skills through meta-skill state; skill edits still flow through proposals and `CoreAgentSkillSleepOptimizer`.

**Tech Stack:** Swift 6.4, Swift Testing, existing `CoreAgentSkills` target, no new dependencies.

## Global Constraints

- Preserve FoundationModels-native/CoreAgent-native contracts; do not vendor MetaSkill-Evolve Python code.
- Store only typed metadata and lowercase SHA-256 digests, not raw prompts, transcripts, branch payloads, or evaluator prose.
- Branch-local meta-skill state is optimizer memory, not user memory and not CoreAgentMemory.
- The scheduler/daemon cadence remains host-owned; this slice only adds state and run audit hooks.
- Use TDD: failing tests before production code.

---

## File Structure

- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`
  - Add typed meta-skill role/component/snapshot/evolution record types.
  - Add optimizer-memory fields and store mutation methods for snapshots/evolution records.
  - Add optional optimization-run meta-skill config, report fields, and phases.
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`
  - Add focused Swift Testing coverage near existing RSI/frontier tests.
- Modify: `Documentation/CoreAgentSkills-Runtime.md`
  - Document branch-local meta-skill state and host-owned scheduler boundary.
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
  - Add L47 status after verification.
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`
  - Move MetaSkill-Evolve from only queued assessment to first implemented branch-state mapping.

## Task 1: Red Tests for Typed Meta-Skill Memory

**Files:**
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`

**Interfaces:**
- Produces expected future API:
  - `CoreAgentSkillMetaSkillComponent`
  - `CoreAgentSkillMetaSkillBranchSnapshot`
  - `CoreAgentSkillMetaSkillEvolutionRecord`
  - `CoreAgentSkillStore.recordMetaSkillSnapshot(_:skillID:)`
  - `CoreAgentSkillStore.recordMetaSkillEvolution(_:skillID:)`

- [ ] **Step 1: Write failing persistence test**

Add `metaSkillBranchStatePersistsTypedComponentsWithoutRawPayloads`:

```swift
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
}
```

- [ ] **Step 2: Run red**

Run: `swift test --skip-update --filter metaSkillBranchStatePersistsTypedComponentsWithoutRawPayloads`

Expected: compile failure because the meta-skill types and store methods do not exist.

## Task 2: Implement Typed Meta-Skill Memory

**Files:**
- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`

**Interfaces:**
- Produces:
  - `CoreAgentSkillMetaSkillComponent`
  - `CoreAgentSkillMetaSkillBranchSnapshot`
  - `CoreAgentSkillMetaSkillEvolutionRecord`
  - `CoreAgentSkillOptimizerMemory.metaSkillSnapshots`
  - `CoreAgentSkillOptimizerMemory.metaSkillEvolutionRecords`
  - `CoreAgentSkillStore.recordMetaSkillSnapshot(_:skillID:)`
  - `CoreAgentSkillStore.recordMetaSkillEvolution(_:skillID:)`

- [ ] **Step 1: Add data types near optimizer memory types**

Use `Codable`, `Equatable`, and `Sendable`.

```swift
public struct CoreAgentSkillMetaSkillComponent: Codable, Equatable, Sendable {
  public let componentDigest: String
  public let policyVersion: String
}

public struct CoreAgentSkillMetaSkillBranchSnapshot: Codable, Equatable, Sendable {
  public let branchID: String
  public let parentBranchID: String?
  public let epoch: Int
  public let analyzer: CoreAgentSkillMetaSkillComponent
  public let retriever: CoreAgentSkillMetaSkillComponent
  public let allocator: CoreAgentSkillMetaSkillComponent
  public let proposer: CoreAgentSkillMetaSkillComponent
  public let evolver: CoreAgentSkillMetaSkillComponent
  public let objectiveDigest: String
}

public struct CoreAgentSkillMetaSkillEvolutionRecord: Codable, Equatable, Sendable {
  public let runID: String
  public let branchID: String
  public let previousEpoch: Int
  public let nextEpoch: Int
  public let acceptedProposalIDs: [String]
  public let rejectedProposalIDs: [String]
  public let evidenceDigest: String
}
```

- [ ] **Step 2: Add validation**

Fail closed for empty/unsafe branch IDs, unsafe parent branch IDs, negative epochs, stale evolution epochs where `nextEpoch <= previousEpoch`, invalid SHA-256 digests, empty component policy versions, duplicate proposal IDs, unsafe proposal IDs, and duplicate snapshot branch/epoch or evolution run/branch/nextEpoch records.

- [ ] **Step 3: Add store persistence**

Append snapshots/evolution records into optimizer memory for both `InMemoryCoreAgentSkillStore` and `FileCoreAgentSkillStore`. File store must continue failing closed on corrupt optimizer memory.

- [ ] **Step 4: Run green**

Run: `swift test --skip-update --filter metaSkillBranchStatePersistsTypedComponentsWithoutRawPayloads`

Expected: pass.

## Task 3: Red/Green Validation Tests

**Files:**
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`
- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`

- [ ] **Step 1: Add failing validation test**

Add `metaSkillBranchStateRejectsInvalidIdentityDigestAndEpochs`:

```swift
@Test("Meta skill branch state rejects invalid identity digest and epochs")
func metaSkillBranchStateRejectsInvalidIdentityDigestAndEpochs() async throws {
  let skill = Self.skill(id: "rsi-invalid", body: "Body")
  let store = InMemoryCoreAgentSkillStore()
  try await store.save(skill)

  await #expect(throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
    "meta-skill branch ID is invalid"
  )) {
    try await store.recordMetaSkillSnapshot(
      Self.metaSkillSnapshot(branchID: "../branch", epoch: 1),
      skillID: skill.id
    )
  }

  await #expect(throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
    "meta-skill component digest must be lowercase sha256"
  )) {
    try await store.recordMetaSkillSnapshot(
      Self.metaSkillSnapshot(branchID: "branch-beta", epoch: 1, analyzerDigest: "sha256:BAD"),
      skillID: skill.id
    )
  }

  await #expect(throws: CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
    "meta-skill evolution epoch must advance"
  )) {
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
```

- [ ] **Step 2: Run red**

Run: `swift test --skip-update --filter metaSkillBranchStateRejectsInvalidIdentityDigestAndEpochs`

Expected: fail until validation is implemented.

- [ ] **Step 3: Implement validation**

Add private validation helpers and call them from store record methods.

- [ ] **Step 4: Run green**

Run: `swift test --skip-update --filter metaSkillBranchStateRejectsInvalidIdentityDigestAndEpochs`

Expected: pass.

## Task 4: Optimization Run Integration

**Files:**
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`
- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`

**Interfaces:**
- Produces:
  - `CoreAgentSkillMetaSkillRunConfig`
  - `CoreAgentSkillOptimizationRunRequest.metaSkill`
  - `CoreAgentSkillOptimizationRunPhase.metaSkillStateRecorded`
  - `CoreAgentSkillOptimizationRunPhase.metaSkillEvolved`
  - report fields `metaSkillBranchID`, `metaSkillEpoch`, and `metaSkillEvolutionRecordCount`

- [ ] **Step 1: Add failing run integration test**

Add `optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep`:

```swift
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
  #expect(report.phases.map(\.phase) == [
    .metaSkillStateRecorded,
    .frontierSelected,
    .sleepOptimized,
    .metaSkillEvolved,
  ])
  #expect(memory.metaSkillSnapshots.map(\.branchID) == ["branch-run"])
  #expect(memory.metaSkillEvolutionRecords.first?.acceptedProposalIDs == ["second-productive"])
  #expect(memory.metaSkillEvolutionRecords.first?.rejectedProposalIDs == ["first-hacked"])
}
```

- [ ] **Step 2: Run red**

Run: `swift test --skip-update --filter optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep`

Expected: compile failure until run config, report fields, and phases exist.

- [ ] **Step 3: Implement run integration**

Validate `metaSkill.skillID` exists. Record the snapshot before memory/proposal/frontier/sleep phases. After sleep, record one evolution record using accepted/rejected proposal IDs, selected/rejected frontier IDs, and a deterministic evidence digest derived from the run ID, branch ID, epoch, proposal IDs, and phase IDs. If there is no sleep report, do not record evolution.

- [ ] **Step 4: Run green**

Run: `swift test --skip-update --filter optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep`

Expected: pass.

## Task 5: Documentation and Verification

**Files:**
- Modify: `Documentation/CoreAgentSkills-Runtime.md`
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`

- [x] **Step 1: Document implementation**

Add implemented docs for typed meta-skill branch snapshots/evolution records. State explicitly that no scheduler/daemon is included.

- [x] **Step 2: Update ledger**

Add L47 `complete_for_meta_skill_branch_state` after verification.

- [x] **Step 3: Verify**

Run:

```bash
swift test --skip-update --filter metaSkillBranchState
swift test --skip-update --filter optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep
swift test --skip-update --filter CoreAgentSkillsTests
swift test --skip-update
swift build --skip-update
git diff --check
```

Expected: all pass before claiming L47 complete. Full `swift-format lint --strict --recursive Package.swift Sources Tests` may still fail on existing repo-wide style debt; changed ranges should remain clean.

Actual verification:

- `swift test --skip-update --filter metaSkillBranchState` passed.
- `swift test --skip-update --filter optimizationRunRecordsMetaSkillBranchStateAroundFrontierAndSleep` passed.
- `swift test --skip-update --filter CoreAgentSkillsTests` passed 55 tests.
- `swift test --skip-update` passed.
- `swift build --skip-update` passed.
- `git diff --check` passed.
- `xcrun swift-format lint --strict Sources/CoreAgentSkills/CoreAgentSkills.swift Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift` passed.
- `xcrun swift-format lint --strict --recursive Package.swift Sources Tests` still fails on pre-existing repo-wide style debt in files outside this slice.

## Self-Review

- Spec coverage: covers branch-local meta-skill state and two-timescale audit hooks; does not implement a production scheduler, branch allocator, or autonomous recursive loop.
- Placeholder scan: no TODO/TBD placeholders.
- Type consistency: planned names match existing `CoreAgentSkill...` namespace and current optimization-run structure.
