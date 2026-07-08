VERDICT: **BLOCK**

---

### FINDINGS

#### [P1] `CoreAgentSwiftDataCheckpointStore` / `scopedRecords(for:)` — Table Scan/Memory DoS via Unbounded Fetch
* **Why it matters**: `modelContext.fetch(FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>())` is invoked without a database-level predicate. This fetches **every single checkpoint record** in the entire database table into memory, including their heavy `encodedCheckpoint` binary blobs (transcripts, artifacts, etc.), before filtering them in Swift. As the checkpoint store grows, every save, load, and delete operation will cause severe disk I/O, CPU thrashing, memory usage spikes, and eventual Out-Of-Memory (OOM) crashes.
* **Concrete Fix**: precompute the `scopeKey` and pass a `#Predicate` to the `FetchDescriptor` to filter records at the database layer before loading them into memory:
  ```swift
  private func scopedRecords(for key: String) throws -> [CoreAgentSwiftDataCheckpointRecord] {
    let scopeKey = CoreAgentSwiftDataCheckpointRecord.scopeKey(
      checkpointKey: key,
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion
    )

    var descriptor = FetchDescriptor<CoreAgentSwiftDataCheckpointRecord>(
      predicate: #Predicate<CoreAgentSwiftDataCheckpointRecord> { record in
        record.scopeKey == scopeKey
      }
    )

    let records = try modelContext.fetch(descriptor)
    return records
      .filter { record in
        record.checkpointKey == key
          && record.authorityBoundaryID == authorityBoundaryID
          && record.policyVersion == policyVersion
      }
      .sorted { lhs, rhs in
        if lhs.savedAt != rhs.savedAt {
          return lhs.savedAt > rhs.savedAt
        }
        if lhs.storedAt != rhs.storedAt {
          return lhs.storedAt > rhs.storedAt
        }
        return lhs.checkpointID.uuidString < rhs.checkpointID.uuidString
      }
  }
  ```

---

#### [P2] `CoreAgentSwiftDataCheckpointStore` — Unsafe Context Rollback Destroys Unrelated App Data
* **Why it matters**: If a shared `ModelContext` (such as the main/UI context) is injected into the store's initializer, calling `modelContext.rollback()` in the `catch` blocks of `saveCheckpoint` or `removeCheckpoint` will discard **all** pending changes in that context. This will silently delete unrelated user edits, form states, or draft model updates elsewhere in the application.
* **Concrete Fix**: Add an initializer that takes a `ModelContainer` and instantiates an isolated `ModelContext` internally so rollback actions are safely containerized, or document this side effect clearly and avoid global rollback:
  ```swift
  public convenience init(
    modelContainer: ModelContainer,
    authorityBoundaryID: String,
    policyVersion: Int,
    typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy = .rejectLossyContent,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      modelContext: ModelContext(modelContainer),
      authorityBoundaryID: authorityBoundaryID,
      policyVersion: policyVersion,
      typeErasurePolicy: typeErasurePolicy,
      clock: clock
    )
  }
  ```

---

### TEST GAPS

1. **Large Scale Checkpoint Database Performance Integration Test**
   * **Goal**: Catch database-level filtering regressions and verify that fetch actions do not degrade linearly with database size.
   * **Action**: Write a test that inserts 1,000 large decoy checkpoints (with large dummy payloads) under different scopes/keys, then asserts that loading a specific key completes without fetching the decoy records or triggering high latency.

2. **Rollback Isolation Verification Test**
   * **Goal**: Verify that a failed save or delete in the checkpoint store does not corrupt or roll back unrelated pending changes in the host application's shared database context (or that an isolated context-based store behaves correctly when rollbacks occur).
