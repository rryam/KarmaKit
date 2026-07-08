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
  `CoreAgentGraphNodeOutput.command(update:goto:)`. Command updates flow through
  the normal reducer, declared command routes fail closed when undeclared, and
  command execution emits proof-visible stream events.
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
- LangGraph `Send`, parent-graph command routing, first-class executable
  subgraphs, and deferred nodes.
- LangSmith-style tracing, eval, replay, annotation, dataset, or optimization
  engine.
- SkillOpt curation, skill optimization, harness optimization, or recursive
  self-improvement loops.
- External-provider adapters or Python API compatibility layers.

Those belong to the later slices in
`docs/superpowers/plans/2026-07-05-coreagent-deepagents-port.md`.
