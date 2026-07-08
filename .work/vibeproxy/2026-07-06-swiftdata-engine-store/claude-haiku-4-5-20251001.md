# SwiftData Engine Store Review

Examining actor isolation, Sendable semantics, receipt verification, sidecar metadata binding, issue lifecycle, and fail-closed behavior across trace/issue records and the ModelContext-backed store.

## VERDICT: BLOCK

---

## FINDINGS

### P1: Actor Isolation Violation – `CoreAgentSwiftDataEngineStore` Unsafe State Access

**File/Symbol:** `CoreAgentApplePlatform.swift:622–662` (`CoreAgentSwiftDataEngineStore.ingest`)

**Why it matters:** The store is declared `@MainActor`, but `modelContext` operations are not actor-safe. SwiftData's `ModelContext` is not `Sendable` and must not be accessed from concurrent contexts. If `ingest()` is called concurrently or reentered, multiple threads write to `modelContext` simultaneously, causing race conditions and data corruption.

**Concrete issue:**
- Line 664: `modelContext.delete(record)`
- Line 670: `try modelContext.save()`

These are called within an async function but without `await` nonisolated boundaries. If the caller holds a reference to the store and calls `ingest()` from multiple tasks before `@MainActor` enforcement is applied, the store will corrupt its database.

**Fix:** Ensure all `modelContext` access happens on the main thread *before* async boundaries. Either:
1. Move all `modelContext` operations into a `@MainActor` nonisolated helper, or
2. Add explicit `MainActor.runUnsafeOnMainThread { }` wrappers around all mutation operations, or
3. Document that callers must serialize all calls through a serial queue (unsafe for async/await).

Better: Redesign to use `nonisolated(unsafe)` for the context only if absolutely necessary, but prefer isolating the entire mutation phase.

---

### P1: Receipt Verification Bypass – Unredacted Run Detected But Not Rejected

**File/Symbol:** `CoreAgentApplePlatform.swift:853–862` (`verifiedTrace`)

**Why it matters:** The verification logic checks `redactionPolicy.redacted(run: trace.run) == trace.run` (line 857), but this is insufficient. The check compares the result of applying the redaction policy to the stored run against itself, which will only catch runs that the *current* policy would redact. If:
- The redaction policy changes, old unredacted rows pass (no policy versioning).
- A run was stored without redaction (pre-policy or bug), the check silently passes.
- The redaction policy is lenient (e.g., `.custom { $0 }`), unredacted data leaks.

The integrity digest (line 455–463) binds the encoded trace, but does *not* bind the redaction policy itself or a policy version, so a stale/wrong policy can decode stale unredacted payloads.

**Fix:**
1. Add a `redactionPolicyVersion: String` field to the trace record (computed from policy identifier or hash).
2. Include the policy version in the integrity digest.
3. On readback, reject any trace whose policy version does not match the current policy.
4. Alternatively, bind a redaction-state flag into the digest at encode time (e.g., `"redacted:true"` concatenated into digest fields).

---

### P1: Unknown Issue Status Raw Value Silently Ignored

**File/Symbol:** `CoreAgentApplePlatform.swift:569–597` (`CoreAgentSwiftDataEngineIssueRecord.issue`)

**Why it matters:** Line 590 checks `issue.status.rawValue == statusRawValue`, but this check happens *after* decoding the issue from JSON (line 581–585). If the encoded issue has a status field that does not match `statusRawValue`, the record fails closed (returns nil). However, if `statusRawValue` is an unknown raw value (e.g., `"future_status_v2"`), the comparison will fail *and* the issue will be silently dropped instead of surfacing an error or logging the mismatch.

This is fail-closed in spirit but creates silent data loss. A human operator cannot debug why an issue disappeared.

**Fix:**
1. If `statusRawValue` is unknown, fail explicitly with a logged error or exception.
2. Add a `statusVersion` field to the record to support schema evolution.
3. Document that unknown statuses must be treated as a hard error (not a silent skip).

---

### P2: Trace Sidecar Metadata Not Digest-Bound to Scope Key

**File/Symbol:** `CoreAgentApplePlatform.swift:486–513` (`CoreAgentSwiftDataEngineTraceRecord`)

