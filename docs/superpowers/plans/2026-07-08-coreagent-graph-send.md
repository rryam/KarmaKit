# CoreAgent Graph Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Swift-native LangGraph `Send` semantics to `CoreAgentGraph` so dynamic fanout can execute the same node multiple times with distinct per-task state and checkpoint-safe replay.

**Architecture:** Replace the internal `[CoreAgentGraphNodeID]` frontier with typed scheduled tasks while preserving `nextNodeIDs` as a compatibility projection. Add `CoreAgentGraphSend<State>` for typed per-task input, checkpointable pending tasks for replay, send-edge selectors for dynamic fanout, and command sends as the Swift equivalent of LangGraph `Command.goto` accepting `Send`. Reducers still own parallel merge semantics; without a reducer, multiple pushed tasks fail closed like existing static fanout.

**Tech Stack:** Swift 6.4, Swift Testing, existing `CoreAgentGraph` target, no new dependencies.

## Global Constraints

- Use TDD: failing Swift Testing coverage must be observed before production code.
- Preserve FoundationModels/CoreAgent-native typed APIs; do not introduce Python `Any` payloads or provider-message abstractions.
- Keep `CoreAgentStateGraph.swift` under the 800-line repository limit by moving `CoreAgentGraphRuntimeContext` into its own file before adding scheduler code.
- Persist enough checkpoint state to replay duplicate same-node sends without rerunning completed pushed tasks.
- Keep `nextNodeIDs` for compatibility, but treat `nextTasks` as authoritative when present.
- Do not add autonomous scheduling, parent-graph routing, first-class executable subgraphs, deferred nodes, or send-specific timeout policy in this slice.
- Do not call unbounded subagent lifecycle cleanup; if delegation is used, record stale handles instead of blocking on close.

---

## Source Grounding

- LangGraph docs currently define `Send` as a dynamic fanout primitive for map-reduce style flows where the downstream node receives a different state per object.
- Current LangGraph source defines `Send(node, arg, timeout?)`; the timeout field is explicitly deferred in this CoreAgent slice.
- LangGraph `Command.goto` can contain node names, `Send`, or sequences of either. CoreAgent keeps existing `goto: [CoreAgentGraphEndpoint]` and adds a source-compatible `sends` field.

## File Structure

- Create: `Sources/CoreAgentGraph/CoreAgentGraphRuntimeContext.swift`
  - Move `CoreAgentGraphRuntimeContext` out of `CoreAgentStateGraph.swift`.
  - Add optional `taskID` to runtime context so pushed tasks can expose stable idempotency markers.
- Create: `Sources/CoreAgentGraph/CoreAgentGraphSend.swift`
  - Add `CoreAgentGraphSend<State>`, `CoreAgentGraphPendingTask<State>`, and internal scheduled-task helpers.
- Modify: `Sources/CoreAgentGraph/CoreAgentGraphNodeOutput.swift`
  - Add `sends` to `CoreAgentGraphNodeCommand<State>` while keeping existing command initializers source-compatible.
- Modify: `Sources/CoreAgentGraph/CoreAgentGraphCheckpoints.swift`
  - Add `taskID` and `commandSends` to pending writes.
  - Add `nextTasks` to checkpoints with backward-compatible Codable decoding from existing `nextNodeIDs`.
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraph.swift`
  - Schedule tasks instead of bare node IDs.
  - Preserve duplicate pushed tasks.
  - Execute sent tasks against sent input while reducer application updates the graph state.
  - Emit send stream evidence.
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraphValidation.swift`
  - Validate declared send-edge targets and include them in reachability.
- Add: `Tests/CoreAgentGraphTests/CoreAgentGraphSendTests.swift`
  - Cover duplicate same-node sends, sent input isolation, reducer requirement, unknown-target failure, command sends, streaming evidence, and checkpoint replay after partial failure.
