# Deep Agents, LangGraph, SkillOpt, and Engine Research Design

Date: 2026-07-05
Repo: `/Users/basitmustafa/Documents/GitHub/coreagent`
Target PR audited: https://github.com/24601/coreagent/pull/1
PR head audited: `origin/cursor/deepagents-langgraph-port-1b12` at `c830678`
Base audited: `main` at `6fbd7ed`

## Status

This document is the design gate for the requested port. It is intentionally
implementation-ready, but it is not an implementation approval by itself.

The `superpowers:brainstorming` and `superpowers:test-driven-development` gates
apply: production code should start only after this design is approved, and each
implementation slice must start with failing tests.

## Executive Decision

Do not merge PR #1. Do not patch it into shape.

PR #1 is useful only as an intent inventory and as a negative architecture
sample. It does not compile under the local Swift 6.4 toolchain, and the deeper
problems are not localized:

- The graph runtime is shallow and misses LangGraph's durable super-step,
  checkpoint, pending-writes, interrupt, resume, time-travel, and stream
  contracts.
- The deep-agent layer builds a parallel message abstraction instead of staying
  native to Foundation Models `Prompt`, `Transcript`, `Tool`,
  `GeneratedContent`, and `Generable`.
- Middleware-mutated system prompts do not reach the actual
  `LanguageModelSession` request.
- Post-tool middleware and human approval hooks are declared but not wired into
  CoreAgent's deterministic tool policy path.
- Engine ingestion records empty synthetic runs instead of real CoreAgent run
  evidence.
- SkillOpt and harness optimization are mostly string heuristics without
  held-out gates, typed edit operations, realistic rollout evidence, or durable
  optimizer memory.

The right path is a fresh, staged port that preserves CoreAgent's current
Foundation Models-native contract.

## Current Source Reality

The current package is intentionally narrow:

- `CoreAgent`: native `LanguageModelSession` harness, checkpointing,
  observability, tool policy, plugin seams.
- `CoreAgentMemory`: optional scoped memory over the native session plugin
  model.
- `CoreAgentTestSupport`: `RecordedLanguageModel` and deterministic model tests.
- `CoreAgentProviders`: optional provider integrations behind SPM traits.

Current main verification:

- `swift test --skip-update` passed on `main` with 63 tests.
- `swift build --skip-update` passed on `main`.
- PR #1 failed `swift build --skip-update` and `swift test --skip-update`
  before tests could run.

Current CoreAgent invariants to preserve:

- CoreAgent accepts Foundation Models types directly.
- CoreAgent does not define another provider, message, tool, schema, or
  agent-loop abstraction unless the new layer is explicitly a higher-level
  optional product.
- Checkpoints store native `Transcript`, with lossy checkpoint content rejected
  by default.
- Plugin context is injected as deterministic prompt context and sanitized out
  before checkpointing.
- Tool permissioning runs through `CoreAgentToolPolicy` before execution.
- Observability events are typed, redacted, and receipt-verifiable.

## External Currentness

Current research was performed on 2026-07-05 from primary sources where
available.

Latest stable package versions observed:

- Deep Agents: `deepagents 0.6.12`, released 2026-06-25. A `0.7.0a3`
  prerelease exists, but stable should be the compatibility target unless the
  user explicitly chooses prerelease behavior.
- LangGraph Python: `langgraph 1.2.7`, released 2026-06-30.
- LangSmith SDK: `langsmith 0.9.7`, released 2026-07-02.
- SkillOpt: `v0.2.0`, released 2026-07-02.

The configured Gemini deep-research helper could not run because no Gemini key
was configured and `op whoami` reported no 1Password account in this shell.
The research below is therefore primary-source web, repository, PyPI/GitHub,
YouTube caption, and local code research, not a Gemini deep-research report.

## What To Port

### LangGraph Contract

Port the durable runtime ideas:

- `StateGraph`-style builder with compile-time graph validation.
- State channels with independent reducers.
- Nodes, normal edges, conditional edges, and explicit entry/end points.
- Conditional routing semantics, including selected branch, default/no-match
  behavior, explicit `END` routing, multi-target fanout only if declared, and
  invalid branch output failures.
- Pregel-style super-step execution where ready nodes in the same step may run
  concurrently.
- Deterministic update application for nodes in the same super-step. Either
  apply updates in a canonical node-ID/task-ID order, or restrict parallel
  channels to reducers that declare the needed algebraic guarantees
  (associative/commutative/idempotent as appropriate). Do not let wall-clock
  completion order define graph state, stream order, or pending-write recovery.
- Node policies for cacheable deterministic work. Swift must use explicit
  cache keys instead of implicit Python pickle/hashes, optional TTLs, and
  proof-visible cache-hit stream events.
- Stream events for values, updates, tasks, checkpoints, interrupts, debug, and
  custom payloads.
