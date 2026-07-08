{
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1433,
      "title": "Checkpoint history/latest can silently hide corrupt matching rows",
      "description": "The scope query requires both the indexed scope key and the logical thread/namespace sidecars to match. If a persisted checkpoint row has the requested threadID/namespace but a corrupted checkpointScopeKey, history/latest will not fetch it, so no integrity check runs and callers can get stale valid rows or nil. That violates the fail-closed contract for matching corrupt rows and the sidecar binding contract.",
      "evidence": "checkpointRecords predicates on `record.checkpointScopeKey == scopeKey && record.threadID == threadID && record.namespace == namespace`, then only validates fetched rows via `record.checkpoint(as:)`. A row with `threadID == requested`, `namespace == requested`, and bad `checkpointScopeKey` is skipped before validation.",
      "concrete_fix": "Fetch rows that match either lookup index or logical sidecars, then validate all candidates before returning: e.g. predicate `(record.checkpointScopeKey == scopeKey) || (record.threadID == threadID && record.namespace == namespace)`, sort by saveSequence descending, and call `checkpoint(as:)` on every fetched row so scope/digest/sidecar mismatches throw instead of being filtered out."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1556,
      "title": "Store record/value/remove/put can silently skip corrupt duplicate rows",
      "description": "The per-key store query requires both storeScopeKey and namespace/key to match. A row with the requested namespace/key but corrupted storeScopeKey is ignored by record/value and can be left behind or deleted/replaced by remove/put without validation. This is fail-open behavior for matching corrupt store rows.",
      "evidence": "`storeRecords(forKey:namespace:)` predicates on `record.storeScopeKey == scopeKey && record.namespace == namespace && record.key == key`. `record(forKey:)` validates only the first fetched row. `put` and `removeValue` delete all fetched rows without calling `graphRecord(as:)`; rows with bad scope keys are not fetched at all.",
      "concrete_fix": "For per-key store operations, fetch candidates with `(record.storeScopeKey == scopeKey) || (record.namespace == namespace && record.key == key)`. For reads, validate all candidates or at least validate before choosing a value so any corrupt matching row throws. For put/remove, validate matching candidates before mutation, or explicitly fail with `CoreAgentSwiftDataGraphPersistenceError` when any candidate has scope/digest/payload mismatch."
    }
  ],
  "residual_risks": [
    "The current saveSequence allocator is process-local/read-max based. MainActor serialization helps within this implementation, but there is no uniqueness constraint or conflict handling if multiple ModelContexts/processes write the same store concurrently."
  ],
  "testing_gaps": [
    "Add checkpoint history/latest tests where a row has matching threadID/namespace but an incorrect checkpointScopeKey; expected result is CoreAgentSwiftDataGraphPersistenceError, not stale fallback.",
    "Add store record/value/put/remove tests where a row has matching namespace/key but an incorrect storeScopeKey; expected result is fail-closed before returning, replacing, or deleting.",
    "Add tests with duplicate store rows where one valid and one corrupt matching candidate exists but the corrupt row is not the first sorted row; expected result is fail-closed rather than returning the valid row."
  ]
}