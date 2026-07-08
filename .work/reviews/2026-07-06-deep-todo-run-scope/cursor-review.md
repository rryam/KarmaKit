## Verdict: **CONDITIONAL GO** — no P0 blockers for the stated L30 contract, but one important correctness gap and several API/test gaps should be fixed before calling the slice done.

The core wiring is sound: governed tools get `CoreAgentToolInvocation.current.runID` via `@TaskLocal`, the guard is actor-serialized, plugin integration tests bind scope to `CoreAgentRun.id`, and docs honestly describe unguarded direct-call behavior. I do **not** see a reset/lifecycle race that lets a second governed write succeed within the same run.

---

## Findings (by severity)

### IMPORTANT

**1. Invalid `write_todos` does not consume the turn guard; a later valid call in the same run can succeed**

```116:122:Sources/CoreAgentDeep/CoreAgentDeepTodos.swift
  public func call(arguments: CoreAgentDeepWriteTodosArguments) async throws -> String {
    let todos = try arguments.typedTodos()
    if let writeGuard, let scopedTurnID = await currentTurnID() {
      try await writeGuard.reserveWrite(turnID: scopedTurnID)
    }
    await store.replace(with: todos)
```

`reserveWrite` runs only after `typedTodos()` succeeds. An invalid status throws first, so the guard slot is never taken. A second governed call in the same `respond()` with valid todos will pass and mutate state.

That conflicts with the stated contract (“a second `write_todos` call in the same CoreAgent run/model turn fails”) if “call” means any tool invocation, not only a successful one. It is also a realistic model failure mode (bad status, then correction).

**Fix direction:** reserve before argument validation, or treat any governed invocation as consuming the scope.

**Test gap:** no coverage for invalid-then-valid in a governed/plugin run. Existing invalid-status test uses no guard and no `CoreAgentToolInvocation` context (`Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift:35-50`).

---

### MINOR

**2. `writeGuard` without resolvable scope silently disables guarding (API footgun)**

```118:134:Sources/CoreAgentDeep/CoreAgentDeepTodos.swift
    if let writeGuard, let scopedTurnID = await currentTurnID() {
      try await writeGuard.reserveWrite(turnID: scopedTurnID)
    }
    ...
  private func currentTurnID() async -> String? {
    if let turnID {
      return await turnID()
    }
    return CoreAgentToolInvocation.current?.runID.uuidString.lowercased()
  }
```

If `writeGuard` is non-`nil` but there is no host `turnID` closure and no `CoreAgentToolInvocation.current`, multiple writes are allowed. That matches the documented “unguarded unless host supplies scope” rule (`Documentation/CoreAgentDeep-Runtime.md:17-27`), but the API shape suggests protection that is not active.

Concrete bypass: `plugin.todoTool.call(...)` outside `CoreAgentSession` has a guard instance but no scope.

**Recommendation:** document prominently on `CoreAgentDeepTodoTool.init`, and add a test that `writeGuard` + direct call without `turnID` allows two writes.

---

**3. Lifecycle cleanup exists only on the plugin path, not on bare tool registration**

```157:167:Sources/CoreAgentDeep/CoreAgentDeepTodos.swift
  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    await todoTool.resetTurnScope(completion.runID.uuidString.lowercased())
    return []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    await todoTool.resetTurnScope(failure.runID.uuidString.lowercased())
    return []
  }
```

`CoreAgentDeepTaskTool` also implements `CoreAgentRunLifecycleTool` for cleanup when registered directly in `session.tools`. `CoreAgentDeepTodoTool` does not. Registering it directly with a `writeGuard` will grow `writtenTurnIDs` until manual `resetTurnScope` / `resetAll`.

Not a functional bypass across runs (each `respond()` gets a fresh UUID), but inconsistent with the task-tool pattern and a long-lived-process leak.

---

**4. Scope is CoreAgent run (`respond()`), not per native model attempt**

Default scope is `CoreAgentToolInvocation.current.runID` (`CoreAgentDeepTodos.swift:133`, `CoreAgentPolicy.swift:542-564`). That is coarser than a Foundation Models retry/attempt boundary. With `allowsRetryAfterToolInvocation: true`, a retried model attempt in the same run would still be blocked after one successful write.

Default config disables that retry path (`CoreAgentTypes.swift:138`), so this is residual, not a current default bug. Worth documenting that “model turn” here means CoreAgent run ID.

---

**5. Plugin does not expose custom `turnID` overrides**

`CoreAgentDeepTodosPlugin` always builds `CoreAgentDeepTodoTool(store:writeGuard:)` without a `turnID` closure (`CoreAgentDeepTodos.swift:145-154`). Custom scopes require constructing `CoreAgentDeepTodoTool` manually. Docs mention host `turnID` for direct/custom scopes, but the ergonomic plugin path cannot override scope.