- Checkpointer and store separation.
- Thread IDs, checkpoint namespaces, checkpoint IDs, parent checkpoint links,
  state history, and time-travel/fork semantics.
- Slice 1 should include the graph store protocol shape even if the first store
  implementation is only in-memory. The ABI must leave room for cross-thread
  long-term store data that is separate from per-thread checkpoints.
- Pending node writes for fault tolerance inside a super-step.
- Interrupt and `resume` semantics with JSON/Codable-safe payload boundaries.
- Runtime context that carries thread metadata, cancellation, stream writer,
  checkpoint/store access, and recursion counters.

Do not port Python shapes:

- `TypedDict`, Pydantic, `Annotated`, decorators, `Runnable`, Python message
  classes, msgpack/jsonplus/pickle, or Python config dictionaries as the Swift
  API.

Swift shape:

- Prefer value types, actors, `Sendable`, `AsyncSequence`, `Codable`, and
  strongly typed channels.
- If a dynamic channel map is needed for an escape hatch, keep it behind a
  typed `CoreAgentGraphValue` boundary and do not use it for native transcript
  state.
- Provide native transcript reducers for `Transcript.Entry`/history rather than
  flattening conversation history to strings.

### Deep Agents Contract

Port the harness behaviors:

- Task planning with a durable todo tool and the public status literals
  `pending`, `in_progress`, and `completed`.
- Virtual filesystem with pluggable backends and canonical path containment.
- Declarative filesystem permissions.
- Context offloading and summarization for large tool outputs and long runs.
- Skills as progressively disclosed Markdown documents, loaded only when
  relevant.
- Subagents as isolated CoreAgent sessions that return one final handoff,
  keeping intermediate tool traces out of the parent context.
- Human-in-the-loop review for sensitive tools through CoreAgent's governed
  tool path, preserving upstream decision names `approve`, `edit`, `reject`,
  and `respond`. `reject` and `respond` are synthetic tool-output paths, not
  post-execution denials.
- Typed streaming of messages, tool calls, values, delegated tasks, and
  checkpoints.
- Parent-child audit linkage: subagent transcripts stay out of parent prompt
  context, but parent events must retain child run IDs and receipt/root-hash
  references so delegated work remains auditable.

Do not port unsafe defaults:

- No arbitrary shell execution by default.
- No hidden global filesystem write access.
- No generic string-only message state.
- No middleware that claims to approve a tool after the native tool already ran.

Swift shape:

- `CoreAgentDeep` should be a higher-level harness over `CoreAgentSession`, not
  a replacement session runtime.
- Before-model context should use `CoreAgentSessionPlugin.prepare` context
  blocks or profile-owned dynamic context, depending on session mode.
- Tool approval should use `CoreAgentToolPolicy`.
- Deep HITL should use an additive pre-authorization intervention policy over
  CoreAgent's governed tools. Existing allow/deny policy remains the final
  authorization gate before execution.
- Tool observation/offload should be implemented by extending the existing
  governed tool/observer surface if needed, not by dead post-tool hooks.
- Subagents should be explicit configurations with isolated tools, instructions,
  checkpoint keys, metadata, and return schemas.
- Dynamic-profile mode must fail closed for sensitive Deep tools unless the
  app supplies explicit governed tools or another proven approval/audit
  boundary. Profile-owned tools are native Foundation Models tools and are not
  wrapped by CoreAgent's explicit-model `CoreAgentToolPolicy` path today.

### SkillOpt Contract

Port the optimizer mechanics:

- Skill document as the trainable text artifact.
- Explicit train/validation/test split.
- Rollout evidence containing prompt, transcript/tool trajectory, verifier
  feedback, score, task metadata, and final output.
- Reflection over failures and successes separately.
- Structured candidate edit operations: add, delete, replace, and protected
  slow-update region changes.
- Learning-rate budget measured by edit count and/or delta size, not whole
  document length.
- Aggregation, ranking, clipping, and candidate application.
- Held-out validation gate with accept/reject/new-best states.
- Split immutability, leakage checks, scorer/version metadata, and deterministic
  replay fixtures so optimizer gains cannot come from test contamination or
  evaluator drift.
- Rejected edits as negative signal.
- Slow update protected region for epoch-level momentum.
- Meta-skill optimizer memory that never mutates the target skill directly.
- `best_skill.md` export and resumable run state.

Swift shape:

- `CoreAgentSkills` owns skill documents, registries, curation, and optimizer
  protocols.
- Skill artifacts should be versioned, scoped, and stored through explicit
  stores. Reuse the memory product's scope/provenance ideas where possible, but
  do not overload user long-term memory as the optimizer store.
- Use deterministic scorer protocols and `RecordedLanguageModel`-based fixtures
  first. Foundation Models/Evaluations framework integrations come after the
  core loop is testable.

