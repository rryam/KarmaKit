You are reviewing a focused Swift package change in `/Users/basitmustafa/Documents/GitHub/coreagent`.

Review slice: L30 `CoreAgentDeepTodoWriteGuard` CoreAgent run/model-turn wiring.

User/project constraints:
- No brittle production shortcuts. Durable contracts must be typed/schema-backed, not provider transcript parsing or one-run text matching.
- VibeProxy is not a formal review tool. It is only for live model/API endpoint exercise when needed. This review should be adversarial code review only.
- Formal review targets are `agy` Gemini 3.5 Flash and Cursor Composer 2.5.
- The change must stay Swift-native and FoundationModels/CoreAgent-native.

Files to inspect:
- `Sources/CoreAgentDeep/CoreAgentDeepTodos.swift`
- `Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift`
- `Sources/CoreAgent/CoreAgentToolInvocationContext.swift`
- `Sources/CoreAgent/CoreAgentPolicy.swift`
- `Sources/CoreAgent/CoreAgentPlugin.swift`
- `Sources/CoreAgent/CoreAgentSession.swift`
- `Documentation/CoreAgentDeep-Runtime.md`
- `Documentation/DeepAgents-Port-Task-Ledger.md`

Intended behavior:
- `CoreAgentDeepTodoTool` still supports explicit host-supplied `turnID` for custom/direct scopes.
- `CoreAgentDeepTodosPlugin` exposes `write_todos` to `CoreAgentSession` and, when the tool is called through CoreAgent's governed tool path, derives the default guard scope from `CoreAgentToolInvocation.current.runID.uuidString.lowercased()`.
- A second `write_todos` call in the same CoreAgent run/model turn fails before mutating typed todo state.
- A later `CoreAgentSession.respond` run can write todos again.
- Direct unmanaged tool calls outside CoreAgent remain unguarded unless the host provides a `turnID`; do not invent transcript parsing or a fake global turn ID.
- Plugin completion/failure reset the completed/failed run scope for cleanup.

Verification already run before review:
- `swift test --skip-update --filter CoreAgentDeepTodoTests`
- `swift test --skip-update --filter CoreAgentDeepTests`
- `swift test --skip-update`

Review asks:
1. Find correctness, concurrency, authorization, lifecycle, or Swift API design bugs in the L30 implementation.
2. Check that the tests assert durable contracts rather than incidental model/provider output.
3. Check whether plugin run-scope reset on success/failure creates any race or bypass with overlapping runs.
4. Check whether the default direct-call behavior is honest and documented.
5. Return findings ordered by severity with file/line references. If there are no blocking findings, say so explicitly and list residual risks.
