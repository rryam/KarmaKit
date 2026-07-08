{
  "findings": [
    {
      "severity": "P0",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1192,
      "title": "SQLite Floating-Point Rounding Mismatch in Date Integrity Digest",
      "description": "The checkpointer and store calculate an integrity digest using nanosecond-precision timestamps (via `timeToken(_:)` with `Date`). SQLite stores `Date` values as `REAL` (double-precision floats), which only provides ~53 bits of precision. This causes sub-microsecond precision loss when round-tripping dates. Consequently, when loading saved checkpoints or store records from SQLite after cache eviction, the re-calculated digest mismatches the stored digest, triggering false-positive integrity validation failures.",
      "evidence": "`timeToken` rounds `date.timeIntervalSinceReferenceDate * 1_000_000_000` to `Int64`. `Date` is stored in SwiftData and serialized to SQLite. Upon fetching, the `Date` round-trips through SQLite's double-precision float, losing precision and causing `integrityDigest` to mismatch `checkpointDigest`.",
      "concrete_fix": "Store timestamps as explicit `Int64` milliseconds properties in the `@Model` entities (e.g., `createdAtMs`) instead of `Date` properties, and use these exact `Int64` values to compute the digest."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 1618,
      "title": "Fatal Arithmetic Overflow on Distant Dates",
      "description": "Calling `timeToken(_:)` with `Date.distantFuture` or `Date.distantPast` results in a value that, when multiplied by 1,000,000,000, exceeds the range of `Int64`. This causes a runtime crash due to out-of-bounds Double-to-Int64 conversion.",
      "evidence": "`String(Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded()))` where `date` can be `Date.distantFuture` (~6.3 * 10^19 nanoseconds, exceeding `Int64.max`).",
      "concrete_fix": "Clamp the `timeIntervalSinceReferenceDate` to a safe range before converting to `Int64`, or use millisecond/second precision to prevent overflow."
    }
  ],
  "residual_risks": [
    "Unpredictable query performance on large databases because fields like `checkpointScopeKey` and `storeScopeKey` lack `@Attribute(.indexed)` annotations, causing full table scans."
  ],
  "testing_gaps": [
    "No tests verifying persistence and reload using an on-disk SQLite container (only in-memory contexts are tested, which masks SQLite precision loss due to object caching).",
    "No boundary testing for extreme dates (e.g., `Date.distantFuture`, `Date.distantPast`)."
  ]
}