### LangSmith Engine Contract

Port the closed-loop improvement workflow:

- Real run traces, trace trees, token/cost/latency metadata, tool events,
  failure events, feedback, datasets, evaluators, and issue states.
- Issue clustering from trace evidence, not generic string matching.
- Root-cause diagnosis tied to contributing trace IDs and evaluator evidence.
- Proposed fixes as typed artifacts with proof requirements.
- Offline examples and regression evaluators created from production trace
  inputs.
- Online evaluator deployment states.
- Issue lifecycle: open, ignored, resolved, reopened.
- Scheduled/ad hoc scans with budgets and explicit paused/disabled states.
- Optional PR creation only after a sandboxed branch run and evaluator proof.

Swift shape:

- `CoreAgentEngine` should start as local, privacy-preserving trace storage and
  analysis over `CoreAgentRun` and `CoreAgentRunReceipt`.
- Cloud export, LangSmith adapters, GitHub PR creation, and model-powered issue
  fixing should be opt-in adapters.
- The plugin path must ingest the actual `CoreAgentRun`, not a synthetic run
  made from completion metadata. If the current plugin API is insufficient,
  extend CoreAgent's observer/plugin contract first.
- Local trace data should be redacted by default and project-scoped with indexed
  readback fields. Do not rely on blob-only encoded payloads as the query
  contract.
- Redaction must not be regex-only. Define typed secret fields and coverage for
  prompt segments, tool arguments, tool outputs, metadata, events, receipts,
  files, export payloads, and evaluator examples. Add canary tests for secrets
  that do not look like common token regexes.

## Apple OS 27 / Foundation Models Alignment

The port should lean into the 2027 Apple model rather than copying LangChain's
Python model:

- `LanguageModelSession` remains the execution surface for model calls.
- `Transcript` is the canonical conversation history. String summaries are
  lossy projections, not canonical state.
- `Prompt` and custom transcript segments must survive orchestration.
- `GeneratedContent` and `Generable` remain the structured generation boundary.
- `Tool` remains the native tool boundary; CoreAgent may wrap tools for policy
  and observability.
- Dynamic profiles are the right shape for adaptive model/tool/instruction
  selection, but profile-owned tools have different interception boundaries.
- `AsyncSequence` is the natural streaming API.
- Actors own mutable runtime state and stores.
- Package products and traits should keep optional features small and explicit.
- Use Apple's Evaluations framework direction for eval concepts where practical:
  synthetic data generation, tool-call trajectory expectations, and
  quality/intent assertions rather than exact output strings.
- Use Xcode 27 Foundation Models Instruments as a complementary runtime
  debugging surface, not as a replacement for CoreAgent's portable trace store.

## Apple Platform Adapter Contract

The portable CoreAgent products should not absorb every Apple-platform feature
directly. The right model is capability adapters that are great on Apple
platforms while leaving the core runtime portable and testable.

Decision summary:

- Keep `CoreAgent`, `CoreAgentGraph`, `CoreAgentDeep`, `CoreAgentSkills`, and
  `CoreAgentEngine` portable. They define typed graph, transcript, checkpoint,
  policy, optimization, and trace contracts.
- Add Apple-only products as adapters over those contracts, not replacements
  for them. SwiftData persists canonical envelopes; SwiftUI observes
  projections; App Intents invoke governed actions; sandbox/computer-use
  adapters execute capabilities under policy.
- Treat sandboxing, code interpretation, computer use, and app automation as
  separate capabilities. A user granting one does not imply the others.
- Make every adapter prove the same four things before it is trusted:
  authority, cancellation, checkpoint/readback, and receipt-visible audit.

Current Xcode 27 SDK interface checks confirm useful primitives exist:

- SwiftData exposes `ModelContainer`, `ModelContext`, `DataStore`,
  `DataStoreSnapshot`, and `DefaultSnapshot`.
- App Intents exposes `AppIntent`, `supportedModes`, OS 27
  `allowedExecutionTargets`, `donate()`, `IntentDonationManager`, and
  `RelevantIntentManager`.
- SwiftUI/Observation should use `@Observable` main-actor view models with
  narrow, equatable UI projections rather than passing full trace/checkpoint
  payloads through views.

Recommended adapters:

- `CoreAgentApplePlatformContracts`
  - Shared Apple-only protocol vocabulary for capability IDs, policy versions,
    consent records, artifact handles, security-scoped resource metadata,
    cancellation snapshots, and platform audit envelopes.
  - This target should contain no UI and no executable sandbox backend. Its job
    is to keep SwiftData, SwiftUI, App Intents, and sandbox adapters from
    inventing incompatible names for the same authority or artifact concepts.
  - Core portable products still must not depend on this target.

