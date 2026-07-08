{
  "findings": [
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1374,
      "title": "Default no-rollback behavior can leave failed SwiftData mutations pending in the context",
      "description": "The public ModelContext initializers default rollsBackOnFailure to false. Both graph persistence implementations catch mutation/save failures and call recoverAfterFailedMutation(), but that method is a no-op unless rollsBackOnFailure is true. If modelContext.save() throws after inserts/deletes have been staged, those unsaved changes remain in the caller-supplied ModelContext and can affect later reads or be committed by a later save. That is a data-loss/corruption risk for the persistence slice because a failed save is not guaranteed to leave the graph checkpoint/store state unchanged.",
      "evidence": "CoreAgentSwiftDataGraphCheckpointer.init(modelContext:rollsBackOnFailure:) defaults to false at line 1374, save inserts before try modelContext.save() at lines 1384-1385, and recoverAfterFailedMutation() only rolls back when rollsBackOnFailure is true at lines 1470-1474. CoreAgentSwiftDataGraphStore has the same pattern: public init defaults to false, put/remove stage deletes/inserts before save, and recoverAfterFailedMutation() is also gated.",
      "concrete_fix": "Make rollback-on-failure the default for graph persistence mutations, or unconditionally rollback in the catch paths for save/put/removeValue after any staged mutation. If caller-owned contexts must opt out, require an explicit opt-out parameter and document that failed saves may leave pending changes. Add tests that inject a save failure and verify no failed checkpoint/store mutation is visible in the same context and cannot be committed by a later save."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1447,
      "title": "Checkpoint latest/history ordering is under-specified when saveSequence ties",
      "description": "checkpointRecords sorts only by saveSequence. The code relies on saveSequence defining newest, but equal saveSequence values are possible with multiple ModelContexts/processes computing nextCheckpointSequence independently, or with manually constructed records using the public initializer. With a tie, SwiftData may return rows in an undefined order, so latest() can resume from the wrong checkpoint and history() can be nondeterministic.",
      "evidence": "checkpoint(id:) uses tie-breakers saveSequence, storedAt, and createdAt, but checkpointRecords used by latest/history sorts only by SortDescriptor(\\.saveSequence, order: .reverse). nextCheckpointSequence is a read-max-plus-one without a uniqueness constraint or transaction-level protection.",
      "concrete_fix": "Use the same deterministic tie-breakers for scoped checkpoint fetches, e.g. saveSequence descending, storedAt descending, createdAt descending, and checkpointID as a final stable tie-breaker. Prefer adding a uniqueness/monotonicity strategy if saveSequence is meant to be globally unique across contexts."
    },
    {
      "severity": "P3",
      "file": "Sources/CoreAgentGraph/CoreAgentGraphStore.swift",
      "line": 47,
      "title": "CoreAgentGraphStoreRecord is not Codable despite the stated graph persistence contract",
      "description": "The supplied intended contracts say the graph persistence types are Codable & Sendable and usable through CoreAgentGraphStore protocol existentials. CoreAgentGraphStoreRecord is Sendable, and Equatable when Value is Equatable, but it has no Codable conformance when Value is Codable. This leaves the store record type inconsistent with CoreAgentGraphCheckpoint, CoreAgentGraphPendingWrite, and the stated Codable contract.",
      "evidence": "CoreAgentGraphCheckpoint and CoreAgentGraphPendingWrite both add Codable conformances when their generic State is Codable. CoreAgentGraphStoreRecord only has `extension CoreAgentGraphStoreRecord: Equatable where Value: Equatable {}` and no matching `Codable where Value: Codable` extension.",
      "concrete_fix": "Add `extension CoreAgentGraphStoreRecord: Codable where Value: Codable {}` and a focused compile/runtime test that a `CoreAgentGraphStoreRecord<CodableValue>` round-trips through JSONEncoder/JSONDecoder and remains usable through `any CoreAgentGraphStore<CodableValue>`."
    }
  ],
  "residual_risks": [
    "The snippets do not show uniqueness constraints or migration/schema setup for the SwiftData models, so duplicate rows remain possible unless constrained elsewhere.",
    "Integrity checks rely on Date sidecars and encoded payload dates retaining compatible precision across SwiftData persistence; the supplied tests appear to exercise in-memory contexts but not necessarily durable SQLite round-trips."
  ],
  "testing_gaps": [
    "Add save-failure tests for checkpointer.save, store.put, and store.removeValue that verify rollback semantics in a caller-supplied ModelContext.",
    "Add a deterministic ordering test with two checkpoint rows in the same scope and identical saveSequence values to lock latest/history tie-breaking behavior.",
    "Add a Codable conformance test for CoreAgentGraphStoreRecord<Value> once the conformance is added.",
    "Add a durable SwiftData container round-trip test for graph checkpoint/store records to catch Date precision or digest mismatches after reopening the store."
  ]
}