I will wait for the `swift test` execution to complete.
I will wait for the `CoreAgentDeepTests` execution to complete.
I will wait for the test suite to execute with the newly added test.
I have completed the adversarial code review of the `CoreAgentDeepTodoWriteGuard` wiring. 

There are **no blocking findings** (no P0/P1 compile, runtime, or concurrency bugs). The implementation is robust, thread-safe under Swift Concurrency, and correctly handles both governed session runs and direct calls.

The full review details have been written to the artifact: [todo_write_guard_review.md](file:///Users/basitmustafa/.gemini/antigravity-cli/brain/60ea79ef-dd4d-42bb-9d9a-c9d52cb9db94/todo_write_guard_review.md).

### Summary of Findings & Risks

#### P2 (Low Severity) — Lifecycle Limitation during Run Retries
* **File Reference**: [`Sources/CoreAgent/CoreAgentSession.swift:L559-658`](file:///Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgent/CoreAgentSession.swift#L559-L658) / [`Sources/CoreAgentDeep/CoreAgentDeepTodos.swift:L137-168`](file:///Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgentDeep/CoreAgentDeepTodos.swift#L137-L168)
* **Risk**: If the user overrides defaults to enable post-tool-call retries (`allowsRetryAfterToolInvocation = true`) and a transient model failure occurs after a successful `write_todos` call, the retry attempt (reusing the same `runID`) will fail with `multipleWritesInTurn`.
* **Mitigation**: Under default settings, retry is disabled after tool calls, so this is currently a minor residual risk.

#### P3 (Informational) — Direct Call Guard Bypass Test Gap (Resolved)
* **File Reference**: [`Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift:L103-124`](file:///Users/basitmustafa/Documents/GitHub/coreagent/Tests/CoreAgentDeepTests/CoreAgentDeepTodoTests.swift#L103-L124)
* **Status**: **Resolved**. There was a minor unit test coverage gap for the direct-call bypass case where no `turnID` closure is provided. I added a new test `writeTodosAllowsMultipleDirectCallsWhenTurnIDIsNil` which compiles and passes successfully alongside the rest of the 99 package tests.

---

### Review Asks Mapping

1. **Correctness & Concurrency**: The actor-isolated design of `CoreAgentDeepTodoWriteGuard` is concurrency-safe. Validation of raw input strings is executed *before* reservation and mutation, ensuring invalid states do not consume the turn's single write capability.
2. **Durable Contracts in Tests**: Tests assert direct store state and typed framework/domain errors (`LanguageModelSession.ToolCallError` and `CoreAgentDeepTodoError.multipleWritesInTurn`). No test scrapes provider logs or text transcripts.
3. **Plugin Run-Scope Reset Races**: Because `CoreAgentDeepTodoWriteGuard` uses unique `runID` UUID strings, concurrent overlapping runs across different sessions use distinct keys. `resetTurnScope` is guaranteed to be called during `didComplete` or `didFail` unwinding, avoiding any leakage or race conditions.
4. **Honest Direct-Call Behavior**: When run outside of a governed session with no `turnID` closure, the tool correctly returns a `nil` turn ID and bypasses the write guard entirely. No fake turn IDs are injected or scraped from transcripts.
