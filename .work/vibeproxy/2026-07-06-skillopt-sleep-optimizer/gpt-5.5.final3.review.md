BLOCK: sleep optimizer can still partially mutate before a later malformed edit aborts the run.

Concrete issue: `CoreAgentSkillSleepOptimizer.run` preflights missing skills and validation metadata, but it does not preflight edit applicability. During the loop, `editsExceedLimits` intentionally returns `false` for non-size edit errors such as:

- `emptyReplacementTarget`
- `replacementTargetNotUnique`
- replacement target missing after earlier accepted mutations

Those errors are then thrown later by `optimizer.propose(...)` / `CoreAgentSkillEdit.apply(...)`. If an earlier proposal in the same sleep run was already accepted, the skill store has already been mutated, but the sleep run throws and returns no report/audit for the partial run.

Example shape:

1. Proposal A is valid and accepted, saving skill version 2.
2. Proposal B has invalid edit metadata, e.g. whitespace-only replacement target, or a target that is no longer present after Proposal A.
3. `run` throws from `optimizer.propose`.
4. Store remains mutated by Proposal A, with no completed sleep optimization report.

That is a remaining correctness blocker for the sleep/recursive optimization loop because model-proposed invalid edits can leave a partially applied sleep run despite the recent preflight fix for invalid validation metadata.