- `CoreAgentAppleSandbox`
  - Capability-scoped executors for code interpretation, filesystem access,
    network access, app automation, and computer-use actions.
  - No default arbitrary shell/code execution.
  - Every side-effecting executor enters through the same HITL/intervention,
    authorization, timeout, cancellation, and audit path as any other governed
    CoreAgent tool. Sandbox approval is not a separate bypass.
  - Implementations can target `JavaScriptCore`, WASI/WebAssembly, Apple
    Container/macOS helper tools, or remote execution, but all must declare
    entitlements, filesystem roots, network policy, timeout, memory budget,
    cancellation, transcript/audit semantics, and teardown behavior.
  - Treat interpreter support as tiers, not one feature flag:
    deterministic in-process interpreters first, WASI/WebAssembly for bounded
    artifact execution next, then opt-in helper/remote execution only when the
    app can prove entitlement, consent, isolation, cancellation, and artifact
    readback. iOS/iPadOS must not assume arbitrary subprocess execution.
  - Computer-use is a separate consent-gated capability because it operates
    UI state and accessibility privileges, not just agent data.
  - Code interpreters should checkpoint declared inputs, outputs, stdout/stderr,
    artifact handles, resource usage, and sandbox policy version. They should
    not checkpoint incidental process state as the canonical contract.

- `CoreAgentSwiftDataStore`
  - SwiftData-backed implementations of `CoreAgentCheckpointStore`,
    `CoreAgentGraphCheckpointer`, `CoreAgentGraphStore`, and later
    `CoreAgentEngine` trace/issue stores.
  - Checkpoint records should persist canonical CoreAgent payloads and indexed
    readback fields: thread ID, namespace, checkpoint ID, parent checkpoint ID,
    run ID, created time, status, receipt root hash, schema version, and
    redaction/encryption policy.
  - SwiftData snapshots should support app-level browsing, undo/restore, and
    migration. They must not replace the CoreAgent checkpoint contract or
    rebuild canonical state from incidental SwiftData row shape.
  - SwiftData's `DataStoreSnapshot`/`DefaultSnapshot` concepts are useful for
    app-level snapshot browsing and restore UX. CoreAgent still owns the
    canonical checkpoint schema, parent lineage, pending writes, interrupt
    state, and receipt hashes.
  - Security-scoped file grants, external artifact bookmarks, and erase/read
    barriers should be stored as policy metadata attached to canonical
    checkpoint or artifact envelopes, never inferred later from file URLs or
    SwiftData relationship shape.

- `CoreAgentSwiftUIStore`
  - Main-actor `@Observable` projection layer over Graph/Deep/Engine stores:
    run list, active task tree, todo state, filesystem audit, interrupt queue,
    child subagent links, and trace issues.
  - Store heavy transcripts, files, receipts, and traces outside view state.
    Views should read narrow equatable projections or per-row observable
    models so streaming runs do not invalidate the whole UI.
  - The HITL queue projection should expose action requests, allowed decisions,
    current decision state, edited arguments preview, policy source, and receipt
    links. SwiftUI views should dispatch decisions back through the governed
    CoreAgent policy/resume path.
  - Live streams should be coalesced by a main-actor projection store. Custom
    SwiftUI environment values should carry stable models or value actions, not
    raw closure-valued tool dispatchers that invalidate every reader.

- `CoreAgentIntents`
  - App Intent wrappers for safe user-visible actions such as continue run,
    pause run, approve/edit/reject/respond to a pending tool review, open a
    trace, search memory, export diagnostics, and run a named workflow.
  - Donations should be outcome-aware and privacy-aware: donate completed,
    user-meaningful actions with stable entity identifiers; delete or update
    donations when traces/memories are erased or access scope changes.
  - Intent execution must re-enter CoreAgent through the same policy and audit
    paths as in-app UI. App Intents are a platform entry point, not a bypass.
  - Intent donation should be attached to stable workflow/run/entity IDs, not
    raw prompt text or transient tool-call payloads. Donation invalidation must
    follow erasure, scope changes, and disabled workflow states.
  - Long-running intents must be cooperative: observe cancellation, persist a
    resumable run/checkpoint handle before expensive work, and emit the same
    trace/receipt events as the in-app action.
  - Sensitive intents must declare and test execution boundaries: supported
    modes, OS 27 `allowedExecutionTargets`, foreground or unlocked-device
    requirements where needed, and policy denial when Siri, Shortcuts,
    Spotlight, widgets, or background execution lack the right authority.

These adapters should be optional SPM targets with compile-time platform
availability checks. They are high-value, but they belong after the portable
contracts they persist, observe, or invoke are stable.

Implementation status as of 2026-07-06:

- `CoreAgentApplePlatform` exists as an optional Apple-only product.
- The first foundation slice implements shared SwiftData checkpoint
  snapshot/record contracts with digest-bound sidecar metadata and in-memory
  `ModelContext` round-trip coverage, a live main-actor `ModelContext`-backed
  `CoreAgentCheckpointStore`, capability/consent action gating, App Intent
  exposure descriptors, and a main-actor `@Observable` Engine trace projection
  store.