---

### Testing / contract quality

**What tests do well (durable, not brittle):**
- Typed errors: `CoreAgentDeepTodoError.invalidStatus`, `multipleWritesInTurn(turnID)`
- Typed store readback via `CoreAgentDeepTodoStore.todos()`
- Plugin scope binding: `turnID == run.id.uuidString.lowercased()` (`CoreAgentDeepTodoTests.swift:129-132`)
- State preserved after rejected second write (`CoreAgentDeepTodoTests.swift:133-135`)
- Cross-run allowance via two `session.respond` calls (`CoreAgentDeepTodoTests.swift:138-167`)
- `RecordedLanguageModel` JSON is fixture input, not parsed provider output

**Missing durable coverage:**
- Invalid-then-valid in same governed run (important)
- Direct `writeGuard` without resolvable scope is unguarded
- Plugin `didFail` cleanup after guard rejection (low urgency because new runs use new UUIDs)
- Bare `CoreAgentDeepTodoTool` in `session.tools` lifecycle cleanup
- No test that guard is skipped when `CoreAgentToolInvocation.current == nil` despite non-nil `writeGuard`

---

## Reset / overlap analysis (review ask #3)

**No race or bypass found for overlapping runs.**

| Mechanism | Effect |
|---|---|
| `CoreAgentSession.acquireSessionLease()` | Blocks concurrent `respond()` on the same session (`CoreAgentSession.swift:1412-1416`) |
| Fresh `runID` per `respond()` | New runs never collide on guard keys (`CoreAgentSession.swift:543`) |
| `CoreAgentDeepTodoWriteGuard` actor | Serializes `reserveWrite`; concurrent same-scope calls cannot both pass |
| `didComplete` / `didFail` reset | Runs only after run termination (`CoreAgentSession.swift:594-646`, `1000-1044`); cannot clear scope mid-run |
| Reset purpose | Memory cleanup of `writtenTurnIDs`; correctness across runs comes from unique run UUIDs |

Early reset cannot reopen the same run because plugin completion/failure happens after the model loop ends and tool execution has finished.

---

## Direct-call honesty (review ask #4)

**Documented honestly.** `Documentation/CoreAgentDeep-Runtime.md:17-27` states:
- Governed CoreAgent path binds to `CoreAgentToolInvocation.current.runID`
- Direct calls outside CoreAgent are unguarded unless host supplies `turnID`
- Plugin completion/failure clears completed/failed run scopes

Implementation matches documentation. The main gap is API discoverability (finding #2), not hidden behavior.

---

## What looks correct

- `CoreAgentToolInvocation` is typed, `@TaskLocal`, set only in `CoreAgentGovernedTool` (`CoreAgentToolInvocationContext.swift:22-34`, `CoreAgentPolicy.swift:542-564`) — no transcript parsing
- Guard rejects second write before `store.replace` on success path
- Invalid status on unguarded/direct path rejects before mutation
- Plugin exposes `write_todos` through `CoreAgentSessionPlugin.tools`
- Completion/failure symmetry matches `CoreAgentDeepSubagentsPlugin` cleanup pattern

---

## Residual risks (non-blocking)

1. **`@concurrent` + `@TaskLocal`:** Integration test proves propagation in the harness today; no dedicated unit test isolates TaskLocal inheritance under `@concurrent`.
2. **Shared `CoreAgentDeepTodoStore` across sessions:** Last writer wins; guard does not serialize cross-session store access (expected for shared store).
3. **Explicit shared `turnID` across runs:** Host-managed scopes must reset between runs themselves.
4. **Formal reviewer gate:** Ledger notes Cursor Composer 2.5 review blocked by auth; that is process, not code defect.

---

## Recommended next steps

1. Move `reserveWrite` before `typedTodos()`, or count any governed invocation attempt.
2. Add plugin-session test: invalid `write_todos` then valid `write_todos` in one `respond()` → second call must throw `multipleWritesInTurn`.
3. Add direct-call test: `writeGuard` present, no `turnID`, no `CoreAgentToolInvocation` → two writes allowed (documents contract).
4. Optionally align with task tool: implement `CoreAgentRunLifecycleTool` on `CoreAgentDeepTodoTool`, or document that lifecycle cleanup requires `CoreAgentDeepTodosPlugin`.

**Blocking findings:** none for the core L30 governed-path contract, contingent on accepting the invalid-then-valid gap as a known limitation. I would not mark L30 fully complete until finding #1 is fixed or explicitly accepted.