**Why it matters:** The `traceScopeKey` (line 440) is derived from `projectID` and `runID` only (line 486–491):
```swift
let fields = [projectID, runID.uuidString.lowercased()]
return "engine-trace-scope-sha256-v1:" + sha256Hex(framed(fields))
```

But the integrity digest (line 494–512) includes `threadID`, `startedAt`, `endedAt`, `ingestedAt`, and the encoded trace. This means:
- Two traces with the same `projectID`/`runID` but different `threadID` have different digests but the *same* scope key.
- A malicious or corrupted database can swap the `threadID` of one trace for another without breaking the scope key, then replace one trace with another's data.

The digest catches this (line 472–477 re-validates all metadata), but the scope key is not a security boundary—it is just an index.

**Fix:**
1. Include `threadID` in the scope key calculation (or remove threadID from the model if it is not part of the identity).
2. If threadID is optional and can change, bind it explicitly into the digest and include version.
3. Document that scope key is a query hint, not a security boundary, and digests are the authoritative check.

This is lower severity because the digest *does* catch the mismatch, but it is a foot-gun for future code that might trust the scope key as a uniqueness invariant.

---

### P2: `issueRecords(issueID:)` Returns Multiple Rows but Only First Is Used

**File/Symbol:** `CoreAgentApplePlatform.swift:692–726` (`upsertIssue`)

**Why it matters:** Line 694 calls `issueRecords(issueID: issue.id).first?.issue`, which fetches all records with the issue ID (sorted by `lastSeenAt` descending, line 811), but only uses the first one. If two records somehow exist (corruption, concurrent writes, or migration bugs), the second is silently ignored.

Issue records are supposed to be collapsed during upsert (line 716–718 deletes all existing records before inserting one new one), so multiple rows should not exist. But if they do, the code does not signal an error or consolidate them.

**Fix:**
1. Assert that `issueRecords(issueID:)` returns at most one record, or log a warning if multiple exist.
2. Consolidate multiple corrupted records into one before returning.
3. Add a test that covers the "corrupted multiple records" case explicitly.

---

### P2: Trace Sequence Monotonicity Not Enforced on Replacement

**File/Symbol:** `CoreAgentApplePlatform.swift:648–676` (`ingest`)

**Why it matters:** When a duplicate run is ingested (same `projectID`/`runID`), the old record is deleted (line 663–665) and a new record is inserted with `sequence: nextTraceSequence()` (line 668). This means:
- If run A is ingested at sequence 0, then run B at sequence 1, then run A is re-ingested, the new run A gets sequence 2 (or later).
- Traces are ordered by `sequence` (line 776), so the re-ingested run A will appear *after* run B, even though it originally appeared first.

This breaks query ordering semantics: `traces(projectID, threadID)` will return runs in replacement order, not original ingest order.

**Fix:**
1. Preserve the original sequence when replacing a trace: if a trace with the same `projectID`/`runID` exists, reuse its sequence instead of allocating a new one.
2. Alternatively, document that sequence is replacement order, not ingest order, and update tests and code comments accordingly.

The test at line 1442–1477 (`swiftDataEngineStoreReplacesDuplicateTracesAndKeepsStableOrdering`) does not catch this because it does not verify the sequence field itself, only the returned traces order via the store's query logic (which does return them in sequence order). But if the sequence is reassigned, the test passes spuriously.

---

### P3: JSON Codec Not Isolated – Shared Encoder/Decoder State

**File/Symbol:** `CoreAgentApplePlatform.swift:885–898` (`CoreAgentSwiftDataEngineCodec`)

**Why it matters:** The `encode` and `decode` functions create a new `JSONEncoder` and `JSONDecoder` on each call, which is correct. However, if the codec is ever extended to cache encoders/decoders (a common optimization), those objects would not be thread-safe. The current code is safe, but the pattern is fragile.

**Fix:**
1. Document that the codec must not cache encoder/decoder instances.
2. Add a test that verifies concurrent encode/decode calls do not interfere.

---

### P3: Missing Test – Ignored Status Not Reset on New Runs

**File/Symbol:** Test gap

