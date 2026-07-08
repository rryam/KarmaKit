You are re-reviewing the settled L30 Swift package change in `/Users/basitmustafa/Documents/GitHub/coreagent`.

Review slice: L30 `CoreAgentDeepTodoWriteGuard` CoreAgent run/model-turn wiring.

Important process constraint:
- VibeProxy is not a formal review tool. It is only for live model/API endpoint exercise. This pass is adversarial code review only.

Prior Cursor Composer 2.5 review found a valid correctness gap:
- Invalid `write_todos` status validation happened before guard reservation, so an invalid scoped attempt did not consume the per-turn guard.
- It also noted bare `CoreAgentDeepTodoTool` lifecycle cleanup was weaker than the task tool pattern.

Fixes now present:
- `CoreAgentDeepTodoTool.call` reserves any available scoped guard before `typedTodos()` validation.
- `CoreAgentDeepTodoTool` conforms to `CoreAgentRunLifecycleTool` and clears a finished run scope in `coreAgentRunDidFinish(_:)`.
- Tests now cover:
  - invalid scoped attempt consumes the turn scope before validation;
  - direct guarded calls without `turnID` remain deliberately unguarded;
  - lifecycle cleanup clears a finished run scope;
  - plugin-scoped second write fails before mutation;
  - later CoreAgent runs can write again.

Files to inspect:
- `Sources/CoreAgentDeep/CoreAgentDeepTodos.swift`
- `Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift`
- `Sources/CoreAgent/CoreAgentToolInvocationContext.swift`
- `Sources/CoreAgent/CoreAgentPolicy.swift`
- `Sources/CoreAgent/CoreAgentPlugin.swift`
- `Sources/CoreAgent/CoreAgentSession.swift`
- `Documentation/CoreAgentDeep-Runtime.md`
- `Documentation/DeepAgents-Port-Task-Ledger.md`

Verification already run after the fixes:
- `swift test --skip-update --filter CoreAgentDeepTodoTests` passed 10 tests.
- `swift test --skip-update --filter CoreAgentDeepTests` passed 102 tests.

Review asks:
1. Verify whether the prior invalid-then-valid scoped guard gap is actually fixed.
2. Look for new regressions from reserving before validation.
3. Check lifecycle cleanup for plugin and bare-tool registration, including failure paths and same-run reset races.
4. Check whether tests assert durable typed contracts rather than provider prose or incidental text.
5. Return findings ordered by severity with file/line references. If there are no blocking findings, say so explicitly and list residual risks.
