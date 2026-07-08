# CoreAgent Graph Command And State Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Swift-native LangGraph-style `Command(update:goto:)`, `update_state`, and `bulk_update_state` foundations to `CoreAgentGraph`.

**Status:** Implemented and verified. The remaining graph parity gaps are `Send`, parent-graph command routing, first-class executable subgraphs, and deferred nodes.

**Architecture:** Existing node operations keep returning typed `State` updates. A new command-node API returns `CoreAgentGraphNodeOutput<State>` so nodes can atomically emit an optional typed state update and override their next route. External state surgery is implemented as explicit typed checkpoint updates that always require a checkpointer, an existing checkpoint, and an explicit `asNode` authority.

**Tech Stack:** Swift 6.4, Swift Testing, existing `CoreAgentGraph` target, no new dependencies.

## Global Constraints

- Preserve Swift-native `Sendable` and actor-friendly API boundaries.
- Do not model Python dictionaries, `Send`, or parent-subgraph routing in this slice.
- Command updates and external state updates must flow through the existing reducer.
- Command `goto` targets must be declared through graph builder metadata and fail closed at runtime if undeclared.
- `updateState` and `bulkUpdateState` must require a checkpointer and an existing checkpoint.
- Keep `CoreAgentStateGraph.swift` under the repo's 800-line limit by moving new public types/APIs to focused files where possible.

---

## Task 1: Red Tests For Command And State Update Contracts

**Files:**
- Create: `Tests/CoreAgentGraphTests/CoreAgentGraphCommandTests.swift`

**Interfaces:**
- Future type: `CoreAgentGraphNodeOutput<State>`
- Future type: `CoreAgentGraphStateUpdate<State>`
- Future type: `CoreAgentGraphTaskID`
- Future stream event: `CoreAgentGraphStreamEvent.command(nodeID:goto:step:)`
- Future builder API: `CoreAgentStateGraph.addCommandNode(_:operation:)`
- Future builder API: `CoreAgentStateGraph.addCommandRoutes(from:to:)`
- Future runtime API: `CoreAgentCompiledGraph.updateState(_:asNode:threadID:namespace:checkpointID:)`
- Future runtime API: `CoreAgentCompiledGraph.bulkUpdateState(_:threadID:namespace:checkpointID:)`

- [x] **Step 1: Add command execution tests**

Add tests proving:
- A command node applies its update through the reducer and routes to a declared dynamic target.
- A command `goto: [.end]` bypasses a regular edge from the same node.
- An undeclared command target fails closed before executing the target.

- [x] **Step 2: Add command streaming test**

Add a test proving command routing emits `.command(nodeID:goto:step:)` and still emits the normal typed update event when the command includes an update.

- [x] **Step 3: Add checkpoint state surgery tests**

Add tests proving:
- `updateState` applies a typed update to the latest checkpoint as if it came from `asNode`, saves a child checkpoint, and routes to that node's next static target.
- `bulkUpdateState` applies multiple supersteps in order and saves one checkpoint per superstep.
- State surgery fails without a checkpointer or without an existing checkpoint.

- [x] **Step 4: Run red**

Run:

```bash
swift test --skip-update --filter graphCommand
```

Expected: compile failure because the command/state-update API does not exist.

Observed: compile failed on missing `addCommandNode`, `addCommandRoutes`, command stream event, pending-write command metadata, `CoreAgentGraphStateUpdate`, and state-update APIs.

## Task 2: Implement Command Node Output And Dynamic Routes

**Files:**
- Create: `Sources/CoreAgentGraph/CoreAgentGraphNodeOutput.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraph.swift`

**Interfaces:**
- `CoreAgentGraphNodeOutput<State>.update(_:)`
- `CoreAgentGraphNodeOutput<State>.command(update:goto:)`
- `CoreAgentStateGraph.addCommandNode(_:operation:)`
- `CoreAgentStateGraph.addCommandRoutes(from:to:)`
- `CoreAgentGraphStreamEvent.command(nodeID:goto:step:)`

- [x] **Step 1: Add node output type**

Create a typed output enum that carries either a normal update or a command with optional update and explicit goto endpoints.

- [x] **Step 2: Store command-capable node operations**