- The second Apple persistence slice adds a live main-actor
  `ModelContext`-backed `CoreAgentEngineStore` for redacted,
  receipt-verifiable Engine traces and issue lifecycle state.
- The third Apple persistence slice adds live main-actor SwiftData graph
  checkpoint and graph key/value stores with digest-bound sidecars, fail-closed
  corrupt-row handling, parent lineage, reverse save order, and portable graph
  protocol existential use.
- The first concrete interpreter slice adds a deterministic in-process typed
  instruction interpreter under `CoreAgentAppleActionGate`. It has no ambient
  filesystem, network, shell, subprocess, JavaScriptCore, WASI, random, clock,
  or host-object authority; it enforces typed inputs/outputs, output-name
  containment, instruction/input/output/value/state/operand/variable budgets,
  cancellation, non-finite number rejection, and audit metadata with
  program/input digests.
- The first computer-use slice adds a typed planning/execution foundation under
  `CoreAgentAppleActionGate`. Dry-run planning is capability-gated and
  side-effect-free by contract; execution requires an approved plan digest from
  a prior dry-run, binds consent to action ID plus plan digest, enforces
  baseline screenshot evidence, validates request/plan/evidence structure, and
  records audit metadata. It is not raw Accessibility automation.
- OS-level sandbox backends, WASI/helper/remote interpreters, raw computer-use
  automation backends, concrete `AppIntent` wrappers, `AppIntentsTesting`, and
  OS donation-manager bridging remain future slices. Typed App Intent donation
  identity and invalidation metadata are now implemented in
  `CoreAgentApplePlatform`.
- `CoreAgentSkills` now includes a local SkillOpt-Sleep style policy loop with
  rollout evidence records, bounded edit limits, heldout/training split
  isolation, protected slow-update regions, rejected-edit/meta-observation
  memory, and mutation-free preflight for malformed validation/edit proposals.
  Model-powered proposal, Engine trace harvest, replay/dream rollouts,
  multi-objective evaluator adapters, and file-backed stores remain future
  slices.

Platform adapter implementation order should be:

1. `CoreAgentApplePersistence`
   - SwiftData-backed checkpoint, graph-store, and trace-store conformances.
   - This is first because every UI, intent, and donation surface needs stable
     readback, lineage, erasure, migration, and receipt verification.
   - Current status: checkpoint, Engine trace/issue, graph checkpoint, and graph
     key/value stores are implemented.
   - Required tests: checkpoint round trip, parent lineage, pending interrupt
     resume, schema migration, erasure, and snapshot restore without depending
     on incidental SwiftData row layout. Artifact/file-grant persistence must
     also prove security-scoped authority metadata, redaction/encryption policy,
     erase barriers, and read-barrier enforcement from canonical envelopes.

2. `CoreAgentAppleSandbox`
   - Capability-scoped code interpreter and artifact executor APIs.
   - Current status: deterministic in-process typed interpreter is implemented
     with no ambient filesystem/network authority, instruction/input/output/
     value/state/operand/variable budgets, cancellation, output-name
     containment, non-finite number rejection, and audit metadata.
   - Next adapters can consider WASI/WebAssembly or JavaScriptCore only after
     preserving the same bounded execution contract. Host shell helpers are
     high-risk and must be opt-in, entitlement documented,
     timeout/cancellation bounded, and HITL-gated.
   - Required tests: denied-by-default execution, filesystem root containment,
     network-deny behavior, timeout/cancellation, stdout/stderr/artifact
     checkpointing, and audit records that include sandbox policy version.

3. `CoreAgentComputerUse`
   - A separate automation adapter for UI/computer-use actions. It should not
     be modeled as a code interpreter because it controls user-visible UI state
     and may require accessibility or automation privileges.
   - Current status: typed dry-run/execution foundation is implemented in
     `CoreAgentApplePlatform`. Execution is consent-gated and bound to an
     approved dry-run plan digest; evidence requirements and audit metadata are
     typed. Raw UI automation, Accessibility permission handling, trusted
     capture, and OS-level attestation remain future backend work.
   - Required tests: consent-required execution, dry-run/action-plan output,
     cancellation, screenshot or UI hierarchy evidence linkage, and typed audit
     records for every action. App automation must never bypass tool policy.

4. `CoreAgentSwiftUIStore`
   - Main-actor `@Observable` projections over persisted stores and live
     streams. This layer owns run lists, active task trees, pending approvals,
     tool evidence, trace issues, and restore affordances.
   - Views should read narrow, equatable projection values. Heavy transcripts,
     receipts, generated files, and trace blobs stay in stores and are loaded
     on demand.
   - Required tests: projection invalidation behavior, pending HITL decision
     round trip, streaming update coalescing, and no closure-valued custom
     environment keys.

