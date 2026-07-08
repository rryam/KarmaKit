BLOCK

The following correctness and stability issues must be fixed:

1. **Infinite Loop / Denial of Service in Protected Region Parser**: 
   In `protectedRanges(for:in:)`, if a `CoreAgentSkillProtectedRegion` has empty `startMarker` and `endMarker` strings, the search range does not advance (`searchStart` remains unchanged), causing the `while` loop to spin infinitely. A guard should be added to ensure markers are non-empty:
   ```swift
   private func protectedRanges(
     for region: CoreAgentSkillProtectedRegion,
     in body: String
   ) -> [CoreAgentProtectedSkillRange] {
     guard !region.startMarker.isEmpty && !region.endMarker.isEmpty else { return [] }
     // ...
   }
   ```

2. **Partial Mutation on Edit Application Failure in Sleep Run**:
   `CoreAgentSkillSleepOptimizer.run(_:)` preflights skill existence and validation scores, but does not dry-run the edit application. If a multi-proposal request has a valid first proposal followed by a second proposal with invalid edits (e.g., non-unique/empty replacement targets or size violations), the run will abort and throw mid-loop. This leaves the store partially mutated (the first proposal's changes are saved, but the run fails to return a report).
   * **Fix**: Dry-run edit applications inside `preflight(_:)` to ensure all proposed edits can be successfully applied to the current bodies before making any store mutations.
