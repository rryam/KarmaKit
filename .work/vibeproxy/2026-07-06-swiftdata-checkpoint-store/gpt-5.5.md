VERDICT: BLOCK

FINDINGS:
- P2 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / `CoreAgentSwiftDataCheckpointStore.scopedRecords(for:)` — Store operations fetch every `CoreAgentSwiftDataCheckpointRecord` and filter in memory. A different authority/policy scope sharing the same SwiftData container can fill the table with unrelated rows and make every `loadCheckpoint`, `saveCheckpoint`, and `removeCheckpoint` O(total checkpoint rows), creating an avoidable cross-scope denial-of-service surface. It also prevents SwiftData from using indexes/predicates for the composite scope barrier. Fix by querying with a SwiftData predicate on `scopeKey` plus the raw scope fields, and push sorting/limits into the fetch where possible:
  - `load`: predicate by `scopeKey/checkpointKey/authorityBoundaryID/policyVersion`, sort by `savedAt desc`, `storedAt desc`, deterministic ID tie-breaker if supported, `fetchLimit = 1`.
  - `save/remove`: predicate by the same scoped fields and fetch only rows in that scope.
  - Consider making `scopeKey` indexed/unique if the desired invariant is one live row per scoped checkpoint key, while retaining migration/repair logic for preexisting duplicates.

TEST GAPS:
- Add a SwiftData store test that seeds many unrelated/cross-scope rows, then verifies scoped load/save/remove use a predicate-limited fetch contract rather than scanning/deleting unrelated records. This can be covered with a helper/fetch wrapper if direct query-plan assertions are not feasible.
- Add a realistic multi-context replacement test if this store is expected to be used from multiple `ModelContext`s against the same container: two saves for the same scoped key should converge to one authoritative row or have a documented conflict/repair path.
