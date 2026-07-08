I'll review this Swift 6.4 CoreAgent SkillOpt slice against the contract and scope requirements.

**Reading the incomplete source file to understand the sleep optimizer implementation:**

The `CoreAgentSkillSleepOptimizer` struct is declared but the implementation is cut off. Let me analyze what's provided and the test expectations.

## Critical Issues Found

**BLOCK** — Multiple concrete correctness issues:

### 1. **Incomplete Implementation (Missing `run` method)**
The `CoreAgentSkillSleepOptimizer` struct (line ~520) is declared but the `run` method implementation is truncated. The test `sleepOptimizerEnforcesLearningRateSplitAndProtectedRegionPolicy` calls `sleepOptimizer.run(...)` and expects:
- Edit budget enforcement (reject if `candidateEdits.count > maxEditsPerProposal`)
- Held-out split leakage detection (reject if validation suite is in `trainingSuiteIDs`)
- Protected region mutation detection (reject if edits target protected regions)
- Duplicate proposal ID detection before any mutations
- Meta-observation recording for rejections

Without the implementation, the test cannot pass, and the contract obligations are unmet.

### 2. **Protected Region Mutation Detection Not Implemented**
The test expects rejection of edits that target text within protected regions (between `startMarker` and `endMarker`). The `CoreAgentSkillEdit.apply()` method (line ~190) performs text replacement without checking whether the target overlaps a protected region. The `CoreAgentSkillProtectedRegion` struct exists but is never used for validation.

### 3. **Held-Out Split Leakage Not Enforced**
The test expects rejection when `validation.heldoutSuiteID` is in `policy.trainingSuiteIDs`. The current `CoreAgentSkillOptimizer.propose()` method (line ~463) has no split-validation logic—it only checks `validation.passed` and score improvement. This bypasses the validation gate contract.

### 4. **Edit Budget Not Validated**
The test expects rejection when `candidateEdits.count > policy.maxEditsPerProposal`. Neither `CoreAgentSkillOptimizer.propose()` nor the incomplete `CoreAgentSkillSleepOptimizer` validates this constraint before applying edits.

### 5. **Duplicate Proposal ID Detection Missing**
The test `sleepOptimizerRejectsDuplicateProposalIDsBeforeMutatingSkills` expects the sleep optimizer to reject duplicate proposal IDs *before* any skill mutations occur. Without the `run` implementation, this contract enforcement is missing.

### 6. **Evidence Tracking Missing**
The test expects `report.entries.last?.evidenceIDs == ["trace-a"]`, but there is no mechanism to associate `CoreAgentSkillRolloutEvidence` from the proposal with the result entry. The `CoreAgentSkillSleepOptimizationEntry` struct includes `evidenceIDs` but nothing populates it.

## Secondary Observations

- `InMemoryCoreAgentSkillStore.recordRejected` and `recordMetaObservation` (lines ~380–400) are `internal` (not `public`), making them inaccessible from the sleep optimizer unless it's in the same module—verify this doesn't break the design.
- `CoreAgentSkillOptimizer.propose()` accepts a proposal but never validates `maxEditsPerProposal` or checks for split leakage; policy enforcement is entirely absent.

**Recommendation:** Complete the `CoreAgentSkillSleepOptimizer.run()` implementation with:
1. Early duplicate proposal ID check (before any store mutations)
2. Per-proposal validation: edit budget, split leakage, protected region integrity
3. Evidence ID collection and recording
4. Meta-observation recording for rejections
5. Halt on first constraint violation (e.g., `duplicateOptimizationProposal` before processing any proposals)
