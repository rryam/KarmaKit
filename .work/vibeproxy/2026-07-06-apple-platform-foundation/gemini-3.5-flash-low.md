VERDICT: BLOCK

FINDINGS:

- **Severity:** P1
  - **File/Symbol:** `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` -> `CoreAgentRunProjectionStore.apply(traces:)`
  - **Issue:** The `apply(traces:)` method instantiates a fresh dictionary `projectionsByRunID = [:]` and completely overwrites `self.projections` with only the newly supplied traces. Any existing runs in the projection store are discarded.
  - **Why it matters:** Whenever a new trace batch is ingested incrementally, all previously captured run projections are deleted from the store, breaking state tracking and causing UI views to drop historical runs.
  - **Concrete Fix:** Update `apply(traces:)` to seed the dictionary with existing projections before processing the new traces:
    ```swift
    public func apply(traces: [CoreAgentEngineTrace]) {
      var projectionsByRunID: [UUID: CoreAgentRunProjection] = [:]
      for projection in projections {
        projectionsByRunID[projection.runID] = projection
      }
      for trace in traces {
        projectionsByRunID[trace.run.id] = CoreAgentRunProjection(trace: trace)
      }
      projections = projectionsByRunID.values
        .sorted { lhs, rhs in
          if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
          }
          return lhs.runID.uuidString < rhs.runID.uuidString
        }
    }
    ```

- **Severity:** P2
  - **File/Symbol:** `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` -> `CoreAgentSwiftDataCheckpointSnapshot.timeToken(_:)`
  - **Issue:** Hashing relies on the raw 64-bit float representation of the date via `String(date.timeIntervalSinceReferenceDate.bitPattern)`.
  - **Why it matters:** When `savedAt` is stored as a `Date` field in the database by SwiftData (backed by SQLite/CoreData), floating-point precision shifts or rounding during storage/retrieval can alter the least significant bits of the double. Even a 1-bit deviation changes the computed digest, leading to unexpected `digestMismatch` errors when attempting to decode checkpoints.
  - **Concrete Fix:** Replace the `Double.bitPattern` extraction with a stable integer timestamp (e.g. millisecond/nanosecond offset) or a formatted ISO8601 string:
    ```swift
    private static func timeToken(_ date: Date) -> String {
      String(Int64(date.timeIntervalSince1970 * 1000))
    }
    ```

- **Severity:** P2
  - **File/Symbol:** `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift` -> `CoreAgentAppleConsentReceipt.verifies(with:)`
  - **Issue:** The HMAC signature verification is performed using standard string equality (`signature == self.signature(signingKey:)`).
  - **Why it matters:** Standard string comparison (`==`) is not constant-time and terminates early upon finding a mismatching character. This exposes the consent verification gate to timing attacks, allowing a caller to potentially brute-force valid signatures.
  - **Concrete Fix:** Parse the hex signature strings back to bytes and perform a constant-time comparison (e.g. using `HMAC<SHA256>.isValidAuthenticationCode` or a constant-time comparison helper over byte collections).

---

TEST GAPS:

- **SwiftData Storage Roundtrip Verification:** The tests in `CoreAgentApplePlatformTests` do not execute actual SwiftData `ModelContext` persistence operations. There needs to be an integration-level test that saves a `CoreAgentSwiftDataCheckpointRecord` to an in-memory `ModelContainer`, fetches it back, and verifies that `decodeCheckpoint` still succeeds (to catch precision loss on Date fields).
- **Projection Store Incremental State Merging:** There are no tests asserting that calling `apply(traces:)` multiple times with different trace inputs preserves existing entries in `CoreAgentRunProjectionStore`.
