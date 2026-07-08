BLOCK

## Findings

### 1. `Sources/CoreAgentEngine/CoreAgentEngine.swift` / `InMemoryCoreAgentEngineStore.ingest`, `trace`, `traces` — P1 — receipt verification is not enforced on readback

**Why it matters**

The intended contract says Engine stores finalized run evidence and verifies receipts after readback. The store creates a receipt at ingest time, but `trace(projectID:runID:)` and `traces(projectID:threadID:)` return stored traces without verifying that the stored `receipt` still matches the stored `run`.

The test verifies the receipt externally:

```swift
#expect(readback.receipt.verify())
```

…but that means the contract is caller-enforced rather than store-enforced. Any future store implementation, corruption bug, or bad `CoreAgentEngineTrace` construction could return invalid evidence as if it were trusted.

**Concrete fix**

Make read APIs return only verified traces, or introduce throwing verified-read APIs. For the current protocol shape, returning `nil` / filtering invalid traces is the least invasive:

```swift
public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
  guard let trace = tracesByKey[TraceKey(projectID: projectID, runID: runID)]?.trace else {
    return nil
  }
  guard trace.receipt.verify(), trace.receipt.runID == trace.run.id else {
    return nil
  }
  return trace
}

public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
  tracesByKey.values
    .filter {
      $0.trace.projectID == projectID
        && (threadID == nil || $0.trace.threadID == threadID)
        && $0.trace.receipt.verify()
        && $0.trace.receipt.runID == $0.trace.run.id
    }
    .sorted { $0.sequence < $1.sequence }
    .map(\.trace)
}
```

Also add a negative test that injects or constructs a bad stored trace if possible, or add a test-only corrupting store to prove invalid receipts are rejected on readback.

---

### 2. `Sources/CoreAgentEngine/CoreAgentEngine.swift` / `InMemoryCoreAgentEngineStore.ingest` — P1 — store accepts non-finalized runs despite finalized-evidence contract

**Why it matters**

The intended contract says CoreAgentEngine stores finalized `CoreAgentRun` evidence. `ingest` currently accepts any `CoreAgentRun`, including runs with no terminal event or only partial events.

The current redaction test ingests a run with only `.toolExecutionFailed`:

```swift
events: [
  Self.event(
    runID: runID,
    kind: .toolExecutionFailed,
    ...
  )
]
```

That means the public store can persist incomplete run evidence, which weakens issue scanning, receipt semantics, and “finalized run observer” guarantees.

**Concrete fix**

Validate terminal state in `ingest` before storage. For example:

```swift
public enum CoreAgentEngineStoreError: Error, Equatable, Sendable {
  case nonFinalizedRun(UUID)
  case eventRunIDMismatch(eventID: UUID, eventRunID: UUID, runID: UUID)
}

private func validateFinalized(_ run: CoreAgentRun) throws {
  guard run.events.contains(where: { $0.kind == .runCompleted || $0.kind == .runFailed }) else {
    throw CoreAgentEngineStoreError.nonFinalizedRun(run.id)
  }

  for event in run.events where event.runID != run.id {
    throw CoreAgentEngineStoreError.eventRunIDMismatch(
      eventID: event.id,
      eventRunID: event.runID,
      runID: run.id
    )
  }
}
```

Call it at the start of `ingest`.

Update the redaction test to include a terminal event, e.g. add `.runFailed` with the same secret-bearing evidence, or add a separate unit test asserting non-finalized runs are rejected.

---

### 3. `Sources/CoreAgentEngine/CoreAgentEngine.swift` / `CoreAgentEnginePlugin.coreAgentRunDidFinish` — P1 — ingestion failures are silently swallowed

**Why it matters**

The Engine plugin is the main integration path for finalized run evidence, but it currently discards all ingestion errors:

```swift
_ = try? await store.ingest(run, projectID: projectID, threadID: threadID)
```

If redaction, receipt creation, storage, or a future durable store fails, evidence is silently lost. That violates the “stores finalized CoreAgentRun evidence” contract and creates an observability blind spot.

**Concrete fix**

Make observer delivery able to surface errors, or at minimum expose an explicit failure hook/logger. Since `CoreAgentRunObserver` is currently non-throwing, a minimal fix is to inject an error handler:

