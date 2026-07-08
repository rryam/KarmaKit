BLOCK: at least one concrete issue should be fixed before treating this slice as done.

Blocking issues:

1. **Unbounded edit drift is still possible.**  
   `CoreAgentSkillOptimizationPolicy` bounds only the number of edits via `maxEditsPerProposal`, but a single edit can append or replace with arbitrarily large text:

   ```swift
   case .append(let addition):
     return body + addition
   ```

   and:

   ```swift
   case .replace(let target, let replacement):
     ...
     return parts[0] + replacement + parts[1]
   ```

   The SkillOpt contract calls for bounded text changes. A proposal with one `.append(String(repeating: ..., count: huge))` or one tiny-target/huge-replacement edit can pass the edit-count policy and massively drift the skill document. This needs a concrete character/token delta/body-size budget or equivalent bounded-diff validation before acceptance.

2. **The public acceptance path can bypass the sleep-loop policy gates.**  
   `CoreAgentSkillOptimizer.propose` directly mutates the store if:

   ```swift
   proposal.validation.passed &&
   proposal.validation.score > proposal.baselineScore
   ```

   It does not enforce:

   - heldout/training split exclusion,
   - `minimumScoreDelta`,
   - edit budget,
   - protected-region immutability,
   - max accepted proposals per run.

   Even if `CoreAgentSkillSleepOptimizer.run` performs these checks before calling it, the same store exposes a public optimizer that can accept edits outside the intended SkillOpt contract. For this slice, acceptance should be centralized behind the policy-aware sleep/optimization gate, or `CoreAgentSkillOptimizer.propose` should take/enforce the policy/expected validation constraints itself.

Non-blocking note: the sleep optimizer test asserts exact entry/meta-observation ordering. That may be acceptable if ordering is intended API behavior, but if not, those assertions are brittle/incidental.