**Why it matters:** The test at line 1228–1239 verifies that ignored issues stay ignored when new runs arrive:
```swift
try await store.updateIssueStatus(first.id, status: .ignored)
try await store.ingest(Self.engineFailedRun(...))
let ignoredAfterNewRun = try #require(try await scanner.scan(...).first)
#expect(ignoredAfterNewRun.status == .ignored)
```

This is correct behavior (per InMemory line 234–235), but the test does not verify that the issue *still appears in the scan results* (i.e., that ignored issues are not filtered out by the scanner). If `scanner.scan()` inadvertently skips ignored issues, the test would crash on the `#require` and the bug would be caught, but a safer test would:
1. Verify that `.scan()` returns the ignored issue in the results.
2. Verify that `.issues(projectID: "...", status: .ignored)` includes it.

---

### P3: Subsecond Precision Lost in `timeToken()` – No Test Coverage of Collision Risk

**File/Symbol:** Test gap + implementation

**Why it matters:** The test at line 1581–1611 verifies that subsecond dates round-trip exactly, which is good. However, the `timeToken()` function (not shown, but used in digest calculations) may truncate subsecond precision for hashing. If two different traces have `startedAt` values that differ only in nanoseconds, they could produce the same `timeToken()`, leading to collisions in the digest.

The test does not verify that two traces with sub-millisecond differences have different digests.

**Fix:**
1. Include the full subsecond precision in `timeToken()` or verify its implementation.
2. Add a test that creates two traces with timestamps differing by 1 nanosecond and verifies their digests are different.

---

## TEST GAPS

### Gap 1: No Test for Concurrent `ingest()` Calls

Currently all tests are `@MainActor`. Add a test that:
1. Creates the store.
2. Calls `ingest()` from two concurrent tasks with different runs.
3. Verifies both traces are persisted and queryable.

This will expose race conditions in `modelContext` access if actor isolation is broken.

---

### Gap 2: No Test for Redaction Policy Change

Add a test that:
1. Ingests a trace with policy A (redacts API keys).
2. Switches the store to policy B (redacts only auth headers).
3. Queries the trace.
4. Verifies the trace is rejected or handled correctly (depending on the fix for P1 above).

---

### Gap 3: No Test for Multiple Issue Records (Corruption Case)

Add a test that:
1. Manually inserts two `CoreAgentSwiftDataEngineIssueRecord` rows with the same `issueID`.
2. Calls `upsertIssue()` with a new issue.
3. Verifies the store consolidates or rejects the corrupted state.

---

### Gap 4: No Test for Trace Sequence Reuse on Replacement

Add a test that:
1. Ingests run A, B, C in order (sequences 0, 1, 2).
2. Ingests run A again (should reuse sequence 0, not get sequence 3).
3. Queries all traces and verifies order is [A, B, C], not [B, C, A].

---

### Gap 5: No Test for Unknown Issue Status Raw Value

Add a test that:
1. Manually inserts an `CoreAgentSwiftDataEngineIssueRecord` with `statusRawValue: "unknown_future_status"`.
2. Calls `issues(projectID:)`.
3. Verifies the store either rejects the record or logs a warning.

---

### Gap 6: No Test for Stale/Wrong Sidecar Metadata with Valid Digest

Add a test that:
1. Ingests a trace with `projectID: "coreagent"`, `threadID: "a"`.
2. Manually updates the record's `threadID` to `"b"` but recompute the digest to match.
3. Calls `trace(projectID:, runID:)`.
4. Verifies the trace is rejected (digest catches the mismatch due to re-validation at line 472–477).

This test will pass with the current code but documents the security boundary.

---

## Summary

The implementation has strong fail-closed behavior and integrity checking at the decode layer, but three **P1 issues** block approval:

1. **Actor isolation:** `modelContext` access is not synchronized; concurrent calls will corrupt the database.
2. **Redaction policy binding:** Stale/changed policies can decode unredacted payloads; policy version must be bound to the digest.
3. **Unknown status handling:** Silent data loss on unknown status raw values instead of explicit errors.

Trace sidecar metadata binding and sequence monotonicity (P2) are foot-guns that should be fixed before production. The codec pattern and subsecond tests (P3) are lower-risk but worth addressing.