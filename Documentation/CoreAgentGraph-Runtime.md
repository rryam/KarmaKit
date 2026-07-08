# CoreAgentGraph Runtime

Created: 2026-07-05

`CoreAgentGraph` is the Swift-native graph runtime foundation for the larger
Deep Agents, LangGraph, SkillOpt, and embedded Engine port. It is deliberately
limited to graph execution contracts; it does not expose Deep Agents, SkillOpt,
or LangSmith-style Engine products.

## Implemented

- `CoreAgentStateGraph<State>` builder with typed node IDs, `START`/`END`
  endpoints, regular edges, and conditional edges.
- Compile-time validation for duplicate nodes, missing entry points, unknown
  edge endpoints, selectorless conditionals, invalid conditional targets,
  orphaned nodes, and invalid recursion limits.
- `CoreAgentCompiledGraph<State>.invoke` and `.stream` with deterministic
  super-step execution. Parallel node completion order does not define state or
  stream update order.
- Explicit reducer/channel support through `CoreAgentGraphChannel<Value>`.
  Parallel fanout is rejected unless the graph was initialized with an explicit
  reducer/channel.
- Built-in overwrite, append, and native Foundation Models
  `[Transcript.Entry]` transcript-history reducer helpers.
- LangGraph-style node caching through explicit `CoreAgentGraphCachePolicy`
  keys and optional TTLs, with `InMemoryCoreAgentGraphNodeCache` as the first
  actor-backed cache implementation. Cached node updates still flow through the
  normal reducer, checkpoint, and stream paths.
- LangGraph-style command node outputs through
  `CoreAgentGraphNodeOutput.command(update:goto:sends:)`. Command updates flow
  through the normal reducer, declared command routes fail closed when
  undeclared, and command execution emits proof-visible stream events.
- Swift-native LangGraph `Send` fanout through `CoreAgentGraphSend<State>` and
  `CoreAgentStateGraph.addSendEdges(from:to:_:)`. Sends schedule typed pushed
  tasks, so the same target node can run multiple times with distinct sent
  `State` values while all updates merge back through the graph reducer.
  Command outputs can also carry typed sends. Checkpoints persist authoritative
  `nextTasks` and task-ID-keyed pending writes while `nextNodeIDs` remains a
  compatibility projection.
- First-class executable subgraphs through
  `CoreAgentStateGraph.addSubgraph(_:_:)` and
  `addNode(_:subgraph:)`. A compiled `CoreAgentCompiledGraph<State>` runs as one
  parent node super-step, receives the parent task state as its initial state,
  and returns the child graph's final state as the parent node update.
- Subgraph checkpoint history is isolated under a nested
  `CoreAgentGraphCheckpointNamespace` derived from the parent namespace,
  subgraph node ID, and pushed task ID when present. Parent streams surface
  child graph events through `CoreAgentGraphStreamEvent.subgraph`, tagged with
  that nested namespace and the parent step.
- Parent-graph command routing through explicit `.parent(...)` command
  endpoints. A subgraph node can route to a parent-declared command target;
  undeclared parent routes fail closed with
  `CoreAgentGraphRuntimeError.undeclaredParentCommandTarget`, and the command
  update merges through the parent reducer before the parent target runs.
- Deferred node scheduling through the typed `addNode(_:defer:...)` builder
  flag. Deferred nodes still participate in normal compile-time reachability
  validation, but execution holds them until all non-deferred scheduled tasks
  across regular, command, and `Send` fanout branches have drained.
- Checkpointing by thread and namespace with parent checkpoint lineage,
  checkpoint history, time-travel resume, forked child lineages, and pending
  writes for failed super-steps.
- Checkpointer-backed `updateState` and `bulkUpdateState` APIs for typed state
  surgery. Both require an existing checkpoint and explicit `asNode` authority,
  apply updates through the reducer, and save child checkpoints.
- Separate in-memory `CoreAgentGraphStore<Value>` key/value protocol shape for
  long-lived graph data that is not part of per-thread checkpoint history.
- Codable resume commands and typed interrupts with stable interrupt IDs,
  checkpointed resume points, proof-visible interrupt events, and deterministic
  interrupt ordering.
- Runtime context metadata: run ID, thread ID, checkpoint namespace, current
  step, resume command, and custom stream-event writer.
- Stream events for values, updates, task start, task completion, task failure,
  node cache hits, commands, checkpoints, interrupts, and custom payloads.

## Not Implemented In This Slice

- Deep Agents todo/planning/filesystem/subagent behavior.
- Python-style heterogeneous `Any` send payloads and send-specific timeout
  policy. CoreAgent `Send` is generic over one `State: Sendable` type.
- LangSmith-style tracing, eval, replay, annotation, dataset, or optimization
  engine.
- SkillOpt curation, skill optimization, harness optimization, or recursive
  self-improvement loops.
- External-provider adapters or Python API compatibility layers.

Those belong to the later slices in
`docs/superpowers/plans/2026-07-05-coreagent-deepagents-port.md`.
