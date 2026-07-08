# CoreAgent RSI Meta-Evolution Frontier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a typed CoreAgentSkills frontier selector for MetaSkill-Evolve/RQGM-style RSI proposal selection without vendoring research prototypes or bypassing the existing sleep-optimizer trust boundary.

**Architecture:** Insert a pure selector between assembled `CoreAgentSkillSleepOptimizationProposal` values and `CoreAgentSkillSleepOptimizer.run`. The selector may filter and order proposals using productivity, novelty, strict/loose evaluator scores, hack-ratio, and optional objective scores, but all mutation still runs through `CoreAgentSkillSleepOptimizer`.

**Tech Stack:** Swift 6.4, Swift Testing, existing `CoreAgentSkills` target, no new dependencies.

## Global Constraints

- Preserve CoreAgent's Foundation Models-native boundaries; do not add provider/message abstractions.
- No brittle provider payload assumptions, phrase checks, or one-run artifact contracts.
- No production scheduler, daemon, network calls, or vendored Python research code.
- Use TDD: failing tests before production code.
- Keep current user memory separate from optimizer/meta-skill memory.
- Selector output can reorder/filter proposals only; it cannot mutate skills or apply edits.

---

## File Structure

- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`
  - Add meta-evolution frontier policy, score, selection, selector, optional optimization-run config, and phase/report fields.
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`
  - Add focused Swift Testing coverage near existing model-proposal/orchestrator tests.
- Modify: `Documentation/CoreAgentSkills-Runtime.md`
  - Document the selector and non-scheduler boundary.
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
  - Convert L46 from planned assessment to complete-for-frontier-selector after verification.

## Task 1: Red Test for Standalone Frontier Selection

**Files:**
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`

**Interfaces:**
- Consumes: `CoreAgentSkillSleepOptimizationProposal`.
- Produces expected future API:
  - `CoreAgentSkillMetaEvolutionFrontierPolicy`
  - `CoreAgentSkillMetaEvolutionFrontierScore`
  - `CoreAgentSkillMetaEvolutionFrontierSelection`
  - `CoreAgentSkillMetaEvolutionFrontierSelector.select(...)`

- [x] **Step 1: Write failing test**

Add `metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically`:

```swift
@Test("Meta evolution frontier selector filters hack ratio and ranks deterministically")
func metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically() throws {
  let proposals = [
    Self.sleepProposal(id: "stable", skillID: "swift", score: 0.72),
    Self.sleepProposal(id: "productive", skillID: "swift", score: 0.70),
    Self.sleepProposal(id: "hacked", skillID: "swift", score: 0.96),
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
```

- [x] **Step 2: Run red**

Run: `swift test --skip-update --filter metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically`

Expected: compile failure because frontier selector types do not exist.

## Task 2: Implement Standalone Selector

**Files:**
- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`

**Interfaces:**
- Produces:
  - `CoreAgentSkillMetaEvolutionFrontierPolicy`
  - `CoreAgentSkillMetaEvolutionFrontierScore`
  - `CoreAgentSkillMetaEvolutionFrontierSelection`
  - `CoreAgentSkillMetaEvolutionFrontierSelector`

- [x] **Step 1: Add data types near harness optimizer types**

Use `Codable`, `Equatable`, and `Sendable` where useful. Policy fields:

```swift
maxSelectedProposals: Int
productivityWeight: Double
noveltyWeight: Double
strictScoreWeight: Double
looseScoreWeight: Double
minimumNoveltyScore: Double?
maximumHackRatio: Double?
```

- [x] **Step 2: Add score calculation**

Normalize hack ratio as `looseScore / max(strictScore, 0.0001)`. Sort audit by raw score descending, then proposal ID ascending. Filter selected proposals by policy gates and cap to `maxSelectedProposals`.

- [x] **Step 3: Validate inputs**

Fail closed for duplicate proposal IDs, duplicate score IDs, unknown score IDs, missing scores, invalid proposal IDs, invalid non-finite/out-of-range scores, invalid weights, invalid gates, and invalid max selection.

- [x] **Step 4: Run green**

Run: `swift test --skip-update --filter metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically`

Expected: pass.

## Task 3: Red/Green Orchestrator Integration

**Files:**
- Modify: `Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift`
- Modify: `Sources/CoreAgentSkills/CoreAgentSkills.swift`

- [x] **Step 1: Add failing orchestrator test**

Add `optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep`:
- create two supplied proposals where the worse proposal would otherwise be first,
- pass frontier scores that select only the second,
- assert sleep receives/selects the scored proposal,
- assert phases include `frontierSelected` before `sleepOptimized`,
- assert report includes selected and rejected frontier proposal IDs.

- [x] **Step 2: Run red**

Run: `swift test --skip-update --filter optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep`

Expected: compile failure or missing behavior.

- [x] **Step 3: Implement config and run wiring**

Add:

```swift
public struct CoreAgentSkillMetaEvolutionFrontierConfig: Sendable {
  public let scores: [CoreAgentSkillMetaEvolutionFrontierScore]
  public let policy: CoreAgentSkillMetaEvolutionFrontierPolicy
}
```

Add `frontier: CoreAgentSkillMetaEvolutionFrontierConfig?` to `CoreAgentSkillOptimizationRunRequest`, `frontierSelected` to phases, and selected/rejected IDs to report.

- [x] **Step 4: Run green**

Run: `swift test --skip-update --filter optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep`

Expected: pass.

## Task 4: Documentation and Verification

**Files:**
- Modify: `Documentation/CoreAgentSkills-Runtime.md`
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`

- [x] **Step 1: Document implementation**

Add the frontier selector to implemented Skills runtime and keep scheduler/runtime host ownership explicit.

- [x] **Step 2: Update ledger**

Change L46 to `complete_for_meta_evolution_frontier_selector` after tests pass.

- [x] **Step 3: Verify**

Run:

```bash
swift test --skip-update --filter metaEvolutionFrontier
swift test --skip-update --filter CoreAgentSkillsTests
swift build --skip-update
git diff --check
```

Expected: all pass before claiming this slice complete.

Actual verification on 2026-07-07:

- Red evidence:
  - `swift test --skip-update --filter metaEvolutionFrontierSelectorFiltersHackRatioAndRanksDeterministically` failed before selector types existed.
  - `swift test --skip-update --filter metaEvolutionFrontierSelectorRejectsInvalidObjectiveEvidence` failed before objective score validation rejected invalid values.
  - `swift test --skip-update --filter optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep` failed before the run request exposed `frontier` and `frontierSelected`.
- Green evidence:
  - `swift test --skip-update --filter metaEvolutionFrontier` passed.
  - `swift test --skip-update --filter optimizationRunOrchestratorAppliesMetaEvolutionFrontierBeforeSleep` passed.
  - `swift test --skip-update --filter CoreAgentSkillsTests` passed 50 tests.
  - `swift test --skip-update` passed for the full package.
  - `swift build --skip-update` passed.
  - `git diff --check` passed.
  - `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`
    still fails on repo-wide pre-existing style debt; the formatter config schema
    was corrected, and filtered lint over this slice's changed ranges is clean.

## Self-Review

- Spec coverage: covers MetaSkill-Evolve productivity/novelty and RQGM strict/loose hack-ratio gates, but not production scheduling.
- Placeholder scan: no TODO/TBD placeholders.
- Type consistency: all names in tests are defined in planned interfaces.
