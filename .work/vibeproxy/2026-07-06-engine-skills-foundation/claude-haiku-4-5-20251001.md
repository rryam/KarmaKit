# BLOCK

## Findings

### P1: CoreAgentEngineRedactionPolicy regex DoS vulnerability
**File/Symbol:** `Sources/CoreAgentEngine/CoreAgentEngine.swift:73-88`

**Severity:** P1 (Security)

**Why it matters:** The redaction patterns use unanchored regexes that can experience catastrophic backtracking on malicious input. The pattern `#"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#` with `[^\s,;]+` can backtrack severely on input like `api_key=` followed by many spaces and non-matching characters.

**Concrete fix:**
```swift
public static let standard = CoreAgentEngineRedactionPolicy { value in
  var result = value
  let patterns: [(String, String)] = [
    (#"(?i)bearer\s+[a-z0-9._~+/=-]{1,256}"#, "Bearer [REDACTED]"),
    (#"(?i)\bsk-[a-z0-9_-]{8,128}\b"#, "[REDACTED_API_KEY]"),
    (#"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]{1,256}"#, "$1=[REDACTED]"),
  ]
  for (pattern, replacement) in patterns {
    result = result.replacingOccurrences(
      of: pattern,
      with: replacement,
      options: .regularExpression
    )
  }
  return result
}
```

Add bounded quantifiers (`{1,256}`) to prevent exponential backtracking on long input sequences.

---

### P1: CoreAgentEngineIssueScanner fingerprint collision risk
**File/Symbol:** `Sources/CoreAgentEngine/CoreAgentEngine.swift:222-235`

**Severity:** P1 (Data Integrity)

**Why it matters:** The fingerprint construction uses `joined(separator: "|")` on user-controlled `error_type` and `tool` attributes. An attacker or malformed event can craft `error_type="foo|bar"` to collide with a different error type's fingerprint, causing unrelated failures to merge into a single issue.

**Concrete fix:**
```swift
private struct FailureEvidence {
  let trace: CoreAgentEngineTrace
  let fingerprint: String
  let title: String

  init?(trace: CoreAgentEngineTrace) {
    guard let failed = trace.run.events.first(where: { $0.kind == .runFailed }) else {
      return nil
    }
    let errorType = failed.attributes["error_type"] ?? "unknown"
    let tool = failed.attributes["tool"] ?? failed.attributes["tool_name"] ?? "none"
    self.trace = trace

    // Use length-prefixed encoding to prevent collision
    let parts = [
      failed.kind.rawValue,
      errorType,
      tool,
    ]
    let encoded = parts.map { "\($0.count):\($0)" }.joined(separator: "|")
    self.fingerprint = encoded
    self.title = "\(failed.kind.rawValue): \(errorType) / \(tool)"
  }
}
```

Use length-prefixed fields to make delimiters unambiguous.

---

### P2: CoreAgentSkillEdit.replace silent no-op on zero-width targets
**File/Symbol:** `Sources/CoreAgentSkills/CoreAgentSkills.swift:91-102`

**Severity:** P2 (Data Integrity)

**Why it matters:** The check `guard !target.isEmpty` prevents empty string replacement, but a malicious or broken proposal could use a whitespace-only target like `" "` that appears many times. The `components(separatedBy:)` will split into many parts, causing the `count == 2` guard to fail silently and reject a valid edit.

**Concrete fix:**
```swift
func apply(to body: String) throws -> String {
  switch self {
  case .append(let addition):
    return body + addition
  case .replace(let target, let replacement):
    let trimmed = target.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw CoreAgentSkillOptimizationError.emptyReplacementTarget
    }
    let parts = body.components(separatedBy: target)
    guard parts.count == 2 else {
      throw CoreAgentSkillOptimizationError.replacementTargetNotUnique(target)
    }
    return parts[0] + replacement + parts[1]
  }
}
```

Trim whitespace from the target before the empty check to reject whitespace-only replacements explicitly.

---

### P2: InMemoryCoreAgentSkillStore recordRejected missing await/actor isolation
**File/Symbol:** `Sources/CoreAgentSkills/CoreAgentSkills.swift:163-167`

**Severity:** P2 (Concurrency)

**Why it matters:** `recordRejected` is defined without `public` and without `async`, but it mutates actor state. The caller `CoreAgentSkillOptimizer.propose` calls it with `await` (line 154), but the function should be declared `public async` to be properly isolated and safe.

**Concrete fix:**
```swift
public func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID) async {
  var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  memory.rejectedEdits.append(rejected)
  memoryByID[skillID] = memory
}
```

Add `public` and `async` keywords, and update the call site in `CoreAgentSkillOptimizer.propose` (line 154) accordingly.

---

### P2: CoreAgentEngineTrace receipt does not capture ingestion time
**File/Symbol:** `Sources/CoreAgentEngine/CoreAgentEngine.swift:14-22`

**Severity:** P2 (Data Integrity)

**Why it matters:** The `CoreAgentRunReceipt` is computed from the redacted run at ingestion time, but the receipt itself does not include `ingestedAt`. If an attacker modifies the stored trace later, the receipt cannot prove when the trace was actually recorded. The receipt should cryptographically bind the ingestion timestamp.

**Concrete fix:**
```swift
@discardableResult
public func ingest(
  _ run: CoreAgentRun,
  projectID: String,
  threadID: String? = nil
) async throws -> CoreAgentEngineTrace {
  let redactedRun = redactionPolicy.redact(run: run)
  let ingestedAt = Date()
  let trace = try CoreAgentEngineTrace(
    projectID: projectID,
    threadID: threadID,
    run: redactedRun,
    receipt: CoreAgentRunReceipt(run: redactedRun, ingestedAt: ingestedAt),
    ingestedAt: ingestedAt
  )
  // ...
}
```

Pass `ingestedAt` to `CoreAgentRunReceipt` so the receipt can bind the timestamp. (Requires updating `CoreAgentRunReceipt` definition in CoreAgent to accept and hash the timestamp