```swift
public struct CoreAgentEnginePlugin: CoreAgentSessionPlugin, CoreAgentRunObserver {
  private let onIngestFailure: (@Sendable (CoreAgentRun, any Error) async -> Void)?

  public init(
    identifier: String = "coreagent.engine",
    store: any CoreAgentEngineStore,
    projectID: String,
    threadID: String? = nil,
    onIngestFailure: (@Sendable (CoreAgentRun, any Error) async -> Void)? = nil
  ) {
    ...
    self.onIngestFailure = onIngestFailure
  }

  public func coreAgentRunDidFinish(_ run: CoreAgentRun) async {
    do {
      try await store.ingest(run, projectID: projectID, threadID: threadID)
    } catch {
      await onIngestFailure?(run, error)
    }
  }
}
```

If this framework already has a recorder/error event mechanism available at that point, prefer recording a typed Engine ingestion failure event instead of silent loss.

---

### 4. `Sources/CoreAgentSkills/CoreAgentSkills.swift` / `CoreAgentSkillEdit`, `CoreAgentSkillOptimizer.propose` — P1 — edits are typed but not bounded

**Why it matters**

The intended SkillOpt contract says “typed bounded edits.” The edits are typed, but they are not bounded:

```swift
case replace(target: String, replacement: String)
case append(String)
```

`append` can add arbitrary content of arbitrary size. `replace` can replace a tiny target with an unbounded body. This allows prompt/skill drift and unbounded memory growth, and it undermines the “bounded edit” part of the contract.

**Concrete fix**

Add explicit edit/result limits and enforce them before acceptance. For example:

```swift
public struct CoreAgentSkillEditLimits: Sendable {
  public var maxAppendCharacters: Int
  public var maxReplacementCharacters: Int
  public var maxResultCharacters: Int

  public static let `default` = CoreAgentSkillEditLimits(
    maxAppendCharacters: 2_000,
    maxReplacementCharacters: 4_000,
    maxResultCharacters: 20_000
  )
}
```

Then validate in `apply` or `propose`:

```swift
public enum CoreAgentSkillOptimizationError: Error, Equatable, Sendable {
  ...
  case editTooLarge
  case resultingSkillTooLarge
}

func apply(to body: String, limits: CoreAgentSkillEditLimits) throws -> String {
  switch self {
  case .append(let addition):
    guard addition.count <= limits.maxAppendCharacters else {
      throw CoreAgentSkillOptimizationError.editTooLarge
    }
    let result = body + addition
    guard result.count <= limits.maxResultCharacters else {
      throw CoreAgentSkillOptimizationError.resultingSkillTooLarge
    }
    return result

  case .replace(let target, let replacement):
    guard replacement.count <= limits.maxReplacementCharacters else {
      throw CoreAgentSkillOptimizationError.editTooLarge
    }
    ...
  }
}
```

Also add tests for oversized append, oversized replacement, and oversized final skill body.

---

### 5. `Sources/CoreAgentSkills/CoreAgentSkills.swift` / `CoreAgentSkillOptimizer.propose` + `InMemoryCoreAgentSkillStore` — P1 — accepted edits can race and create duplicate versions / lost updates

**Why it matters**

`propose` performs a read-modify-write sequence across actor calls:

```swift
guard let current = await store.currentSkill(id: proposal.skillID) else { ... }

// compute candidate

try await store.save(next)
```

Two concurrent proposals can both read version `1`, both create version `2`, and both save. `currentSkill` then uses `max` by version, but duplicate versions make the result ambiguous and can lose one accepted edit.

The actor protects individual store methods, but not the full optimization transaction.

**Concrete fix**

Move the read/validate/save transaction into the actor, or add compare-and-swap semantics.

Example CAS-style fix:

```swift
public actor InMemoryCoreAgentSkillStore {
  ...

  public func saveIfCurrentVersion(
    _ skill: CoreAgentSkill,
    expectedCurrentVersion: Int
  ) throws {
    let current = historyByID[skill.id]?.max { $0.version < $1.version }
    guard current?.version == expectedCurrentVersion else {
      throw CoreAgentSkillOptimizationError.concurrentModification(skill.id)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }
}
```