5. `CoreAgentIntents`
   - App Intent entry points and donations for stable workflows and entities.
   - Intents can continue/pause runs, resolve HITL decisions, open traces,
     export diagnostics, search memory, or launch named workflows. Each intent
     must call the same CoreAgent policy/resume/store APIs used by in-app UI.
   - Donations are only for completed or user-meaningful workflow outcomes with
     stable entity IDs. Prompt text, raw tool arguments, ephemeral call IDs, and
     sensitive trace payloads are not donation identifiers.
   - Required tests: `AppIntentsTesting` execution, entity query identity,
     Spotlight/view-annotation readback where used, donation invalidation after
     erasure/scope changes, cooperative cancellation for long-running intents,
     supported-mode/allowed-execution-target declarations, foreground or
     unlocked-device restrictions for sensitive intents, and policy denial for
     disallowed invocation contexts.

Rejection criteria:

- Do not add a SwiftData model that becomes the canonical checkpoint schema.
  SwiftData is a store implementation and browsing/snapshot tool; CoreAgent's
  typed checkpoint, pending-write, interrupt, and receipt contracts remain the
  source of truth.
- Do not expose computer-use, shell, network, or app-automation capability as a
  generic "tools enabled" switch. Each capability needs its own entitlement,
  consent, policy, timeout, cancellation, and audit shape.
- Do not store SwiftUI view state as the run truth. UI state is a projection
  over graph/deep/engine stores.
- Do not let App Intents, Spotlight, Siri, or donations bypass the same HITL,
  authorization, redaction, erasure, and receipt-verification paths used by the
  in-app experience.

## Proposed Products

Keep product boundaries narrow:

- `CoreAgentGraph`
  - Depends on `CoreAgent`.
  - Graph runtime, channels, checkpoints, interrupts, stream events.
  - No deep-agent tools, no SkillOpt, no Engine.

- `CoreAgentDeep`
  - Depends on `CoreAgent` and `CoreAgentGraph`.
  - Deep harness tools, todo, virtual filesystem, subagents, context offload,
    approval integration.
  - No trace-store implementation.

- `CoreAgentSkills`
  - Depends on `CoreAgent`; optionally integrates with `CoreAgentDeep`.
  - Skill registry, skill curation, SkillOpt loop, sleep/consolidation.
  - Should not depend on the full deep harness just to apply edits.

- `CoreAgentEngine`
  - Depends on `CoreAgent`.
  - Trace store, issue/evaluator/dataset contracts, local analysis loop.
  - Should not depend on Deep/Graph/Skills.

- `CoreAgentDeepStack` or `CoreAgentAgenticKit`
  - Optional convenience target that wires Graph + Deep + Skills + Engine.
  - This avoids making trace-only consumers import the whole stack.

- `CoreAgentApplePlatform`
  - Umbrella convenience target over Apple-only adapters such as sandbox
    executors, SwiftData stores, SwiftUI projections, and App Intents.
  - Currently owns the live SwiftData checkpoint store, Engine trace/issue
    store, graph checkpoint/store persistence, and SwiftUI run projection store.
  - Should not be required by `CoreAgent`, `CoreAgentGraph`, `CoreAgentDeep`,
    `CoreAgentSkills`, or `CoreAgentEngine`.

## PR #1 Salvage Decision

Keep as reference only:

- Product split idea.
- Some public type names if they still fit after contract review.
- The rough division into graph, deep, skills, and engine modules.

Rewrite:

- All graph execution, checkpointing, and streaming code.
- All deep-agent session/middleware/tool code.
- All SkillOpt training logic.
- All engine store/analysis/plugin code.
- All tests.

Potentially salvage with edits:

- Small value types such as graph node IDs or trace IDs, after rechecking API
  names against the new design.
- Documentation wording only where it describes intended behavior, not current
  behavior.

Drop:

- PR README/changelog claims.
- Fake ReAct graph adapter.
- Harness optimization placeholders.
- String heuristic issue clustering.
- Shell/file operations that lack canonical path containment and policy proof.

## Implementation Slices

### Slice 1: CoreAgentGraph Runtime

Goal: a compile-green, Swift-native graph runtime with durable checkpoint and
interrupt semantics before any deep-agent feature depends on it.

Acceptance evidence:

- Reducer tests for overwrite, append, and native transcript/history channels.
- Compile validation tests for orphan nodes, duplicate nodes, missing entry, bad
  conditional edge targets, and recursion limits.
- Super-step execution tests with sequential and parallel nodes.
- Checkpoint tests for latest lookup, specific checkpoint lookup, state history,
  parent checkpoint, namespace, and pending writes.
- Interrupt/resume tests proving resume payload is consumed and side effects
  before interrupt are idempotent.
