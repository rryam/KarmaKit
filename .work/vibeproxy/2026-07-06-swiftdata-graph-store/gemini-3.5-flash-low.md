VERDICT: **BLOCK**

The package slice cannot compile due to a missing store implementation and truncated helper method. Furthermore, strict `Date` equality checks in digest verification will lead to false-positive corruption detections in production.

---

### FINDINGS

#### P1: Missing `CoreAgentSwiftDataGraphStore` Class Implementation
**Severity:** P1 (Build Blocker)
**Context:** The test suite attempts to instantiate `CoreAgentSwiftDataGraphStore` (lines 2043–2044), but the implementation class is completely missing from the production sources. Additionally, `put` must perform manual replacement (upsert) to prevent duplicate rows for the same namespace/key from accumulating and corrupting `keys(namespace:)` results.

**Fix:** Add the following implementation to `CoreAgentApplePlatform.swift`:

```swift
@MainActor
public final class CoreAgentSwiftDataGraphStore<Value: Codable & Sendable>: CoreAgentGraphStore {
  private let modelContext: ModelContext
  private let rollsBackOnFailure: Bool

  public init(modelContext: ModelContext, rollsBackOnFailure: Bool = false) {
    self.modelContext = modelContext
    self.rollsBackOnFailure = rollsBackOnFailure
  }

  public convenience init(modelContainer: ModelContainer) {
    self.init(modelContext: ModelContext(modelContainer), rollsBackOnFailure: true)
  }

  public func put(
    _ value: Value,
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws {
    let record = CoreAgentGraphStoreRecord(namespace: namespace, key: key, value: value)
    let newRecord = try CoreAgentSwiftDataGraphStoreRecord(record: record)

    let namespaceRaw = namespace.rawValue
    let keyRaw = key.rawValue
    let scopeKey = CoreAgentSwiftDataGraphStoreRecord.scopeKey(namespace: namespaceRaw, key: keyRaw)

    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { rec in
        rec.storeScopeKey == scopeKey && rec.namespace == namespaceRaw && rec.key == keyRaw
      }
    )

    do {
      // Enforce replacement parity with InMemoryCoreAgentGraphStore
      if let existing = try modelContext.fetch(descriptor).first {
        modelContext.delete(existing)
      }
      modelContext.insert(newRecord)
      try modelContext.save()
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func value(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws -> Value? {
    try await record(forKey: key, namespace: namespace)?.value
  }

  public func record(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws -> CoreAgentGraphStoreRecord<Value>? {
    let namespaceRaw = namespace.rawValue
    let keyRaw = key.rawValue
    let scopeKey = CoreAgentSwiftDataGraphStoreRecord.scopeKey(namespace: namespaceRaw, key: keyRaw)

    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { rec in
        rec.storeScopeKey == scopeKey && rec.namespace == namespaceRaw && rec.key == keyRaw
      }
    )

    return try modelContext.fetch(descriptor)
      .compactMap { $0.graphRecord(as: Value.self) }
      .first
  }

  public func removeValue(
    forKey key: CoreAgentGraphStoreKey,
    namespace: CoreAgentGraphStoreNamespace
  ) async throws {
    let namespaceRaw = namespace.rawValue
    let keyRaw = key.rawValue
    let scopeKey = CoreAgentSwiftDataGraphStoreRecord.scopeKey(namespace: namespaceRaw, key: keyRaw)

    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { rec in
        rec.storeScopeKey == scopeKey && rec.namespace == namespaceRaw && rec.key == keyRaw
      }
    )

    do {
      if let existing = try modelContext.fetch(descriptor).first {
        modelContext.delete(existing)
        try modelContext.save()
      }
    } catch {
      recoverAfterFailedMutation()
      throw error
    }
  }

  public func keys(
    namespace: CoreAgentGraphStoreNamespace
  ) async throws -> [CoreAgentGraphStoreKey] {
    let namespaceRaw = namespace.rawValue
    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphStoreRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphStoreRecord> { rec in
        rec.namespace == namespaceRaw
      }
    )
    let records = try modelContext.fetch(descriptor)
    return records.map { CoreAgentGraphStoreKey($0.key) }.sorted()
  }

  private func recoverAfterFailedMutation() {
    guard rollsBackOnFailure else { return }
    modelContext.rollback()
  }
}
```