- Modify: `Documentation/CoreAgentGraph-Runtime.md`
  - Document the typed `Send<State>` surface and explicit non-goals.
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
  - Add L51 completion row after verification.
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`
  - Move `Send` out of the explicit not-implemented list after verification.

## Task 1: Red Tests for Dynamic Send Fanout

**Files:**
- Add: `Tests/CoreAgentGraphTests/CoreAgentGraphSendTests.swift`

**Interfaces:**
- Produces expected future API:
  - `CoreAgentGraphSend<State>`
  - `CoreAgentStateGraph.addSendEdges(from:to:_:)`
  - `CoreAgentGraphRuntimeError.undeclaredSendTarget(source:target:)`

- [ ] **Step 1: Write failing tests**
  - `sendEdgesRunSameNodeMultipleTimesWithDistinctSentState`
  - `sendEdgesRequireReducerForParallelPushedUpdates`
  - `sendEdgesRejectUndeclaredDynamicTarget`

- [ ] **Step 2: Verify red**
  - Run: `swift test --skip-update --filter CoreAgentGraphSendTests`
  - Expected: compile failure because `CoreAgentGraphSend`, `addSendEdges`, and `undeclaredSendTarget` do not exist.

## Task 2: Red Tests for Command Sends, Streaming, and Replay

**Files:**
- Modify: `Tests/CoreAgentGraphTests/CoreAgentGraphSendTests.swift`

**Interfaces:**
- Extends expected future API:
  - `CoreAgentGraphNodeOutput.command(update:goto:sends:)`
  - `CoreAgentGraphStreamEvent.send(source:target:state:taskID:step:)`
  - `CoreAgentGraphCheckpoint.nextTasks`

- [ ] **Step 1: Write failing tests**
  - `commandNodeCanEmitSendsAfterApplyingUpdate`
  - `sendStreamEventsExposeDuplicateTaskEvidence`
  - `sendCheckpointResumePreservesDuplicateTaskInputsAndPendingWrites`

- [ ] **Step 2: Verify red**
  - Run: `swift test --skip-update --filter CoreAgentGraphSendTests`
  - Expected: compile failure because command sends, stream send events, and checkpoint `nextTasks` do not exist.

## Task 3: Implement Typed Send Data and Checkpoint Compatibility

**Files:**
- Create: `Sources/CoreAgentGraph/CoreAgentGraphRuntimeContext.swift`
- Create: `Sources/CoreAgentGraph/CoreAgentGraphSend.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentGraphCheckpoints.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentGraphNodeOutput.swift`

**Interfaces:**
- `CoreAgentGraphSend<State: Sendable>`
- `CoreAgentGraphPendingTask<State: Sendable>`
- `CoreAgentGraphPendingWrite.commandSends`
- `CoreAgentGraphCheckpoint.nextTasks`

- [ ] **Step 1: Move runtime context**
  - Remove `CoreAgentGraphRuntimeContext` from `CoreAgentStateGraph.swift`.
  - Recreate it in `CoreAgentGraphRuntimeContext.swift` with the same public initializer plus optional `taskID`.

- [ ] **Step 2: Add typed send and pending-task models**
  - `CoreAgentGraphSend` stores `nodeID`, `state`, and optional `taskID`.
  - `CoreAgentGraphPendingTask` stores `nodeID`, optional `input`, optional `taskID`, and optional `source`.

- [ ] **Step 3: Add backward-compatible checkpoint encoding**
  - Decode missing `commandSends`, `taskID`, and `nextTasks` as empty/default values.
  - Encode the new fields for fresh checkpoints.

- [ ] **Step 4: Verify compile moves are still red only because runtime behavior is missing**
  - Run: `swift test --skip-update --filter CoreAgentGraphSendTests`
  - Expected: remaining failures point at missing graph APIs or behavior, not syntax errors.

## Task 4: Implement Send Scheduling and Validation

**Files:**
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraph.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraphValidation.swift`

**Interfaces:**
- `CoreAgentStateGraph.SendSelector`
- `CoreAgentStateGraph.SendEdges`
- `CoreAgentStateGraph.addSendEdges(from:to:_:)`

- [ ] **Step 1: Add send-edge registration and compile validation**
  - Validate send sources and declared targets exist.
  - Include send targets in reachability.

- [ ] **Step 2: Replace frontier dedupe with task canonicalization**
  - Regular node tasks remain deduped by node ID.
  - Sent tasks keep duplicates and carry sent input.

- [ ] **Step 3: Execute pushed tasks with sent input**
  - Use sent input for node operation and cache key generation.
  - Apply resulting updates through the graph reducer in canonical task order.

- [ ] **Step 4: Fail closed on undeclared dynamic sends**
  - Runtime selector output must target one of the declared send targets.
  - Command sends must target one of the declared command route node targets.

- [ ] **Step 5: Preserve replay identity**
  - On failure, save retry `nextTasks` and pending writes keyed by task ID.
  - On resume, replay pending writes and retry only failed/not-yet-run tasks with their original sent input.

## Task 5: Verification, Docs, and Ledger

**Files:**
- Modify: `Documentation/CoreAgentGraph-Runtime.md`
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`

- [ ] **Step 1: Focused verification**
  - Run: `swift test --skip-update --filter CoreAgentGraphSendTests`
  - Run: `swift test --skip-update --filter CoreAgentGraphTests`

- [ ] **Step 2: Broad verification**
  - Run: `swift test --skip-update`
  - Run: `swift build --skip-update`
  - Run: `xcrun swift-format lint --strict` on touched Swift files.
  - Run: `git diff --check`
  - Run: touched-file `wc -l` and confirm every touched source file is at or below 800 lines.

- [ ] **Step 3: Documentation**
  - Document typed `Send<State>` and command sends.
  - State that Python-style heterogeneous `Any` send payloads and send timeouts are not implemented in this slice.
  - Add L51 ledger row with verification evidence.

