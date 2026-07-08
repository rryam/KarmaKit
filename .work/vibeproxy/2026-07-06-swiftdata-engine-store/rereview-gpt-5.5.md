VERDICT: BLOCK

FINDINGS:

1. **P2 — `CoreAgentSwiftDataEngineTraceRecord.trace` / `canonicalTraces(from:)` — `traceScopeKey` is not integrity-checked**
   - **Why it matters:** The trace digest binds `projectID`, `threadID`, `runID`, timestamps, redaction policy identifier, and payload hash, but not `traceScopeKey`; nor does `trace` verify that `traceScopeKey == scopeKey(projectID:runID:)`. A row with otherwise valid sidecar fields and payload but a corrupted/forged `traceScopeKey` will verify successfully during project/thread reads. Because `canonicalTraces(from:)` groups winners by `record.traceScopeKey`, this can bypass duplicate collapse and return multiple traces for the same `(projectID, runID)`. Exact lookup also fetches by computed scope key, so such a row may disappear from `trace(projectID:runID:)` while still appearing in `traces(projectID:)`.
   - **Concrete fix:** In `CoreAgentSwiftDataEngineTraceRecord.trace`, fail closed unless:
     ```swift
     traceScopeKey == Self.scopeKey(projectID: projectID, runID: runID)
     ```
     Prefer also adding `traceScopeKey` to `integrityDigest` fields for forward integrity, with migration/backward-compat handling if needed. In `canonicalTraces(from:)`, group by a recomputed canonical key from verified `trace.projectID`/`trace.run.id` or by a verified `scopeKey`, not an unchecked stored value.

2. **P2 — `CoreAgentSwiftDataEngineStore.upsertIssue(_:)` and `InMemoryCoreAgentEngineStore.upsertIssue(_:)` — contributing run IDs are replaced, not merged**
   - **Why it matters:** When an issue already exists, the code computes `existingRuns`, `incomingRuns`, and `hasNewRuns`, but the stored issue uses:
     ```swift
     contributingRunIDs: issue.contributingRunIDs
     ```
     This can drop previously stored contributing runs if the incoming issue contains only a delta, a partial scan result, or is produced by a caller that does not replay all historical runs. That corrupts issue provenance and can also affect reopening logic over time.
   - **Concrete fix:** Store a deterministic union of existing and incoming run IDs, preserving a stable order, e.g. existing order plus new incoming IDs:
     ```swift
     let mergedRunIDs = existing.contributingRunIDs + issue.contributingRunIDs.filter {
       !existingRuns.contains($0)
     }
     ```
     Use `mergedRunIDs` in both SwiftData and in-memory stores. Keep `hasNewRuns` based on the incoming-vs-existing set comparison.

3. **P2 — `CoreAgentSwiftDataEngineStore.upsertIssue(_:)` / `issueRecords(issueID:)` / in-memory `issuesByID` — issue canonicalization is scoped only by `issueID`**
   - **Why it matters:** `upsertIssue` fetches and deletes all records with the same `issueID` regardless of `projectID`; the in-memory store also keys only by `issue.id`. If issue IDs are derived from fingerprints or are otherwise not globally unique, an upsert in one project can merge with, overwrite, or delete an issue from another project. Even within one project, a colliding `issueID` with different fingerprint is silently merged while preserving the old `projectID`/`fingerprint` and adopting the new title/runs.
   - **Concrete fix:** Either enforce and document that `CoreAgentEngineIssue.id` is globally unique and add validation that `existing.projectID == issue.projectID` and `existing.fingerprint == issue.fingerprint` before merging, or scope persistence by `(projectID, issueID)` / `(projectID, fingerprint)`. For SwiftData, change `issueRecords(issueID:)` to include `projectID` for upsert paths, or add an issue scope key similar to traces. For in-memory, key by a composite issue key.

4. **P2 — `CoreAgentSwiftDataEngineStore` public `init(modelContext:rollsBackOnFailure:)` — failed mutations can leave destructive deletes pending**
   - **Why it matters:** The patch correctly constructs replacement records before deleting existing rows, but rollback after a failed save only happens when `rollsBackOnFailure` is true. The public `modelContext` initializer defaults this to `false`, and the tests use that initializer. If `save()` fails after deletes/inserts have been staged, the store throws but leaves the `ModelContext` with pending deletions and insertions. A later unrelated save can commit the destructive mutation, causing data loss despite the failed operation.
   - **Concrete fix:** Make mutation rollback the default for this store, or always rollback changes staged by `ingest`, `upsertIssue`, and `updateIssueStatus` on failure. If preserving unrelated caller changes is a concern, document that callers must provide an isolated context and set `rollsBackOnFailure: true`, but the safer fix is to default the public initializer to `true` or use a private mutation context.

TEST GAPS:

1. **Corrupted `traceScopeKey` with otherwise valid trace record**
   - Insert two valid trace records for the same `(projectID, runID)`, one with a forged/stale `traceScopeKey`.
   - Assert `trace(projectID:runID:)` and `traces(projectID:)` agree and return only the canonical valid trace.
   - This would catch unchecked scope-key duplicate bypasses.

2. **Issue upsert with partial contributing run IDs**
   - Store an issue with `[runA]`, then upsert same issue with `[runB]`.
   - Assert stored issue has `[runA, runB]` and reopening still works if the previous status was `.resolved`.
   - This would catch provenance loss from replacement instead of union.

3. **Cross-project or fingerprint-collision issue upsert**
   - Insert/upsert two issues with the same `issueID` but different `projectID` and/or `fingerprint`.
   - Assert they do not merge/delete each other, or assert the store rejects the collision explicitly.
   - This would catch lifecycle canonicalization scoped only by issue ID.

4. **Failed SwiftData save after destructive mutation using `init(modelContext:)`**
   - Use a failing/instrumented context or a controlled invalid mutation to force `save()` failure after deletes are staged.
   - Assert the original records remain visible and no pending delete is committed by a later save.
   - This would catch non-atomic mutation behavior when `rollsBackOnFailure` is false.