- Stream tests for values, updates, tasks, checkpoints, interrupts, and custom
  events.

### Slice 2: CoreAgentDeep Harness

Goal: make Deep Agents behavior real through CoreAgent's native session, plugin,
and tool policy seams.

Acceptance evidence:

- Todo tool uses exact public status literals and persists state.
- Filesystem backend canonicalizes paths after resolving symlinks and rejects
  escapes.
- Context blocks injected by Deep plugins appear in
  `RecordedLanguageModel`-captured transcripts and are sanitized before
  checkpointing.
- Human-in-the-loop approve/edit/reject/respond decisions run before tool
  execution; rejected/responded calls do not execute the underlying tool and
  emit typed intervention events.
- Context offload stores oversized tool output and returns a reference; parent
  prompt receives the reference, not the full output.
- Subagent task tool creates an isolated session with a separate transcript and
  returns one final report to the parent.

### Slice 3: CoreAgentEngine Trace Ingestion

Goal: create a local Engine foundation that ingests real CoreAgent evidence.

Acceptance evidence:

- Observer/plugin path stores the actual `CoreAgentRun` with real events.
- Trace store supports project/thread/run queries with indexed fields.
- Trace receipts verify after store/readback.
- Failed runs cluster into issues with contributing trace IDs.
- Issue filters by project/status are covered end to end.
- Redaction tests prove secrets do not leave allowed boundaries.

### Slice 4: CoreAgentSkills and SkillOpt

Goal: build trainable, versioned skills with held-out validation gates.

Acceptance evidence:

- Skill registry loads only selected `SKILL.md` documents and preserves source
  metadata.
- Skill curation ranks candidates by typed metadata, not incidental wording.
- Rollout evidence captures transcripts, tool events, verifier feedback,
  scores, and task metadata.
- Edit operations are typed and bounded by learning-rate policy.
- Held-out validation gate accepts/rejects candidates correctly.
- Rejected edits and meta-skill memory influence later reflections without
  mutating target skills directly.
- `best_skill.md` export and resumable optimizer state work.
- Local sleep-loop proposal execution preflights malformed proposals before
  mutation and records accepted/rejected decisions with evidence IDs.

### Slice 5: Integrated Agentic Kit

Goal: wire Graph + Deep + Skills + Engine without collapsing product boundaries.

Acceptance evidence:

- Import smoke tests prove `CoreAgentEngine` works without `CoreAgentDeep`.
- Integrated sample runs with a recorded model and no network dependencies.
- Documentation states what is implemented, what is experimental, and what is
  intentionally out of scope.

## Security and Privacy Requirements

- Tool policy is pre-execution and deterministic.
- Shell/code execution is excluded from defaults and must require explicit
  sandbox/backend configuration.
- File backends enforce canonical containment and first-match permission rules.
- Filesystem permissions are default-deny. The contract must define
  read/write/list/delete permissions, absolute-path handling, symlink race
  expectations, first-match precedence, and audit events for denied operations.
- Trace export is opt-in and redacted by default.
- Trace retention/deletion and local file protection are explicit configuration,
  not hidden store behavior.
- Cloud adapters are explicit and document privacy implications.
- Stores persist indexed operational states such as dropped, skipped, unknown,
  unscoped, expired, disabled, paused, and failed.
- Do not encrypt queryable local trace/lake events by default; encrypt secrets
  and credentials as secret material.
- Do not reconstruct canonical data from provider-specific row shapes.

## Open Decisions For Approval

1. Stable-only external target or include prerelease Deep Agents `0.7.0a3`
   behavior now?
   - Recommendation: stable-only behavior for implementation; track prerelease
     in docs as drift risk.

2. First implementation PR scope.
   - Recommendation: Slice 1 only, `CoreAgentGraph`, with no Deep/Skill/Engine
     public claims until the runtime is real.

3. Package names.
   - Recommendation: `CoreAgentGraph`, `CoreAgentDeep`, `CoreAgentSkills`,
     `CoreAgentEngine`, plus optional `CoreAgentAgenticKit`.

4. SQLite for graph checkpoints in Slice 1.
   - Recommendation: implement in-memory checkpointer first plus protocol
     conformance tests; SQLite follows only after the contract is green.

5. Engine PR automation.
   - Recommendation: no autonomous PR creation in the first Engine slice.
     Implement typed proposed-fix artifacts and evaluator proof first.


## RSI / RLM Follow-On Integrations (Queued)

These are design inputs for later SkillOpt/RSI slices. They are not implemented in
the current port foundation.

