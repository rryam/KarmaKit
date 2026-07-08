VERDICT: BLOCK

FINDINGS:

1. **P2 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / `CoreAgentSwiftDataEngineTraceRecord.trace`**
   - **Why it matters:** `CoreAgentSwiftDataEngineStore` correctly rejects persisted trace rows whose decoded run is not redacted, via `verifiedTrace(from:)`. But the `@Model` record exposes a public `trace` accessor that performs digest/sidecar/receipt checks without enforcing redaction. Any package consumer with access to SwiftData records can decode a valid, receipt-verifiable but unredacted trace row directly, bypassing the store’s fail-closed privacy invariant.
   - **Concrete fix:** Do not expose decoded trace payloads publicly from the record. Make the decode accessor `internal`/`package` and route all public readback through `CoreAgentSwiftDataEngineStore`, or move trace decoding into a store-private helper that also requires the configured redaction policy. If the model type must remain public for schema construction, keep raw indexed fields public as needed but do not expose a public canonical `CoreAgentEngineTrace?`.

2. **P2 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / `CoreAgentSwiftDataEngineStore.traces(projectID:threadID:)`**
   - **Why it matters:** Project/thread trace queries return every verified row sorted by sequence. If duplicate valid rows already exist for the same `(projectID, runID)`—for example from a previous bug, migration, failed partial mutation, or multi-context writer—the store returns multiple traces. That diverges from `InMemoryCoreAgentEngineStore`, where `(projectID, runID)` is a replacement key, and makes SwiftData row shape become observable canonical truth.
   - **Concrete fix:** After verification, collapse by `CoreAgentSwiftDataEngineTraceRecord.scopeKey(projectID:runID:)` or `(projectID, run.id)`, choose the deterministic replacement winner, e.g. highest `sequence` then latest `ingestedAt`, and return only winners sorted by their chosen sequence. Consider adding a uniqueness constraint if SwiftData schema support is acceptable, but still keep read-side collapse for migration/corruption tolerance.

3. **P2 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / `CoreAgentSwiftDataEngineStore.upsertIssue(_:)` and `updateIssueStatus(_:status:)`**
   - **Why it matters:** Both methods use `try issueRecords(issueID:).first?.issue`. If the newest row for an issue ID is corrupt or has mismatched sidecar/status data, but an older valid row exists, the valid lifecycle state is ignored. `upsertIssue` will treat the issue as new and can reset an explicitly `resolved`/`ignored` issue back to the incoming status. `updateIssueStatus` can silently no-op even though a valid duplicate row exists.
   - **Concrete fix:** Fetch all rows for the issue ID, decode with `compactMap(\.issue)`, and choose the deterministic valid winner before applying lifecycle logic. Delete all rows for that issue ID before inserting the merged replacement. If no valid row exists, then fail closed as new input or throw a corruption error, but do not let an invalid duplicate shadow a valid lifecycle row.

4. **P2 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / `CoreAgentSwiftDataEngineStore.issues(projectID:status:)`**
   - **Why it matters:** Issue queries return all valid rows and do not collapse duplicate rows by `issueID`. This can surface duplicate issues, stale statuses, and stale first/last-seen windows if multiple valid rows exist for one issue. The in-memory store has one issue per ID, and the slice requirements call for duplicate row collapse rather than treating SwiftData rows as canonical truth.
   - **Concrete fix:** Decode valid issues, group by `id`, choose a deterministic winner, preferably by latest `lastSeenAt` plus stable tie-breakers or by the same row ordering used for lifecycle updates, and return one issue per ID. For status-filtered queries, prefer collapsing first and then applying the typed status filter, or ensure the sidecar filter cannot exclude the canonical winner incorrectly.

5. **P3 — `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` / failed mutation paths in `ingest`, `upsertIssue`, `updateIssueStatus`**
   - **Why it matters:** With a caller-supplied `ModelContext`, `rollsBackOnFailure` is false. The store deletes existing rows before all throwing work and `save()` complete. If encoding, insert, or save fails, the shared context can retain pending deletes/inserts that a later unrelated save may commit. This can cause unintended trace/issue loss even though the store operation threw.
   - **Concrete fix:** Move all possible pre-save throwing work before destructive deletes where possible: construct encoded records first, compute sequence first, then delete/insert. For save failures on shared contexts, either document and expose a clear recovery contract, or perform mutations in an isolated context/transaction-like helper so failed store operations cannot leave pending destructive changes in a shared context.

TEST GAPS:

1. Insert two valid trace records with the same `(projectID, runID)` and assert `traces(projectID:)` and `traces(projectID:threadID:)` return exactly one deterministic winner.

2. Insert a valid resolved/ignored issue row plus a newer corrupt duplicate with the same `issueID`; then run scanner upsert/status update and assert the valid lifecycle state is preserved and the corrupt row does not shadow it.

3. Insert two valid issue rows with the same `issueID` but different status/seen bounds and assert `issues(projectID:)` and `issues(projectID:status:)` collapse to one deterministic typed issue.

4. Add a non-`@MainActor`/detached-task regression that uses `CoreAgentSwiftDataEngineStore` through `any CoreAgentEngineStore` and through `CoreAgentEnginePlugin`, to catch Swift 6 actor-isolation or existential-conformance regressions outside main-actor tests.

5. Add a regression proving unredacted valid trace rows cannot be decoded through public API. Ideally this becomes a compile/API test after making record-level decoded trace access non-public; otherwise it should fail until `CoreAgentSwiftDataEngineTraceRecord.trace` enforces the same redaction invariant as the store.