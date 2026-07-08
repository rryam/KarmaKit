BLOCK

### 1. `Package.swift` — Unsupported Platform Version `.v27`
* **Severity:** P0 (Compile Blocker)
* **Why it matters:** In Swift Package Manager, the `SupportedPlatform` static members (e.g., `.iOS`, `.macOS`, `.visionOS`) do not support a `.v27` version (since version numbers correspond to release versions like iOS 17/18, macOS 14/15, etc.). This causes a fatal package compilation/manifest loading error, preventing any build.
* **Concrete Fix:** Update `Package.swift` platform specifications to use valid, existing platform version members (e.g., `.v17` for iOS/macOS/visionOS or explicitly target standard deployment versions):
```swift
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .visionOS(.v1),
  ],
```

---

### 2. `Sources/CoreAgent/CoreAgentSession.swift` — Corrupted Syntax and Implementation Snippets
* **Severity:** P0 (Compile Blocker)
* **Why it matters:** The code snippet provided under `CoreAgentSession.swift` contains multiple severe compile-blocking syntax errors, including:
  * Truncated/missing property assignments in the `private init`.
  * `await` statements and logic referencing undefined local variables (`runID`, `usage`, `nativeResponse`) executed directly in the body of a synchronous initializer.
  * Attempting to return a `CoreAgentResponse` from an initializer (`return CoreAgentResponse(...)`).
  * Mismatched parentheses and braces (e.g., a trailing `)` on line 640, unmatched `catch` blocks without preceding `do` blocks).
* **Concrete Fix:** Replace the broken snippets with a valid session initializer and run-loop implementation. Ensure `respond(to:)` is an `async throws` method where the run completion/failure lifecycle, plugin notification, and response generation occur, leaving the initializer to only assign stored state properties.

---

### 3. `CoreAgentEngine/InMemoryCoreAgentEngineStore` — Missing Receipt Verification on Readback
* **Severity:** P1 (Contract Gap / Data Integrity)
* **Why it matters:** The system contract explicitly states: *"CoreAgentEngine stores finalized CoreAgentRun evidence, verifies receipts after readback..."* However, the query methods (`trace` and `traces`) read and return trace items directly from memory without verifying their associated `CoreAgentRunReceipt` values. This allows corrupted or tampered runs to be read back undetected.
* **Concrete Fix:** Update `trace(projectID:runID:)` and `traces(projectID:threadID:)` to assert receipt validity using `trace.receipt.verify()`. Omit/discard traces that fail verification:
```swift
  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    guard let trace = tracesByKey[TraceKey(projectID: projectID, runID: runID)]?.trace else {
      return nil
    }
    guard trace.receipt.verify() else { return nil }
    return trace
  }

  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
    tracesByKey.values
      .filter {
        $0.trace.projectID == projectID
          && (threadID == nil || $0.trace.threadID == threadID)
          && $0.trace.receipt.verify()
      }
      .sorted { $0.sequence < $1.sequence }
      .map(\.trace)
  }
```

---

### 4. `CoreAgentSkills/InMemoryCoreAgentSkillStore` — Concurrent Version Collisions and Lost Updates
* **Severity:** P1 (Concurrency / Data Integrity)
* **Why it matters:** `InMemoryCoreAgentSkillStore` allows appending arbitrary versions via `save(_:)`. If multiple optimizer runs execute concurrently for the same skill, they may calculate different edits, increment the version counter to the same target version, and save them. This results in duplicate versions in the history, and since `currentSkill` and `allCurrentSkills` use `.max { $0.version < $1.version }`, one of the updates will be silently ignored (lost update).
* **Concrete Fix:** Introduce version validation in `save(_:)` to reject concurrent edits that conflict with already saved versions. Update the error enum to support version collisions:

Add to `CoreAgentSkillOptimizationError`:
```swift
  case versionCollision(CoreAgentSkillID, Int)
```

Update `InMemoryCoreAgentSkillStore.save(_:)`:
```swift
  public func save(_ skill: CoreAgentSkill) async throws {
    let history = historyByID[skill.id] ?? []
    if history.contains(where: { $0.version == skill.version }) {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }
```

---

### 5. `CoreAgentEngine/InMemoryCoreAgentEngineStore` — Resolved Issues Not Reopened on New Failures
* **Severity:** P1 (Contract Gap)
* **Why it matters:** In `upsertIssue(_:)`, when an issue already exists, the status is resolved to `existing.status` unconditionally. If a previously resolved issue reoccurs in a new run (new contributing run IDs), the status is never automatically updated to `.reopened`. This breaks the contract of issue lifecycle tracking, hiding active bugs.
* **Concrete Fix:** Update `upsertIssue` to transition the status from `.resolved` to `.reopened` if new failure runs are detected:
```swift
  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    if let existing = issuesByID[issue.id] {
      let hasNewRuns = !Set(issue.contributingRunIDs).isSubset(of: existing.contributingRunIDs)
      let nextStatus = (existing.status == .resolved && hasNewRuns) ? CoreAgentEngineIssueStatus.reopened : existing.status

      let merged = CoreAgentEngineIssue(
        id: existing.id,
        projectID: existing.projectID,
        fingerprint: existing.fingerprint,
        title: issue.title,
        contributingRunIDs: issue.contributingRunIDs,
        status: nextStatus,
        firstSeenAt: min(existing.firstSeenAt, issue.firstSeenAt),
        lastSeenAt: max(existing.lastSeenAt, issue.lastSeenAt)
      )
      issuesByID[issue.id] = merged
      return merged
    }
    issuesByID[issue.id] = issue
    return issue
  }
```

---

### 6. `CoreAgentSkills/CoreAgentHarnessOptimizer` — Duplicate Candidate ID Runtime Crash
* **Severity:** P2 (Runtime Reliability)
* **Why it matters:** `Dictionary(uniqueKeysWithValues:)` is used to map candidates. If there are duplicate candidates or duplicate candidate IDs passed to `selectBest`, the application will crash at runtime with a duplicate key fatal error.
* **Concrete Fix:** Use the uniquing initializer variant of `Dictionary` to handle duplicate candidate IDs gracefully without throwing a fatal crash:
```swift
    let candidateByID = Dictionary(
      candidates.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
```
