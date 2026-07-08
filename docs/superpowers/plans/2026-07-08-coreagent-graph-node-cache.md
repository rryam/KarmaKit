# CoreAgent Graph Node Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Swift-native LangGraph-style node caching to `CoreAgentGraph`.

**Status:** Implemented and verified for the graph node-cache slice. The larger LangGraph parity gaps identified during this slice remain open: `Command(update:goto:)`, `update_state` / `bulk_update_state`, first-class executable subgraphs, and deferred nodes.

**Architecture:** Nodes may carry an explicit `CoreAgentGraphCachePolicy<State>` with a caller-defined cache-key function and optional TTL. A compiled graph may receive a `CoreAgentGraphNodeCache<State>` implementation; when both policy and cache exist, the runtime reuses cached node updates, emits an audit-visible cache-hit stream event, and still applies the cached update through the normal reducer path.

**Tech Stack:** Swift 6.4, Swift Testing, existing `CoreAgentGraph` target, no new dependencies.

## Global Constraints

- Preserve Swift-native `Sendable` and actor-friendly API boundaries.
- Do not require graph `State` to be `Codable` or `Hashable`; cache keys are explicit.
- Cache node updates, not whole final graph states.
- Cache hits must not skip reducer semantics, checkpoint writes, or stream audit evidence.
- TTL expiration must fail closed by executing the node again.
- No disk/SwiftData cache in this slice; start with in-memory protocol and actor store.

---

## Task 1: Red Tests For Node Cache Contract

**Files:**
- Modify: `Tests/CoreAgentGraphTests/CoreAgentGraphExecutionTests.swift`
- Modify: `Tests/CoreAgentGraphTests/CoreAgentGraphStreamingTests.swift`

**Interfaces:**
- Future types:
  - `CoreAgentGraphCacheKey`
  - `CoreAgentGraphCachePolicy<State>`
  - `InMemoryCoreAgentGraphNodeCache<State>`
  - `CoreAgentGraphStreamEvent.nodeCacheHit(nodeID:key:step:)`
  - `CoreAgentStateGraph.addNode(_:cachePolicy:operation:)`
  - `CoreAgentStateGraph.compile(..., cache:)`

- [x] **Step 1: Add failing execution tests**

Add tests proving:
- Same cache key avoids re-executing the node on a second invocation.
- Different cache keys re-execute the node.
- TTL `0` expires immediately and re-executes.

- [x] **Step 2: Add failing streaming test**

Add a test proving the second run emits `.nodeCacheHit` and still emits the cached `.updates` event.

- [x] **Step 3: Run red**

Run:

```bash
swift test --skip-update --filter graphNodeCache
```

Expected: compile failure because the cache API does not exist.

Observed: failed to compile on the missing cache API surface before implementation.

## Task 2: Implement CoreAgentGraph Node Cache

**Files:**
- Create: `Sources/CoreAgentGraph/CoreAgentGraphCache.swift`
- Modify: `Sources/CoreAgentGraph/CoreAgentStateGraph.swift`

**Interfaces:**
- `CoreAgentGraphCacheKey`: typed raw string key.
- `CoreAgentGraphCachePolicy<State>`: optional TTL plus key function.
- `CoreAgentGraphCacheEntry<State>`: cached update with stored/expiration dates.
- `CoreAgentGraphNodeCache<State>`: async cache protocol.
- `InMemoryCoreAgentGraphNodeCache<State>`: actor implementation.
- Runtime integration through node metadata, compile cache argument, and stream event.

- [x] **Step 1: Add cache types**

Create `CoreAgentGraphCache.swift` with typed key, policy, entry, protocol, and in-memory actor.

- [x] **Step 2: Wire node policy and compiled cache**

Add cache metadata to `CoreAgentStateGraph.Node`, overload `addNode`, and add a `cache:` parameter to `compile`.

- [x] **Step 3: Reuse cached updates**

In `executeNodes`, compute the key from the node snapshot/context. If a non-expired entry exists, return it as the node update without running the node operation. On miss, run the operation and store the returned update with the policy TTL.

- [x] **Step 4: Emit cache-hit evidence**

Add `.nodeCacheHit(nodeID:key:step:)` to `CoreAgentGraphStreamEvent`. On hit, emit it between task start and task completion; then emit the normal `.updates` event so downstream consumers do not need a separate state path.

- [x] **Step 5: Run green**

Run:

```bash
swift test --skip-update --filter graphNodeCache
swift test --skip-update --filter CoreAgentGraphTests
```

Observed: `swift test --skip-update --filter graphNodeCache` passed 4 tests, and `swift test --skip-update --filter CoreAgentGraphTests` passed 45 tests.

## Task 3: Docs, Ledger, Verification

**Files:**
- Modify: `Documentation/CoreAgentGraph-Runtime.md`
- Modify: `Documentation/DeepAgents-Port-Research-and-Design.md`
- Modify: `Documentation/DeepAgents-Port-Task-Ledger.md`
- Modify: this plan file.

- [x] **Step 1: Document node caching**

Document explicit-key cache policy, TTL semantics, stream audit event, and in-memory-only scope.

- [x] **Step 2: Update ledger**

Add L48 `complete_for_graph_node_cache`.

- [x] **Step 3: Verify**

Run:

```bash
swift test --skip-update --filter graphNodeCache
swift test --skip-update --filter CoreAgentGraphTests
swift test --skip-update
swift build --skip-update
git diff --check
xcrun swift-format lint --strict --recursive Sources/CoreAgentGraph Tests/CoreAgentGraphTests
```

Repo-wide formatter debt outside this slice should be reported separately.

Observed on 2026-07-07:

- `swift test --skip-update` passed.
- `swift build --skip-update` passed.
- `git diff --check` passed.
- `xcrun swift-format lint --strict --recursive Sources/CoreAgentGraph Tests/CoreAgentGraphTests` passed.

## Self-Review

- Spec coverage: adds LangGraph node caching semantics without requiring Python compatibility or implicit pickled hashes.
- Placeholder scan: no TODO/TBD placeholders.
- Type consistency: all planned public types use the `CoreAgentGraph...` namespace and preserve current compile/invoke defaults.
