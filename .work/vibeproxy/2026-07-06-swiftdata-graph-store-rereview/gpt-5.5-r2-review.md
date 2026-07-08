{
  "findings": [
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1504,
      "title": "Store put/remove treat valid heterogeneous same-key rows as corruption",
      "description": "Before replacing or deleting existing store rows, the implementation calls graphRecord(as: Value.self), which validates integrity and then decodes the payload as the current store's Value type. That makes mutation fail for an otherwise integrity-valid row at the same namespace/key that was written by a CoreAgentSwiftDataGraphStore with a different Codable value type. This is a fail-closed behavior for real corruption, but it also prevents repair, overwrite, or removal of valid heterogeneous rows because mutation validation is stronger than necessary. The existing validateIntegrity() method can validate scope/digest without decoding typed payloads.",
      "evidence": "put fetches existingRecords and executes `_ = try existing.graphRecord(as: Value.self)` before deleting/replacing them. removeValue does the same at line 1546. graphRecord(as:) calls validateIntegrity() and then decodes `Value.self`, throwing `storePayloadDecodeFailed` on type mismatch. The supplied heterogeneous-key test only covers keys(namespace:) with a different key, not mutation of an existing same-key heterogeneous row.",
      "concrete_fix": "In put and removeValue, validate existing rows with `try existing.validateIntegrity()` instead of `try existing.graphRecord(as: Value.self)` before deletion. Keep typed decoding in read paths (`record`/`value`) where returning Value requires it. Add tests proving that a valid same-namespace/same-key row encoded with another Codable type can be overwritten and removed, while forged scope/digest rows still block mutation."
    }
  ],
  "residual_risks": [
    "The supplied snippet truncates the private storeRecords(forKey:namespace:) implementation after the predicate begins, so ordering and candidate matching for per-key store reads could not be fully reviewed from the provided text."
  ],
  "testing_gaps": [
    "Add a same-key heterogeneous payload test for CoreAgentSwiftDataGraphStore.put: insert an integrity-valid CoreAgentSwiftDataGraphStoreRecord encoded as OtherGraphValue for namespace/key, then verify CoreAgentSwiftDataGraphStore<GraphValue>.put replaces it instead of throwing storePayloadDecodeFailed.",
    "Add a same-key heterogeneous payload test for CoreAgentSwiftDataGraphStore.removeValue: insert an integrity-valid row encoded as OtherGraphValue for namespace/key, then verify CoreAgentSwiftDataGraphStore<GraphValue>.removeValue deletes it instead of requiring typed payload decode.",
    "Add a checkpointer latest test with a corrupt older candidate and a valid newest candidate in the same scope to lock the intended O(1) contract that latest validates only the newest candidate while history still fails closed."
  ]
}