- [zjunlp/SkillAdaptor](https://github.com/zjunlp/SkillAdaptor): skill adaptation
  over heterogeneous tool/skill libraries. Map to `CoreAgentSkill` curation plus
  bounded edit operations with held-out validation, not prompt-string surgery.
- [observeco/rqgm-core](https://github.com/observeco/rqgm-core) and
  [observeco/EvoSkill-RQGM](https://github.com/observeco/EvoSkill-RQGM): graph/meta
  memory for skill evolution. Map to optimizer memory, meta-observations, and
  `CoreAgentSkillOptimizationRunExecutor` phase audit—not ad hoc transcript memory.
- [AutoMem](https://github.com/autoLearnMem/AutoMem): long-horizon memory for
  recursive/iterative learning. Map behind Engine trace harvest and
  `CoreAgentMemory` contracts with digest-bound evidence, not raw payload replay.
- [MetaSkill-Evolve arXiv 2607.05297](https://arxiv.org/pdf/2607.05297)
  ("Recursive Self-Improvement of LLM Agents via Two-Timescale Meta-Skill
  Evolution", submitted 2026-07-06): assess for RSI inclusion around fast
  task-skill evolution plus slower branch-local meta-skill evolution. CoreAgent
  maps this into a typed
  `CoreAgentSkillMetaEvolutionFrontierSelector` that filters/orders SkillOpt
  sleep proposals by productivity, novelty, strict score, loose score, and
  hack-ratio policy before mutation, plus branch-local
  `CoreAgentSkillMetaSkillBranchSnapshot` /
  `CoreAgentSkillMetaSkillEvolutionRecord` optimizer memory for
  analyzer/retriever/allocator/proposer/evolver state. Future work must keep
  scheduler cadence, branch allocation, and recursive budget policy host-owned.
- Recursive Language Models (RLMs): treat as an orchestration pattern over
  `CoreAgentDeep` subagents plus Engine/Skills feedback loops. Requires explicit
  recursion budgets, audit, and held-out gates before any autonomous spawn.

### Explicitly Not Implemented Yet

- LangGraph `Send`, parent-graph command routing, first-class executable
  subgraphs, and deferred node scheduling. `CoreAgentGraph` now has typed
  `Command(update:goto:)`-style node outputs plus checkpointer-backed
  `updateState` / `bulkUpdateState`, but not subgraph send/parent semantics.
- OS-level sandbox interpreter runners and production remote/WASI runtime hosts
  (deterministic in-process, consent-gated helper-process, WASI backend boundary,
  and remote backend boundary exist; CoreAgent still does not launch sandboxes or
  network calls itself).
- Production cross-run scheduler/daemon for SkillOpt sleep runs (local executor
  only).
- Fully autonomous token/cost optimization closed loops beyond local budgets and
  `CoreAgentSkillOptimizationRunHarvestConfig.maximumTotalTokens` gating (hosts still
  own production schedulers and evaluator gates).
- Held-out Engine/Skills feedback gates wired into recursive orchestration and
  rubric grading (FoundationModels decomposition/grading backends and local
  orchestration exist; closed-loop optimization gates remain host-owned).
- Default-on autonomous dynamic subagent spawning without any host policy
  (`CoreAgentDeepDynamicSubagentsAutoApprovalPolicy` provides opt-in,
  digest-bound auto-registration for explicitly allowlisted proposal names).

## Source Index

- Deep Agents overview:
  https://docs.langchain.com/oss/python/deepagents/overview
- Deep Agents subagents:
  https://docs.langchain.com/oss/python/deepagents/subagents
- Deep Agents repository:
  https://github.com/langchain-ai/deepagents
- LangGraph overview:
  https://docs.langchain.com/oss/python/langgraph/overview
- LangGraph Graph API:
  https://docs.langchain.com/oss/python/langgraph/graph-api
- LangGraph checkpointers:
  https://docs.langchain.com/oss/python/langgraph/checkpointers
- LangGraph interrupts:
  https://docs.langchain.com/oss/python/langgraph/interrupts
- LangGraph streaming:
  https://docs.langchain.com/oss/python/langgraph/streaming
- LangSmith Engine:
  https://docs.langchain.com/langsmith/engine
- SkillOpt repository:
  https://github.com/microsoft/SkillOpt
- SkillOpt guide:
  https://microsoft.github.io/SkillOpt/docs/guideline.html
- SkillOpt overview:
  https://microsoft.github.io/SkillOpt/
- Apple WWDC26, agentic app experiences:
  https://developer.apple.com/videos/play/wwdc2026/242/
- Apple WWDC26, Foundation Models provider protocol:
  https://developer.apple.com/videos/play/wwdc2026/339/
- Apple WWDC26, Foundation Models Instruments:
  https://developer.apple.com/videos/play/wwdc2026/243/
- Apple WWDC26, robust evaluations:
  https://developer.apple.com/videos/play/wwdc2026/299/
- LangSmith Engine video provided by user:
  https://youtu.be/MVvFDfxaeWg
- Max Agency podcast video provided by user:
  https://youtu.be/YqjR4vQwbTc
