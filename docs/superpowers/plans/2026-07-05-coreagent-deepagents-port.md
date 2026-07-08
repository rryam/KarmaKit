# CoreAgent Deep Agents Port Implementation Plan

Date: 2026-07-05
Status: Historical implementation plan; current progress is tracked in the task ledger on `codex/coreagent-graph-runtime`
Design doc: `/Users/basitmustafa/Documents/GitHub/coreagent/Documentation/DeepAgents-Port-Research-and-Design.md`
Task ledger: `/Users/basitmustafa/Documents/GitHub/coreagent/Documentation/DeepAgents-Port-Task-Ledger.md`

## Guardrails

- Do not implement production code until the design is approved.
- Use a feature branch from `main`; do not work directly on `main`.
- Keep PRs small and behavioral.
- Start every implementation slice with failing tests.
- Preserve Foundation Models-native types: `LanguageModelSession`, `Prompt`,
  `Transcript`, `Tool`, `GeneratedContent`, and `Generable`.
- Do not port Python API shapes where they fight Swift or Foundation Models.
- Do not ship broad docs/changelog claims before executable proof exists.
- Do not reuse PR #1 code unless the specific file/pattern passes the design
  contract and new tests.

## Baseline

Verified on `main` at `6fbd7ed`:

- `swift test --skip-update` passed.
- `swift build --skip-update` passed.

PR #1 at `c830678` failed to compile. It is not a merge base.

## Branch

After approval:

```bash
git switch main
git pull --ff-only
git switch -c codex/coreagent-graph-runtime
```

If `main` has moved, rerun:

```bash
swift test --skip-update
swift build --skip-update
```

## Slice 1: CoreAgentGraph

### 1.1 Package and Empty Target

Red:

- Add `CoreAgentGraphTests` import/build smoke tests for the new product.
- Add tests that currently fail because `CoreAgentGraph` does not exist.

Green:

- Add `CoreAgentGraph` product and target depending only on `CoreAgent`.
- Add `CoreAgentGraphTests`.
- Add minimal public module file.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphTests
swift build --skip-update
```

### 1.2 Graph Builder and Compile Validation

Red:

- Test duplicate node rejection.
- Test missing entry point rejection.
- Test orphan node rejection.
- Test edge to missing node rejection.
- Test conditional edge target validation.
- Test recursion limit validation.

Green:

- Implement:
  - `CoreAgentGraphNodeID`
  - `CoreAgentGraphEdge`
  - `CoreAgentGraphCompileError`
  - `CoreAgentStateGraph<State>`
  - `CoreAgentCompiledGraph<State>`

Refactor:

- Keep the public builder small.
- Keep dynamic values out of generic typed state.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphCompileTests
```

### 1.3 State Channels and Reducers

Red:

- Test overwrite reducer.
- Test append reducer.
- Test reducer conflict ordering across same super-step with randomized node
  completion order.
- Test final state, stream order, and pending-write recovery remain identical
  across repeated runs where parallel nodes finish in different wall-clock
  orders.
- Test native transcript/history append reducer with `Transcript.Entry`.

Green:

- Implement `CoreAgentGraphChannel<Value>` and reducer protocols/closures.
- Implement typed state update application.
- Define deterministic super-step update ordering. Default to canonical
  node-ID/task-ID ordering; allow parallel completion order to affect latency,
  not state. If a future channel opts into unordered parallel reduction, its
  reducer must declare the required algebraic guarantees.
- Add `Overwrite` equivalent as an explicit update wrapper only if needed.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphReducerTests
```

### 1.4 Super-Step Execution

Red:

- Test `START -> A -> B -> END`.
- Test two parallel nodes in one super-step both apply updates.
- Test inactive/halt termination.
- Test recursion limit error.
- Test conditional branch selection at runtime.
- Test conditional default/no-match behavior.
- Test explicit `END` routing from a conditional edge.
- Test invalid branch output fails with a typed graph error.
- Test multi-target fanout only if the API explicitly supports it; otherwise
  test that multi-target output is rejected.

Green:

- Implement `invoke` and `stream` execution over compiled graph.
- Use an actor for mutable run state.
- Use `TaskGroup` for ready nodes in the same super-step only when node
  functions are `Sendable` and updates can be reduced deterministically.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphExecutionTests
```