Then in `propose`:

```swift
let expectedVersion = current.version
let next = CoreAgentSkill(... version: expectedVersion + 1 ...)
try await store.saveIfCurrentVersion(next, expectedCurrentVersion: expectedVersion)
```

Add a concurrency test with two simultaneous accepted proposals against the same base skill.

---

### 6. `Sources/CoreAgentSkills/CoreAgentSkills.swift` / `CoreAgentHarnessOptimizer.selectBest` — P1 — harness selection can compare candidates on different held-out suites

**Why it matters**

The harness optimizer computes a mean over whatever evaluations each candidate has:

```swift
let scores = evaluations.filter { $0.candidateID == candidate.id }
let meanScore = scores.map(\.score).reduce(0, +) / Double(scores.count)
```

This allows unfair selection. Example:

- candidate A evaluated only on easy heldout suite, score `0.95`
- candidate B evaluated on hard heldout suite, score `0.80`

A wins despite no shared held-out basis. That weakens the “held-out harness selection” contract.

**Concrete fix**

Require all candidates to have evaluations for the same non-empty held-out suite set, or require a caller-provided required suite set.

Minimal internal fix:

```swift
let expectedSuiteIDs = Set(evaluations.map(\.heldoutSuiteID))
guard !expectedSuiteIDs.isEmpty else {
  throw CoreAgentSkillOptimizationError.missingHarnessEvaluation("all")
}

for candidate in candidates {
  let scores = evaluations.filter { $0.candidateID == candidate.id }
  let suiteIDs = Set(scores.map(\.heldoutSuiteID))

  guard suiteIDs == expectedSuiteIDs else {
    throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidate.id)
  }

  ...
}
```

Better: derive `expectedSuiteIDs` from an explicit `requiredHeldoutSuiteIDs` parameter so unknown/extra evaluations cannot affect selection.

Also reject evaluations for unknown candidate IDs or ignore them consistently and do not include them in `heldoutSuiteIDs`.

---

### 7. `Sources/CoreAgentEngine/CoreAgentEngine.swift` / `CoreAgentEngineIssueScanner.scan` — P2 — issue contributing run order is nondeterministic for equal timestamps

**Why it matters**

The scanner sorts evidence only by `startedAt`:

```swift
groups[fingerprint]?.sorted(by: { lhs, rhs in
  lhs.trace.run.startedAt < rhs.trace.run.startedAt
})
```

The tests create runs with identical `startedAt`, then assert exact contributing run order:

```swift
#expect(issues.map(\.contributingRunIDs) == [
  [Self.uuid(401), Self.uuid(402)],
  [Self.uuid(403)],
])
```

Swift sorting is not guaranteed stable for equal keys. This can make tests brittle and can produce nondeterministic issue evidence ordering.

**Concrete fix**

Add deterministic tie-breakers:

```swift
let evidence = groups[fingerprint]?.sorted { lhs, rhs in
  if lhs.trace.run.startedAt != rhs.trace.run.startedAt {
    return lhs.trace.run.startedAt < rhs.trace.run.startedAt
  }
  return lhs.trace.run.id.uuidString < rhs.trace.run.id.uuidString
}
```

Or make test timestamps distinct.

---

### 8. `Sources/CoreAgentSkills/CoreAgentSkills.swift` / `CoreAgentSkillValidationResult`, `CoreAgentSkillOptimizer.propose`, `CoreAgentHarnessOptimizer.selectBest` — P2 — validation scores are not constrained to finite expected range

**Why it matters**

Scores are plain `Double`. The code accepts any finite or infinite values and does not validate `heldoutSuiteID` is non-empty. `Double.infinity` can pass as an improvement, and malformed validation metadata can be persisted into provenance.

**Concrete fix**

Validate before using scores:

```swift
private func validate(_ validation: CoreAgentSkillValidationResult) throws {
  guard validation.score.isFinite, validation.score >= 0, validation.score <= 1 else {
    throw CoreAgentSkillOptimizationError.invalidValidationScore(validation.score)
  }
  guard !validation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
  }
}
```

Apply equivalent validation to harness evaluations.
