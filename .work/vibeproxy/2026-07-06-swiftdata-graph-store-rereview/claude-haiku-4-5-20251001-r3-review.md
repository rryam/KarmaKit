```json
{
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1447,
      "title": "Checkpoint fetch predicate includes forged scope-key candidates but latest() validates only newest without exhausting OR branch",
      "description": "The checkpointRecords() fetch predicate uses OR logic: `record.checkpointScopeKey == scopeKey || (record.threadID == threadID && record.namespace == namespace)`. This intentionally includes candidates with forged/mismatched scope keys so validators can throw. However, latest() calls checkpointRecords(fetchLimit: 1) and validates only the first result. If the newest record (by saveSequence/storedAt/createdAt) happens to match the OR's second branch (threadID+namespace match but scopeKey is forged), latest() will throw on validation, which is correct. But the sort order (saveSequence DESC) means if an older valid record and a newer forged record both exist for the same scope, latest() returns the forged one and fails closed—which is intended. The contract states 'latest validates only the newest candidate for O(1) resume, while history still fails on older corrupt rows.' This is met, but the design is fragile: adding a record with matching threadID+namespace but different scopeKey will poison latest() even if older valid checkpoints exist. This violates the implicit contract that latest() should return the newest valid checkpoint, not fail if a newer invalid one exists.",
      "evidence": "Lines 1432-1437 (latest() calls checkpointRecords with fetchLimit:1, maps to checkpoint validation), lines 1447-1452 (OR predicate includes bad-scope-key candidates), test at line 2122 (swiftDataGraphCheckpointerLatestValidatesNewestCandidateOnly) expects latest() to succeed even with older corrupt records, but does not test a newer corrupt record poisoning the result.",
      "concrete_fix": "Either (1) add a third sort criterion to prefer records with valid scopeKey first (requires scope validation before sort, defeating O(1) intent), or (2) document that latest() will fail if the newest record is corrupt even if older valid ones exist, and update the test to verify this behavior is intentional, or (3) change latest() to fetch without limit and return the first valid checkpoint after filtering, accepting O(n) cost for correctness. Recommend option (3): modify latest() to validate and skip invalid candidates until a valid one is found, with a test that newer corrupt records do not block returning an older valid checkpoint."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1500,
      "title": "Store put() validates existing records before deletion but does not handle model context delete state during exception",
      "description": "In put(), existing records are fetched, validateIntegrity() is called on each, then modelContext.delete() is called for each, then the new record is inserted. If validation throws, the exception bubbles before any delete. However, if delete() succeeds but insert() throws, the record is deleted but insertion failed; rollback (if enabled) will undo this, but if rollsBackOnFailure=false, the key's value is lost. Additionally, if an exception occurs between multiple delete() calls (e.g., during iteration), some records may be deleted and the transaction partially applied. The code does call recoverAfterFailedMutation() in the catch block, but only if rollsBackOnFailure is true. With rollsBackOnFailure=false (the default for explicit ModelContext), data loss is possible.",
      "evidence": "Lines 1499–1518 in put(): loop calls modelContext.delete() for multiple records, then insert(), then save(). If save() throws, records are deleted but new one not inserted. Lines 1513–1517 show recoverAfterFailedMutation() only rolls back if rollsBackOnFailure=true. Default is rollsBackOnFailure=false (line 1485), so put() with default context can lose data.",
      "concrete_fix": "Change default rollsBackOnFailure to true (line 1485: `private let rollsBackOnFailure: Bool = true`), or restructure put() to insert the new record first, then delete old ones, so any exception leaves the new value in place (even if duplicated briefly). Alternatively, delete records only after save() succeeds. Recommend: change default to true and update init docstring."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1585,
      "title": "Store storeRecords() predicate does not enforce scope-key match for integrity validation in keys()",
      "description": "keys() iterates over all fetched records and calls validateIntegrity() on each, including those matching the OR branch (namespace+key match but scopeKey might be forged). The contract states 'Store keys validate integrity without decoding typed payload values', and the test at line 2185 (swiftDataGraphStoreKeysValidateIntegrityWithoutDecodingPayloadValues) confirms this. However, the predicate allows forged-scopeKey records to be included in keys(), and validateIntegrity() will throw if scope key is forged, failing the entire keys() call. This is fail-closed (correct), but the test at line 2185 does not verify that a record with forged scopeKey is rejected by keys(). Test inserts two heterogeneous OtherGraphValue records (which will have different encoded values but valid sidecar structure), not a forged-scope record. A test for forged scope in store keys is missing.",
      "evidence": "Lines 1560–1576 in keys(): fetches with OR predicate, validates each record. Line 2185 test does not insert a record with forged scopeKey. Test at line 2253 (swiftDataGraphStoreFailsClosedOnForgedScopeKeysBeforeReadOrMutation) covers put/remove/record but no mention of keys() test in provided snippet.",
      "concrete_fix": "Add test case: insert a store record with forged scopeKey, call store.keys(), expect CoreAgentSwiftDataGraphPersistenceError.storeScopeMismatch. Verify that keys() fails closed when any record in the namespace has a forged scope key."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1153,
      "title": "Checkpoint init with nil checkpointScopeKey does not validate scopeKey derivation matches input fields",
      "description": "CoreAgentSwiftDataGraphCheckpointRecord.init() at line 1117 accepts an optional checkpointScopeKey parameter. If nil, it derives it from threadID and namespace. However, there is no test that verifies a manually-constructed record with a pre-computed but incorrect scopeKey (e.g., scopeKey derived from different threadID) fails validation. The convenience init (line 1099) always derives the correct scopeKey, so it is safe. But the designated init (line 1117) trusts the input. If external code or a migration constructs a record with checkpointScopeKey set to a value that does not match the derived value, checkpoint() will throw, which is correct fail-closed behavior. However, this is a protocol contract risk: if a caller constructs records directly (bypassing the convenience init), they must ensure scopeKey is correct.",
      "evidence": "Lines 1117–1138: designated init accepts checkpointScopeKey as optional; if provided, it is used as-is without validation. Line 1150: checkpoint() validates it matches the derived value. No test directly validates a mismatched scopeKey provided to init().",
      "concrete_fix": "Add a test: construct CoreAgentSwiftDataGraphCheckpointRecord with mismatched checkpointScopeKey (correct threadID/namespace but wrong scope hash), call checkpoint(), expect checkpointScopeMismatch error. Or add validation in the designated init to compute expected and actual scopeKey and throw if they mismatch, but this changes the init contract."
    },
    {
      "severity": "P2",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1290,
      "title": "Store graphRecord() decodes payload after validateIntegrity() but decoded value is not re-validated against sidecar",
      "description": "In graphRecord() (line 1281), validateIntegrity() is called first, then the payload is decoded. The contract states 'Store reads validate all fetched per-key candidates' and 'Store keys validate integrity without decoding typed payload values, so heterogeneous valid payload rows are not treated as corrupt.' This means store records with different payload types but same namespace/key are allowed, and validateIntegrity() (which does not decode) passes them. However, graphRecord() decodes assuming type Value, and if the stored payload is of a different Codable type, the decode will fail, throwing storePayloadDecodeFailed. This is fail-closed (correct). But there is no validation that the decoded graphRecord's namespace and key match the sidecar after construction—only that the sidecar values match the columns (line 1301–1305). This check is redundant with the validateIntegrity() call, which already validated namespace/key/scope. No data corruption risk, but the redundant check suggests incomplete trust in validateIntegrity().",
      "evidence": "Lines 1281–1305 in graphRecord(): validateIntegrity() called, payload decoded, then graphRecord.namespace and graphRecord.key are checked against namespace and key columns. These columns are validated in validateIntegrity() (line 1315–1320), so the re-check is redundant.",
      "concrete_fix": "Remove the redundant check at lines 1301–1305, or document why it is necessary (e.g., Codable contract violation). If kept, rename it from 'sidecar mismatch' to 'constructed record mismatch' for clarity. No test change needed."
    },
    {
      "severity": "P3",
      "file": "Tests/CoreAgentApplePlatformTests/CoreAgentApplePlatformTests.swift",
      "line": 2253,
      "title": "Test swiftDataGraphStoreFailsClosedOnForgedScopeKeysBeforeReadOrMutation missing test for keys()",
      "description": "The test at line 2253 (mentioned in index but not fully shown) covers put/remove operations with forged scopeKey, but the test snippet ends at line 2275 without showing if keys() is tested. Based on the test name and provided snippet cutoff, it appears keys() may not be tested in this scenario. Keys() should fail when iterating records with forged scopeKey.",
      "evidence": "Line 2253 test name implies coverage of read/mutation, but provided snippet (lines 2253–2275) shows only put/remove, not keys(). No keys(namespace:) call in visible test code.",
      "concrete_fix": "Extend the test to also call store.keys(namespace: 'alpha') after inserting a forged-scope record, and verify it throws CoreAgentSwiftDataGraphPersistenceError.storeScopeMismatch."
    },
    {
      "severity": "P3",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1378,
      "title": "Checkpoint save() does not validate that checkpoint.id matches the constructed record's checkpointID",
      "description": "save() encodes the checkpoint and constructs a record, but does not verify that the record's checkpointID matches checkpoint.id before insertion. The record is constructed with checkpoint.id.rawValue, so in normal operation they match. However, if the checkpoint object is modified after encoding but before insertion (unlikely in practice, but possible due to Sendable semantics), a mismatch could occur. The checkpoint() method validates this (line 1193), so the contract is enforced at read time. But save() does not pre-validate, so an invalid record could be inserted and only caught at read time.",
      "evidence": "Lines 1378–1388 in save(): record constructed from checkpoint, inserted, no validation that record.checkpointID == checkpoint.id.rawValue before insertion. Validation happens at line 1193 during read.",
      "concrete_fix": "Add assertion or pre-save validation: `guard record.checkpointID == checkpoint.id.rawValue else { throw CoreAgentSwiftDataGraphPersistenceError.checkpointSidecarMismatch(...) }` after line 1379. Or document that the record-sidecar check in checkpoint() is sufficient and remove assertion."
    }
  ],
  "residual_risks": [
    "Scope-key collision risk: sha256Hex over framed fields may have theoretically low collision probability, but no collision detection or mitigation at insertion time. If two different (threadID, namespace) pairs hash to the same scope key, forged-scope detection will fail. Recommend adding a uniqueness constraint or collision test.",
    "Time-token precision: timeToken() converts Date to nanosecond Int64, then back to String. If Date.timeIntervalSinceReferenceDate has microsecond precision on some platforms, rounding errors could cause mismatched digests on save/load cycles. Test on real devices to verify round-trip consistency.",
    "SwiftData model schema evolution: @Model records do not have a schema version or migration path. If the model fields change (e.g., adding a new field), existing persisted records may fail to decode. No migration support in the provided code.",
    "Concurrent access to modelContext: checkpointer and store are @MainActor, but if called from background tasks or concurrent contexts via protocol existentials, MainActor checks may be bypassed. Ensure callers respect @MainActor requirement.",
    "Rollback semantics: recoverAfterFailedMutation() calls modelContext.rollback(), which undoes all pending changes in the context. If multiple concurrent operations use the same context, a rollback in one operation affects all. Consider per-operation transactions or separate contexts.",
    "Missing envelope validation: frames use simple format 'len:value|', with no HMAC or signature to detect frame corruption. A corrupted frame count could cause framing to fail silently or mismatch digests without throwing."
  ],
  "testing