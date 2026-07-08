## Verdict: **CONDITIONAL GO** — no blocking correctness findings

The prior **invalid-then-valid scoped guard gap is fixed** in implementation. Residual risks are mostly test-coverage and documented scope tradeoffs, not new logic bugs.

---

## 1. Prior gap — **fixed**

Reservation now happens before `typedTodos()` whenever a scoped turn ID is available:

```116:122:Sources/CoreAgentDeep/CoreAgentDeepTodos.swift
  public func call(arguments: CoreAgentDeepWriteTodosArguments) async throws -> String {
    if let writeGuard, let scopedTurnID = await currentTurnID() {
      try await writeGuard.reserveWrite(turnID: scopedTurnID)
    }
    let todos = try arguments.typedTodos()
    await store.replace(with: todos)
```

Unit test `writeTodosGuardConsumesTurnScopeBeforeValidation` (lines 79–107) proves: invalid status → `invalidStatus("blocked")`, then valid retry → `multipleWritesInTurn("turn-1")`, store stays empty.

Plugin path uses the same `call` via `CoreAgentToolInvocation.withCurrent` in `CoreAgentGovernedTool` (`CoreAgentPolicy.swift` 542–564), with scope `runID.uuidString.lowercased()` (`CoreAgentDeepTodos.swift` 133–137).

---

## 2. Reserve-before-validation regressions — **none blocking**

| Concern | Assessment |
|--------|------------|
| Invalid attempt consumes slot | **Intentional**; matches docs (`CoreAgentDeep-Runtime.md` 23–25) |
| Store mutation on invalid input | **Still safe** — `typedTodos()` throws before `replace` |
| Second `reserveWrite` on same scope | **Still safe** — actor serializes; throws before validation |
| Empty `todos` | Consumes one scoped write and clears store — consistent with “one call per scope” |
| `writeGuard` + no scope (`turnID` nil, no invocation context) | **Still deliberately unguarded** — tested at 134–155 |

No new correctness hole from reordering.

---

## 3. Lifecycle cleanup — **sound**

**Plugin path** (`CoreAgentDeepTodos.swift` 161–170): `didComplete` / `didFail` → `resetTurnScope`.

**Bare tool path** (96, 125–127): `CoreAgentRunLifecycleTool` → `coreAgentRunDidFinish` → same reset.

**Session wiring** (`CoreAgentSession.swift` 61–62, 610, 647, 798, 835, 1047–1050): lifecycle tools collected from `tools + plugins.flatMap(\.tools)`; `finishRunLifecycleTools` runs on **both** success and failure after `completePlugins` / `failPlugins`.

**Failure paths:** Tool errors → run catch → `failPlugins` + `finishRunLifecycleTools`. Plugin `didComplete` throwing → catch still runs `failPlugins` + `finishRunLifecycleTools`. Todos plugin `didComplete`/`didFail` do not throw, so no extra risk there.

**Same-run reset races:** `CoreAgentSession` serializes runs via session lease; per-run UUID keys; double reset (plugin + lifecycle hook) is idempotent. No leak/race found.

**Task-tool parity:** Matches `CoreAgentDeepSubagentsPlugin` pattern (plugin + `CoreAgentRunLifecycleTool`).

---

## 4. Test contract quality — **good, one integration gap**

**Durable contracts asserted:**
- `CoreAgentDeepTodoError.invalidStatus` / `multipleWritesInTurn(turnID)` (typed, not prose)
- `CoreAgentDeepTodoStore.todos()` readback
- Enum raw values and tool name literals
- Plugin scope: `turnID == run.id.uuidString.lowercased()` (214)
- `LanguageModelSession.ToolCallError` wrapping in plugin test (210–211)
- `argumentsJSON` as structured input to `RecordedLanguageModel`, not transcript scraping

**`COREAGENT_DEEP_TODOS_UPDATED_V1`** (line 32) is a stable protocol marker, not provider prose — acceptable.

**Gaps (non-blocking):**
- No **plugin-session** test for invalid-then-valid in one `respond()` (unit test covers equivalent logic with explicit `turnID` closure only)
- Lifecycle test calls `coreAgentRunDidFinish` directly (157–183), not `CoreAgentSession` + `session.tools` registration
- No explicit `didFail` / failed-run cleanup test (covered indirectly by session failure path + lifecycle hook)

---

## Findings by severity

### CRITICAL
None.

### IMPORTANT

**I1 — Plugin integration test gap for invalid-then-valid same run**
`Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift`
Behavior is fixed at tool level (79–107) and proven for two valid plugin writes (185–218), but not for `RecordedLanguageModel` invalid status then valid retry in one `respond()`. Low regression risk given shared `call`, but the prior Cursor finding explicitly asked for this scenario at plugin boundary.

**I2 — `allowsRetryAfterToolInvocation` + scoped guard (documented tradeoff)**
`CoreAgentSession.swift` 698–700, `CoreAgentDeepTodos.swift` 117–118
Guard keys on `runID`, not model-attempt boundary. With `allowsRetryAfterToolInvocation: true`, a post-tool model retry in the same run cannot call `write_todos` again. Docs describe run-level scope; config interaction is not tested. Product-consistent, but hosts enabling retries should know.

### MINOR

**M1 — “Direct calls when turn ID is nil” test name is narrow**
`CoreAgentDeepTodoTests.swift` 134–155
Unguarded only when **both** `turnID` closure is nil **and** `CoreAgentToolInvocation.current` is absent. Bare registration in `session.tools` **is** guarded via invocation context. Docs (`CoreAgentDeep-Runtime.md` 30–31) are correct; test name could mislead.

**M2 — Redundant cleanup (harmless)**
Plugin `resetTurnScope` plus `coreAgentRunDidFinish` both clear the same key. Idempotent; slightly redundant.

**M3 — `writtenTurnIDs` growth if lifecycle never runs**
Same class of risk as task budget registry if process dies mid-run. Acceptable for v0.

---

## Residual risks (explicit)

1. Plugin-bound invalid-then-valid not covered end-to-end in session tests.
2. Retry-after-tool-invocation config vs one-write-per-run semantics untested.
3. Shared `CoreAgentDeepTodoStore` across sessions: last writer wins; guard does not cross-session serialize (expected).
4. Custom `turnID` closure cannot be set through `CoreAgentDeepTodosPlugin` ergonomic path — manual `CoreAgentDeepTodoTool` construction only (documented).

---

## Summary

| Review ask | Result |
|-----------|--------|
| Prior guard gap fixed? | **Yes** — reserve before validation; test proves invalid burns scope |
| New regressions from reorder? | **None blocking** — behavior change is intentional and store-safe |
| Lifecycle cleanup? | **Sound** for plugin, bare tool, success, and failure paths |
| Tests use durable contracts? | **Yes** — minor integration gaps only |

**No blocking findings.** Ship-ready for L30 contract intent, with optional hardening: plugin invalid-then-valid test, session-registered lifecycle test, and retry-config note in public API docs.