### 1.5 Streaming

Red:

- Test values stream emits full snapshots.
- Test updates stream emits node updates.
- Test task stream emits node start/end/failure.
- Test stream event order is stable when parallel nodes complete in different
  wall-clock orders.
- Test checkpoint stream emits checkpoint IDs when a checkpointer is attached.
- Test custom event writer.

Green:

- Implement `CoreAgentGraphStreamEvent<State>`.
- Implement `AsyncThrowingStream` or custom `AsyncSequence`.
- Include run ID, thread ID, super-step, node ID, and checkpoint metadata.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphStreamingTests
```

### 1.6 Checkpointer Contract

Red:

- Test save latest by thread ID.
- Test get specific checkpoint ID.
- Test list history newest first.
- Test parent checkpoint link.
- Test checkpoint namespace.
- Test resume from a specific checkpoint ID rather than latest.
- Test fork from a checkpoint creates a new child lineage without overwriting
  the parent.
- Test namespace isolation for same thread/checkpoint IDs.
- Test state history readback includes checkpoint metadata and parent lineage.
- Test pending writes recovery when one node in a super-step fails.

Green:

- Implement:
  - `CoreAgentGraphCheckpoint`
  - `CoreAgentGraphCheckpointID`
  - `CoreAgentGraphThreadID`
  - `CoreAgentGraphCheckpointNamespace`
  - `CoreAgentGraphCheckpointer`
  - `CoreAgentGraphStore`
  - `InMemoryCoreAgentGraphCheckpointer`
- Add in-memory `CoreAgentGraphStore` if the first implementation needs no
  cross-thread durable values; otherwise provide a no-op implementation that
  still locks the protocol shape. Do not merge Slice 1 with checkpointer APIs
  that make later store separation impossible without breaking ABI.
- Store channel versions, versions seen, checkpoint metadata, parent config,
  and pending writes.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphCheckpointTests
```

### 1.7 Interrupt and Resume

Red:

- Test interrupt persists state and returns a typed interrupt event.
- Test resume payload is consumed by the interrupted node.
- Test interrupt calls are not reordered.
- Test side effects before interrupt require idempotency markers.

Green:

- Implement:
  - `CoreAgentGraphInterrupt`
  - `CoreAgentGraphCommand`
  - `CoreAgentGraphResumeValue`
- Restrict resume payloads to `Codable & Sendable`.
- Emit proof-visible events for interrupted, resumed, and invalid-resume states.

Verify:

```bash
swift test --skip-update --filter CoreAgentGraphInterruptTests
swift test --skip-update
swift build --skip-update
```

Completion criteria for Slice 1:

- All graph tests pass.
- Existing tests pass.
- `CoreAgentGraph` documentation states only implemented behavior.
- No Deep/Skill/Engine public product is introduced in this PR.

## Slice 2: CoreAgentDeep

Start only after Slice 1 is merged or deliberately continued on the same
approved branch.

Red first:

- Todo tool protocol-literal tests.
- Filesystem canonical containment tests, including `..` and symlink escape.
- Filesystem default-deny tests.
- Filesystem read/write/list/delete permission tests.
- Filesystem first-match precedence tests.
- Absolute path handling tests.
- Denied-operation audit event tests.
- Plugin context injection tests using `RecordedLanguageModel`.
- Tool approval denial tests.
- Dynamic-profile sensitive-tool bypass tests: Deep must reject profile-owned
  sensitive tools unless an explicit governed tool or proven approval/audit
  boundary is configured.
- Context offload tests for oversized tool output.
- Subagent isolation tests with separate transcript/checkpoint keys.
- Subagent audit-link tests: parent run events link child run IDs and receipt
  hashes without injecting child transcript content into the parent prompt.

Implementation:

- Add `CoreAgentDeep` target depending on `CoreAgent` and `CoreAgentGraph`.
- Implement deep todo state as typed Codable state.
- Implement filesystem backend and permissions.
- Filesystem policy is default-deny with explicit read/write/list/delete
  permissions, canonical containment after resolving symlinks where possible,
  documented symlink race expectations, and typed deny events.