Change the internal node operation closure to return `CoreAgentGraphNodeOutput<State>`. Keep existing `addNode` source-compatible by wrapping returned `State` in `.update`.

- [x] **Step 3: Add declared command routes**

Store command route metadata, validate declared route sources/targets at compile time, and include declared command routes in reachability.

- [x] **Step 4: Execute command outputs**

Apply command updates through the existing reducer, emit `.command` before task completion, and use command `goto` endpoints instead of regular/conditional edges for that source node.

- [x] **Step 5: Run green for command tests**

Run:

```bash
swift test --skip-update --filter graphCommand
swift test --skip-update --filter CoreAgentGraphTests
```

Observed: `swift test --skip-update --filter graphCommand` passed 8 tests, and `swift test --skip-update --filter CoreAgentGraphTests` passed 53 tests.

## Task 3: Implement updateState And bulkUpdateState

**Files:**
- Create: `Sources/CoreAgentGraph/CoreAgentGraphStateUpdates.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentGraphTypes.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraph.swift`

**Interfaces:**
- `CoreAgentGraphTaskID`
- `CoreAgentGraphStateUpdate<State>`
- `CoreAgentCompiledGraph.updateState(_:asNode:threadID:namespace:checkpointID:)`
- `CoreAgentCompiledGraph.bulkUpdateState(_:threadID:namespace:checkpointID:)`

- [x] **Step 1: Add state update types**

Add typed state-update request structs with explicit `update`, `asNode`, and optional task identity.

- [x] **Step 2: Expose internal graph runtime helpers**

Make the compiled graph's reducer, checkpointer, node lookup, and next-node helper available to same-module extensions without making them public API.

- [x] **Step 3: Add updateState**

Load the requested or latest checkpoint, apply the update through the reducer, compute next nodes as if `asNode` had just run, save a child checkpoint, and return it.

- [x] **Step 4: Add bulkUpdateState**

Validate non-empty supersteps, apply each superstep sequentially, save one checkpoint per superstep, and return the final checkpoint.

- [x] **Step 5: Run green for state update tests**

Run:

```bash
swift test --skip-update --filter graphCommand
swift test --skip-update --filter CoreAgentGraphTests
```

Observed: `swift test --skip-update --filter graphCommand` passed 8 tests, and `swift test --skip-update --filter CoreAgentGraphTests` passed 53 tests.

## Task 4: Docs, Ledger, Verification

**Files:**
- Modify: `Documentation/CoreAgentGraph-Runtime.md`
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
- Modify: this plan file.

- [x] **Step 1: Document implemented scope**

Document typed command updates, declared dynamic routes, checkpointer-backed state surgery, and explicit exclusions for `Send`, parent graph routing, and first-class executable subgraphs.

- [x] **Step 2: Add L49 ledger row**

Add L49 `complete_for_graph_command_state_update` with exact evidence and remaining parity gaps.

- [x] **Step 3: Verify**

Run:

```bash
swift test --skip-update --filter graphCommand
swift test --skip-update --filter CoreAgentGraphTests
swift test --skip-update
swift build --skip-update
git diff --check
xcrun swift-format lint --strict --recursive Sources/CoreAgentGraph Tests/CoreAgentGraphTests
```

Observed on 2026-07-07:

- `swift test --skip-update --filter graphCommand` passed 8 tests.
- `swift test --skip-update --filter CoreAgentGraphTests` passed 53 tests.
- `swift test --skip-update` passed.
- `swift build --skip-update` passed.
- `git diff --check` passed.
- `xcrun swift-format lint --strict --recursive Sources/CoreAgentGraph Tests/CoreAgentGraphTests` passed.
- Graph source/test file-size check found no files over 800 lines; `CoreAgentStateGraph.swift` is exactly 800 lines after validation split.

## Self-Review

- Spec coverage: covers LangGraph `Command(update:goto:)`, `update_state`, and `bulk_update_state` foundations while explicitly excluding subgraph `Send` semantics.
- Placeholder scan: no TODO/TBD placeholders.
- Type consistency: planned names use the `CoreAgentGraph...` namespace and keep existing `addNode` callers source-compatible.
