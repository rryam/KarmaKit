# Review Prompt: CoreAgentDeep Graph HITL Executable Dispatch

You are reviewing a Swift package at `/Users/basitmustafa/Documents/GitHub/coreagent`.

Scope: review the L32 change that adds manifest-bound execution of reviewed graph-level HITL executable actions.

Files to inspect:
- `Sources/CoreAgentDeep/CoreAgentDeepHITLExecution.swift`
- `Sources/CoreAgentDeep/CoreAgentDeepHITL.swift`
- `Tests/CoreAgentDeepTests/CoreAgentDeepHITLExecutionTests.swift`
- `Documentation/CoreAgentDeep-Runtime.md`
- `Documentation/DeepAgents-Port-Task-Ledger.md`

Background:
- `CoreAgentDeepHITLExecutableAction` is the graph-level reviewed action emitted by the HITL resolver. It carries a reviewed/requested tool name and an executable tool name, plus requested and executable argument JSON.
- This slice intentionally adds only a reusable execution boundary, not automatic `CoreAgentSession` receipt emission. The docs should make that explicit.
- Final execution must authorize and invoke the executable target manifest, not merely trust the reviewed target.
- Tool invocation context should be bound to the executable target so downstream auditing sees the final manifest and target name.
- Duplicate executable manifest names must fail closed.
- Missing manifests and malformed JSON must fail before backend execution.
- Invocation identity should be deterministic but should change when the run ID, graph tool call ID, executable target, manifest digest, or executable args change.
- Result audit evidence should preserve redacted requested/executable JSON plus stable digests without leaking raw credentials.

Ask:
Find correctness, security, concurrency, Swift API, or test-contract issues. Focus on bugs and missing durable contracts, not style preferences. Do not suggest broad architecture beyond this slice unless the current change makes it necessary.

Verification already run locally before review:
- `swift test --skip-update --filter CoreAgentDeepHITLExecutionTests`
- `swift test --skip-update --filter CoreAgentDeepTests`
- `swift test --skip-update`
- `swift build --skip-update`
- `git diff --check`

Important project rule:
VibeProxy is not a review tool. It is only for exercising local model/API endpoints. Formal review here should be read-only code review.