---

#### P2: Truncated Method `checkpointRecords` in `CoreAgentSwiftDataGraphCheckpointer`
**Severity:** P2 (Compile Error)
**Context:** At line 1375, the body of `checkpointRecords` terminates immediately after initializing the `FetchDescriptor`, resulting in a compilation error because no return value is provided.

**Fix:** Complete the method by performing the fetch:

```swift
  private func checkpointRecords(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace
  ) throws -> [CoreAgentSwiftDataGraphCheckpointRecord] {
    let threadID = threadID.rawValue
    let namespace = namespace.rawValue
    let scopeKey = CoreAgentSwiftDataGraphCheckpointRecord.scopeKey(
      threadID: threadID,
      namespace: namespace
    )
    let descriptor = FetchDescriptor<CoreAgentSwiftDataGraphCheckpointRecord>(
      predicate: #Predicate<CoreAgentSwiftDataGraphCheckpointRecord> { record in
        record.checkpointScopeKey == scopeKey
          && record.threadID == threadID
          && record.namespace == namespace
      },
      sortBy: [
        SortDescriptor(\.step, order: .reverse),
        SortDescriptor(\.createdAt, order: .reverse),
        SortDescriptor(\.storedAt, order: .reverse),
      ]
    )
    return try modelContext.fetch(descriptor) // Added
  }
```

---

#### P2: Strict Floating-Point Date Comparison Mismatches Fail Closed
**Severity:** P2 (Data Integrity / Operational Risk)
**Context:** In `checkpoint(as:)` (line 1160), strict date comparison is enforced:
`checkpoint.createdAt == createdAt`.
CoreData SQLite stores dates as 64-bit floating-point offsets (seconds since 2001). The JSON codec (`CoreAgentSwiftDataGraphCodec`) may format the date as an ISO8601 string or numeric timestamp. Minor rounding discrepancies during serialization round-tripping will cause `==` to evaluate to `false`, treating healthy records as corrupt.

**Fix:** Compare dates with a sub-millisecond tolerance threshold:

```swift
    guard checkpoint.id.rawValue == checkpointID,
      checkpoint.threadID.rawValue == threadID,
      checkpoint.namespace.rawValue == namespace,
      checkpoint.parentCheckpointID?.rawValue == parentCheckpointID,
      checkpoint.step == step,
      abs(checkpoint.createdAt.timeIntervalSince(createdAt)) < 0.001 // Fix: Tolerance window
    else {
      return nil
    }
```

---

#### P3: Floating-Point Instability in `timeToken` Generation
**Severity:** P3 (Robustness)
**Context:** When computing digests via `integrityDigest` (lines 1172, 1276), `timeToken` is used to convert dates to stable strings. If `timeToken` formats dates with high floating-point precision directly (e.g. `String(date.timeIntervalSinceReferenceDate)`), small precision variations during database readbacks can lead to different token strings, invalidating the digest.

**Fix:** Normalize all dates by truncating to millisecond precision before calculating digests:

```swift
static func timeToken(_ date: Date) -> String {
  // Truncate to millisecond resolution to ensure string serialization stability
  let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
  return String(ms)
}
```

---

### TEST GAPS

1. **Duplicate Checkpoint ID Resolution Test**: Add a test where two checkpoints with the same `id` are saved sequentially. Assert that `checkpoint(id:)` retrieves the one with the latest `storedAt` (matching the `InMemoryCoreAgentGraphCheckpointer` last-in-wins behavior).
2. **Sub-Millisecond Date Tolerance Test**: Save a checkpoint created with `Date()` (which contains fractional seconds). Ensure that fetching the checkpoint back passes integrity validation and does not return `nil`.
3. **Graph Store Key Sorting Test**: Write a test verifying that `keys(namespace:)` returns keys in ascending alphabetical order, even if they were added in random or reverse-alphabetical sequence.
4. **Graph Store Replacement Integrity Test**: Add a test executing `put()` multiple times for the same namespace and key. Fetch the matching DB rows directly using a raw query and assert that only a single row exists in the database.