- Implement context offload as plugin/tool-observer integration.
- Extend CoreAgent governed tool observation only if current event surface is
  insufficient.
- Implement `CoreAgentSubagent` as isolated `CoreAgentSession` factory.

Verify:

```bash
swift test --skip-update --filter CoreAgentDeepTests
swift test --skip-update
swift build --skip-update
```

## Slice 3: CoreAgentEngine

Red first:

- Real `CoreAgentRun` ingestion test.
- Receipt verification after store/readback.
- Project/status issue filter tests.
- Redaction boundary tests.
- Typed secret-field tests for prompt segments, tool arguments, tool outputs,
  metadata, events, receipts, files, export payloads, and evaluator examples.
- Canary secret tests using values that do not match common token/API-key
  regexes.
- Retention/deletion and file-protection tests.
- Export-consent tests.
- Failed-run issue clustering test.

Implementation:

- Add `CoreAgentEngine` target depending only on `CoreAgent`.
- Add local trace store protocol and in-memory implementation first.
- Add SQLite only after store conformance tests pass.
- If plugin completion cannot access real run evidence, extend CoreAgent's
  observer/plugin contract in a small preceding commit.
- Add typed issue, evaluator, dataset-example, proposed-fix, and scan-state
  models.
- Define redaction as typed policy first, regex as a best-effort supplement
  only.

Verify:

```bash
swift test --skip-update --filter CoreAgentEngineTests
swift test --skip-update
swift build --skip-update
```

## Slice 4: CoreAgentSkills and SkillOpt

Red first:

- Skill registry load/curation tests.
- Progressive disclosure tests.
- Rollout evidence schema tests.
- Edit operation budget tests.
- Held-out validation gate tests.
- Rejected edit memory tests.
- Slow-update protected-region tests.
- Meta-skill memory tests.
- `best_skill.md` export and resume tests.
- Split immutability and leakage detection tests.
- Scorer/evaluator version metadata tests.
- Deterministic replay fixture tests for accepted and rejected optimizer steps.

Implementation:

- Add `CoreAgentSkills` target depending on `CoreAgent`.
- Keep skill store separate from user memory, but borrow scope/provenance
  concepts from `CoreAgentMemory`.
- Implement deterministic scorer and recorded-model fixtures before model-based
  optimizers.
- Add Foundation Models/Evaluations framework adapter after core contracts pass.

Verify:

```bash
swift test --skip-update --filter CoreAgentSkillsTests
swift test --skip-update
swift build --skip-update
```

## Slice 5: Integration Product

Red first:

- Import smoke test for trace-only `CoreAgentEngine`.
- Import smoke test for integrated kit.
- Recorded end-to-end deep-agent sample test with todo, filesystem, subagent,
  trace ingestion, and no network.

Implementation:

- Add optional `CoreAgentAgenticKit` target depending on Graph, Deep, Skills,
  and Engine.
- Keep convenience wiring here, not in lower-level products.

Verify:

```bash
swift test --skip-update
swift build --skip-update
```

## Delegation Plan

Use subagents/workers after design approval where write scopes are disjoint:

- Worker A: `Sources/CoreAgentGraph` and `Tests/CoreAgentGraphTests`.
- Worker B: design-review/code-review only for graph checkpoint semantics.
- Worker C: source drift audit against latest Deep Agents/LangGraph/SkillOpt
  before starting later slices.

Do not delegate cross-cutting API naming or CoreAgentSession contract changes
without explicit integration review.

## Review Gates

Before each PR:

```bash
swift test --skip-update
swift build --skip-update
git diff --stat
```

Then run adversarial review focused on:

- Foundation Models-native type preservation.
- checkpoint/resume correctness.
- tool policy and filesystem containment.
- privacy/redaction.
- brittle tests or string-shape assertions.

## Definition Of Done

A slice is done only when:

- New failing tests were added first and now pass.
- Existing tests pass.
- Public docs match implemented behavior.
- No broad claims are made for unimplemented future slices.
- Review findings are resolved or explicitly rejected with evidence.
