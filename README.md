# Foundation Models Agent

**Foundation Models makes any model callable. Foundation Models Agent makes any model shippable.**

Foundation Models Agent is a production harness for Apple's Foundation Models API. Give it any
type that conforms to `LanguageModel` and keep using native `Prompt`,
`Transcript`, `Tool`, `GeneratedContent`, and `Generable` values end to end.

FoundationModelsAgent adds the layer an app still needs around the native session:

- approval, allowlist, and trusted-manifest policy before tools execute;
- per-run tool budgets and cooperative tool/model timeouts;
- retries for failures your app classifies as safe;
- versioned, durable native-transcript checkpoints;
- optional scoped long-term memory with SQLite FTS, approval, and deletion;
- toolset validation when restoring a checkpoint;
- ordered run events, observers, usage, and tamper-evident receipts;
- execution-agnostic parent/child lineage and structured terminal task results;
- explicit, evidence-producing selection among native `LanguageModel` values;
- deterministic, zero-network model fixtures for tests;
- optional first-party Apple, Anthropic, and Google provider packages.

FoundationModelsAgent does **not** define another provider protocol, message format, schema
tree, tool protocol, or agent loop. Foundation Models owns those primitives.

## Requirements

- Swift 6.4
- Xcode 27
- iOS 27+, macOS 27+, or visionOS 27+

Apple has announced that the Foundation Models core will become open source.
Until that source and its package manifest ship, FoundationModelsAgent makes no iOS 18 or
Linux compatibility claim.

## Installation

Add FoundationModelsAgent with Swift Package Manager:

```swift
dependencies: [
  .package(
    url: "https://github.com/rudrankriyam/FoundationModelsAgent.git",
    from: "0.4.0"
  )
]
```

Add the main library to your target:

```swift
.product(name: "FoundationModelsAgent", package: "FoundationModelsAgent")
```

Add `FoundationModelsAgentMemory` only when the app needs inspectable long-term memory:

```swift
.product(name: "FoundationModelsAgentMemory", package: "FoundationModelsAgent")
```

Add `FoundationModelsAgentBackgroundTasks` when the app needs a durable, app-managed
task queue:

```swift
.product(name: "FoundationModelsAgentBackgroundTasks", package: "FoundationModelsAgent")
```

## Quick start

```swift
import FoundationModelsAgent
import FoundationModels

let agent = try AgentSession(
  model: SystemLanguageModel.default,
  instructions: Instructions {
    "Be concise. Use a tool only when it materially improves the answer."
  }
)

let response = try await agent.respond(to: "Explain tool calling in one sentence.")
print(response.content)
print(response.usage)
```

The session is persistent. Foundation Models retains its native transcript and
FoundationModelsAgent returns the typed response, raw generated content, new transcript
entries, token usage, and audited run.

## Xcode 27 dynamic profiles

Use the profile-factory initializer when Foundation Models' dynamic profile is
the composition root. This preserves native dynamic instructions, model
switching, lifecycle hooks, and utilities such as Skills and history modifiers:

```swift
let agent = try AgentSession(
  checkpointCompatibilityID: "assistant-profile-v1",
  checkpointStore: store,
  checkpointKey: "assistant:user-123"
) {
  LanguageModelSession.Profile {
    Instructions("Help the user with the current project.")
    dynamicTools
  }
  .model(model)
}
```

FoundationModelsAgent stores an `@Sendable` factory and calls it again for lazy restore and
`reset()`. Each returned profile is transferred to Foundation Models with
`sending`, so the factory may create fresh non-`Sendable` state; state shared
across profile instances must itself be `Sendable` (as Apple's
`SkillActivations` is). FoundationModelsAgent restores only `Transcript.history`, allowing
the current profile to rematerialize its instructions, tools, model, and
modifiers. Change
`checkpointCompatibilityID` whenever that contract changes. Dynamic state that
is not in a transcript—including `SkillActivations`, closures, and session
properties—must be persisted and reinjected by the app before the factory runs.
Profile history transforms run inside Foundation Models; FoundationModelsAgent's transcript
retention runs afterward at persistence time, so avoid configuring two
compactors that discard the same context.

Xcode 27's `onToolCall` hook runs before a profile-owned tool implementation and
can throw to stop it. Opt into that native pre-execution boundary with an
explicit registry and pinned manifest digests:

```swift
let lookup = LookupTool()
let registry = try DynamicProfileToolRegistry(tools: [lookup])
let governance = try DynamicProfileToolGovernanceConfiguration(
  trusting: registry,
  authorizer: ClosureDynamicProfileToolAuthorizer { request in
    // request.arguments is GeneratedContent; this string has sorted JSON keys.
    audit(request.nativeCallID, request.canonicalArgumentsJSON)
    return await approvals.allows(request) ? .allow : .deny(reason: "Approval declined")
  },
  maximumCallsPerRun: 6,
  maximumCallsPerToolPerRun: ["lookup": 3]
)

let agent = try AgentSession(
  checkpointCompatibilityID: "assistant-profile-v2",
  toolGovernance: governance
) {
  LanguageModelSession.Profile {
    Instructions("Help the user with the current project.")
    lookup
  }
  .model(model)
}
```

Build the registry from the same tool values placed in the profile. Unknown tool
names fail closed. The `trusting:` initializer pins every current digest; the
lower-level initializer accepts the registry and trusted digest set separately
when an application stores approvals independently. A changed description,
schema, name, or `includesSchemaInInstructions` value produces a different
digest and must be trusted intentionally.

Registry lookup, exact-manifest trust, total and per-tool budgets, and the
application authorizer all run before execution against the native
`GeneratedContent` arguments and canonical JSON. Audited outcomes use
`profileToolAllowed`, `profileToolDenied`, `profileToolApprovalFailed`, and
`profileToolBudgetExhausted`; each carries the native tool-call ID. A denial,
unknown tool, changed manifest, exhausted budget, approval error, or cancellation
prevents the tool implementation from running.

`profileToolAllowed` records the pre-execution governance decision. Foundation
Models still performs native schema decoding and tool execution afterward, so
an allowed call can subsequently fail without entering the tool implementation.

The supplied profile's inner `onToolCall` hooks run before AgentSession's outer
governance modifier. An inner hook that throws can therefore preempt governance,
and side effects inside an inner lifecycle callback are outside this boundary.
`onToolOutput` remains best-effort observation. Profile mode still rejects
multi-attempt retries because profile-owned state and lifecycle hooks are not
generically reversible. See
[Dynamic-profile tool governance](Documentation/Dynamic-Profile-Tool-Governance.md)
for the complete contract.

## Explicit native model routing

Use `FoundationModelsAgentRouter` before constructing an explicit-model `AgentSession`.
Routing chooses among native `LanguageModel` values and produces evidence; it does not
respond, stream, translate messages, or replace the native session loop.

```swift
let local = FoundationModelsAgentRouteCandidate.onDevice(
  id: "on-device-general",
  purpose: "Keep ordinary assistant prompts on device."
)
let privateCloud = await FoundationModelsAgentRouteCandidate.privateCloudCompute(
  id: "pcc-reasoning",
  purpose: "Handle reasoning requests when the user allows Private Cloud Compute."
)

let policy = ClosureFoundationModelsAgentRoutingPolicy { requirements, candidates in
  FoundationModelsAgentRoutePlan(
    primaryRouteID: "on-device-general",
    // Listing a fallback is an explicit opt-in. No fallback is inferred.
    fallbackRouteIDs: requirements.requiresReasoning ? ["pcc-reasoning"] : []
  )
}

let requirements = FoundationModelsAgentRouteRequirements(
  // The default is `.onDeviceOnly`. Both classes must be explicitly widened
  // before prompt data may leave the device.
  dataPolicy: FoundationModelsAgentRouteDataPolicy(
    allowedPrivacyClasses: [.onDevice, .privateCloudCompute],
    allowedNetworkClasses: [.none, .applePrivateCloud]
  ),
  minimumContextTokens: 8_000,
  requiresReasoning: true,
  quotaPolicy: .avoidApproachingLimit
)

switch FoundationModelsAgentRouter().select(
  from: [local, privateCloud],
  requirements: requirements,
  policy: policy
) {
case .selected(let selection):
  let agent = try AgentSession(
    selection: selection,
    instructions: Instructions("Help the user.")
  )
  let response = try await agent.respond(to: "Analyze this plan.")
  print(response.run.routingDecision as Any)

case .noRoute(let decision):
  // Show an app-owned recovery UI. Every candidate and rejection reason is present.
  print(decision)
}
```

The app-supplied policy determines the primary route and ordered fallback list.
The router then applies availability, privacy/network, context, reasoning, and quota
requirements deterministically. `FoundationModelsAgentRouteDecision` records the selected
route, whether it was a fallback, and an outcome for every candidate before execution.
`AgentSession` emits `routeSelected` and `routeCandidateRejected` before the first model
attempt, then preserves the decision beside truthful usage on completed runs and beside
`nil` usage when a failed native response exposes no usage.

The on-device and Private Cloud Compute candidate helpers snapshot Apple's native
availability. The Private Cloud Compute helper also records below-limit,
approaching-limit, and limit-reached quota states and queries the native context size only
when the model is available. These helpers are availability-gated to the OS versions that
expose their native APIs.

Treat a native context size of zero literally. Xcode 27 Beta 4 can report
`SystemLanguageModel.contextSize == 0` while the model is available. The helper preserves
that observation as `.known(tokenLimit: 0)` instead of inventing a limit. A request with a
positive `minimumContextTokens` then rejects the route as insufficient; a request without
a minimum can still select it based on the other declared requirements.

Third-party `LanguageModel` packages own authentication, secret storage, account setup,
and billing. Construct and authenticate those native model values outside the router, then
describe the route with `.externalProvider(providerID:accountReference:)`. The router never
accepts API keys or refresh tokens, does not validate provider billing, and does not turn
an account reference into authorization. Keep secrets out of route IDs, purposes, and
account references because routing decisions are audit evidence.

Use routing only with the explicit-model `AgentSession` initializer. The dynamic-profile
initializer intentionally has no `routingDecision` parameter because Foundation Models
owns its model switching; attaching an external route would make the evidence diverge
from the model that actually executed. Govern profile-owned tool calls independently with
`DynamicProfileToolGovernanceConfiguration`; those runs retain governance evidence and a
`nil` routing decision.

## Native context budgets

`AgentSessionContextBudget` preflights the exact native components used by an
explicit-model session: instructions, governed tools, the final prompt
(including plugin context), an applicable generation schema, and transcript
history. `SystemLanguageModel` uses its native `contextSize` and
`tokenCount(for:)` APIs automatically:

```swift
let agent = try AgentSession(
  model: SystemLanguageModel.default,
  tools: tools,
  instructions: Instructions("Answer from the available evidence."),
  configuration: FoundationModelsAgentConfiguration(
    contextBudget: AgentSessionContextBudget(
      reservedResponseTokens: 768,
      maximumUsableFraction: 0.9,
      maximumUsableTokens: 3_000,
      overflowPolicy: .failBeforeInference
    )
  )
)
```

Exact fits proceed; overflow fails before inference. A custom `LanguageModel`
can opt in with `AgentSessionContextMeasurer`. Its closure receives the
exact model instance passed to the session and the native values to measure.
FoundationModelsAgent never substitutes an approximate tokenizer.

For a routed model, construct the session atomically with
`AgentSession(selection:contextMeasurer:...)`. The measurer receives the
selection's actual native model. A route descriptor's context size remains
routing evidence and is never substituted for native token accounting; an
unsupported selected model fails instead of silently trying another route.

For app-owned compaction, use `.transform(...)`. The rewritten active session
is validated, remeasured, and recorded with before/after counts, affected
entry IDs, provenance, and cache invalidation. The complete authoritative
transcript and checkpoint remain unchanged by default. Choosing
`authoritativeTranscriptPolicy: .replace` is the explicit lossy option.

Dynamic profiles are intentionally different: their active model and
modifier-produced history are opaque outside Foundation Models, so
`AgentSession` rejects `contextBudget` in profile mode. Apply model-aware
history policy inside the profile. Apple's `foundation-models-utilities`
modifiers compose directly:

```swift
import FoundationModelsUtilities

let agent = try AgentSession(
  checkpointCompatibilityID: "assistant-profile-v2"
) {
  LanguageModelSession.Profile {
    Instructions("Help with the current project.")
    dynamicTools
  }
  .model(model)
  .summarizeHistory(entryThreshold: 50, model: summarizer)
  .rollingWindow(entries: 10)
  .droppingCompletedToolCalls()
}
```

Those are Apple's native profile modifiers, not implementations supplied or
replaced by FoundationModelsAgent. Because `rollingWindow(entries:)` is an
entry suffix rather than a turn-aware window, compose and test it carefully
when tool calls are present. See
[Context budgeting](Sources/FoundationModelsAgent/FoundationModelsAgent.docc/Context-Budgeting.md)
for custom-model
measurement, transform auditing, checkpoint semantics, and limitations.

## Foreground child agents

Use `ChildAgentTool` for Apple's phone-a-friend pattern: the parent pauses,
creates a fresh child `AgentSession`, gives it one focused task, receives a
bounded structured result, and then writes the final answer itself.

```swift
let researcher = try ChildAgentDefinition(
  identifier: "research_child",
  description: "Research one focused question, then return findings to the parent.",
  limits: ChildAgentLimits(
    maximumChildrenPerParentRun: 2,
    maximumDepth: 1,
    maximumTurns: 1,
    maximumToolCalls: 3,
    wallClockTimeout: .seconds(20),
    maximumOutputBytes: 4_096
  ),
  policy: ClosureChildAgentPolicy { invocation in
    await delegationPolicy.allowsChild(invocation)
      ? .allow
      : .deny(reason: "Delegation is outside the current policy scope.")
  }
) { invocation in
  try AgentSession(
    model: model,
    tools: narrowlyScopedResearchTools,
    instructions: Instructions {
      "Investigate only the delegated task. Return evidence, not a user-facing answer."
    }
  )
}

let parent = try AgentSession(
  model: model,
  tools: [ChildAgentTool(definition: researcher)],
  instructions: Instructions {
    "Use research_child only when consultation helps. You own the final answer."
  }
)
```

The session factory runs once per tool call and must return a fresh session.
That makes native transcript, checkpoint, plugin, and memory state isolated by
default. A factory can deliberately install a child-specific checkpoint or
memory scope, but it should never return the parent session or reuse a previous
child. Cancellation of the parent task cancels the foreground child. Child
denial, cancellation, timeout, tool-budget exhaustion, and failure become
canonical `AgentTaskResult` settlements inside `ChildAgentResult`, rather than
opaque thrown text. Successful children also return a tamper-evident receipt
whose `AgentRunLineage` links the child run and task to the parent run.

No positive permission is inherited. The `ChildAgentPolicy` hook can carry
parent denials into the delegation boundary, while the session factory installs
an explicitly narrower child tool policy. This seam is intentionally small so
an application policy system can adapt to it without FoundationModelsAgent
duplicating a capability hierarchy.

A native dynamic profile can also be the child recipe:

```swift
let specialist = try ChildAgentDefinition(
  identifier: "specialist",
  description: "Consult the specialist profile."
) { invocation in
  SpecialistProfile(task: invocation.task)
}
```

This convenience requires a `Sendable` profile value. If a profile creates
fresh non-`Sendable` state, use the `sessionFactory:` initializer and construct
its `AgentSession(checkpointCompatibilityID:profile:)` there.
When the profile owns tools, pass an explicit
`DynamicProfileToolGovernanceConfiguration` to `toolGovernance:`. The child
definition narrows its total call budget to `maximumToolCalls`; unknown,
changed, or denied profile tools continue to fail closed under the canonical
governance runtime. A profile without governance is observable but its opaque
tool execution cannot truthfully be limited by the package.

Choose the dynamic-profile initializer on `AgentSession` for baton-pass
behavior: one native session changes model, instructions, tools, or history
handling while retaining that session's transcript. Choose `ChildAgentTool`
for phone-a-friend behavior: a separate session receives an isolated task,
returns bounded findings, and never replaces the parent as final-answer owner.

Child consultations are foreground-only and exactly one child turn. Per-parent
child, recursive depth, and explicit-model tool-call limits are enforced before
construction or native tool execution. Wall-clock timeouts use Swift
cooperative cancellation, so session factories and custom model/tool
implementations must honor cancellation. Routing, context budgeting, plugins,
checkpoint scope, memory scope, tool policy, and instrumentation remain
explicit choices of the fresh child session factory. Canonical lineage is
supplied automatically, so child receipts and Instruments signposts correlate
with the parent without defining a second hierarchy. This API does not create
background jobs, durable child handles, or a workflow DSL.

See
[Consulting foreground child agents](Sources/FoundationModelsAgent/FoundationModelsAgent.docc/ChildAgents.md)
for the factory, policy, governance, evidence, and limit contracts.

## Native typed and multimodal input

There is no FoundationModelsAgent-specific message type to flatten rich input.

```swift
@Generable
struct Inspection: Sendable {
  let summary: String
  let severity: String
}

let prompt = Prompt {
  Attachment(image).label("screenshot")
  "Inspect this UI failure."
}

let response = try await agent.respond(
  to: prompt,
  generating: Inspection.self
)

print(response.content.summary)
```

Provider-defined `Transcript.CustomSegment` values can carry modalities such as
audio or video without FoundationModelsAgent needing to understand or convert them.

## Govern native tools

Pass ordinary Foundation Models tools. FoundationModelsAgent applies an internal type
eraser and policy, then delegates execution back to the native session.

```swift
@Generable
struct SendEmailArguments: Sendable {
  let recipient: String
  let subject: String
  let body: String
}

struct SendEmailTool: Tool {
  let name = "send_email"
  let description = "Send an email after explicit approval."

  @concurrent
  func call(arguments: SendEmailArguments) async throws -> String {
    // Perform the side effect.
    "sent"
  }
}

let approval = ClosureFoundationModelsAgentApprovalProvider { request in
  // request.arguments is native GeneratedContent.
  print(request.argumentsJSON)
  return await askUserToApprove(request) ? .approve : .deny(reason: "User declined")
}

let agent = try AgentSession(
  model: SystemLanguageModel.default,
  tools: [SendEmailTool()],
  toolConfiguration: FoundationModelsAgentToolConfiguration(
    policy: CompositeFoundationModelsAgentToolPolicy([
      ToolNameAllowlistPolicy(["send_email"]),
      ApprovalRequiredToolPolicy(
        requiredNames: ["send_email"],
        provider: approval
      )
    ]),
    executionTimeout: .seconds(15),
    maximumCallsPerRun: 3
  )
)
```

`FoundationModelsAgentToolManifest` hashes the native tool name, description, and encoded
`GenerationSchema`. Persist approved digests and enforce them with
`TrustedToolManifestPolicy` to detect a changed tool contract.

## Durable native transcript checkpoints

FoundationModelsAgent checkpoints `Transcript` rather than inventing a lossy conversation
format.

```swift
let store = FileCheckpointStore(
  directory: URL.applicationSupportDirectory
    .appending(path: "FoundationModelsAgent", directoryHint: .isDirectory)
)

let agent = try AgentSession(
  model: model,
  tools: tools,
  instructions: Instructions("Help the user."),
  checkpointStore: store,
  checkpointKey: "support-agent:user-123"
)

_ = try await agent.respond(to: prompt) // checkpoints after success
let checkpoint = try await agent.checkpoint()
```

On the next launch, the first request restores the checkpoint lazily. By
default, FoundationModelsAgent rejects it if the current tool manifests do not match the
saved toolset revision. Dynamic-profile sessions instead validate the required
`checkpointCompatibilityID` supplied by the app.

Use `FoundationModelsAgentTranscriptRetention.latestHistoryEntries(_:)` for bounded history
or provide an async custom transform. Bounded retention keeps only whole
prompt-led turns, so it may retain fewer entries than the limit rather than
orphaning a tool call or output. The file store hashes keys before using them as
filenames and writes atomically.

Transcript retention is persistence-only. A `.preserve` context transform
keeps the complete in-memory authoritative transcript and, with the default
`.complete` retention, the complete checkpoint. Choosing
`.latestHistoryEntries` or a custom retention transform is a separate explicit
lossy checkpoint policy; `.replace` is the explicit way to make the context
rewrite itself authoritative.

Important Foundation Models persistence behavior in Xcode 27:

- image attachments are encoded into the checkpoint and can make files large;
- decoded images retain pixels but may lose the original URL;
- custom segments retain data but decode through Foundation Models' erased
  representation rather than their original concrete Swift type;
- custom metadata values similarly lose concrete type identity;
- credentials, model configuration, tools, closures, and dynamic-profile state
  are not part of a transcript and must be reinjected.

`FileCheckpointStore` rejects custom segments and typed metadata by default,
because their concrete Swift types cannot be restored losslessly. Supply
`.allowFoundationModelsTypeErasure` only when the provider explicitly supports
the erased representation or your app rehydrates it. In-memory checkpoints do
not cross a Codable boundary and preserve the concrete values.

Encrypt sensitive checkpoint files at the application boundary. FoundationModelsAgent's
plain file store is intentionally not presented as encrypted storage.

## Durable app-managed tasks

`FoundationModelsAgentBackgroundTasks` persists task scheduling and recovery without
replacing the native model loop. The caller supplies a `@Sendable` execution
factory. The request names the canonical parent run, and each attempt receives
a fresh `.background` lineage with the same stable task ID.

```swift
import FoundationModelsAgent
import FoundationModelsAgentBackgroundTasks

let taskStore = try FileBackgroundAgentTaskStore(
  fileURL: URL.applicationSupportDirectory
    .appending(path: "FoundationModelsAgent/background-tasks.json")
)

let coordinator = try BackgroundAgentTaskCoordinator(store: taskStore) {
  record, context in
  guard let lineage = record.currentAttemptLineage else {
    throw AppError.missingBackgroundLineage
  }
  let selection = try routeModel(for: record)
  let session = try AgentSession(
    selection: selection,
    tools: governedTools,
    configuration: agentConfiguration,
    checkpointStore: checkpointStore,
    checkpointKey: "background-\(record.id)",
    instrumentation: instrumentation
  )
  let response = try await session.respond(
    to: record.prompt,
    lineage: lineage
  )
  try await context.recordUsage(
    turns: 1,
    tokens: response.usage.inputTokens + response.usage.outputTokens
  )
  let receipt = try FoundationModelsAgentRunReceipt(run: response.run)
  let result = try AgentTaskResult(
    lineage: lineage,
    status: .succeeded,
    outputReferences: [saveOutput(response.content, runID: lineage.runID)],
    evidenceReferences: [.run(lineage.runID)],
    usage: response.usage,
    receipt: AgentReceiptReference(
      runID: lineage.runID,
      rootHash: receipt.rootHash
    ),
    timing: AgentTaskTiming(
      queuedAt: record.submittedAt,
      startedAt: response.run.startedAt,
      endedAt: response.run.endedAt
    )
  )
  return BackgroundAgentTaskOutcome(taskResult: result)
}

try await coordinator.start()
guard let parentLineage = foregroundResponse.run.lineage else {
  throw AppError.missingForegroundLineage
}
let taskID = try await coordinator.submit(
  BackgroundAgentTaskRequest(
    prompt: "Reconcile the local draft.",
    ownerID: signedInUserID,
    parentLineage: parentLineage,
    metadata: [
      "workspace": workspaceID,
      "checkpointKey": "background-\(workspaceID)-reconcile",
    ],
    priority: .normal,
    recoveryPolicy: .readOnly
  )
)
let finalRecord = try await coordinator.waitForSettlement(of: taskID)
```

Every prompt gets its own stable UUID and FIFO sequence. The coordinator does
not merge matching text. It records owner, root, parent, depth, priority,
timestamps, attempts, leases, cooperative usage, canonical results, and a
terminal reason in a versioned snapshot. Every retry gets a different run ID;
prior attempt evidence stays on the record. `FileBackgroundAgentTaskStore`
atomically replaces the snapshot and holds an advisory lock for exclusive local
ownership.

Mutation recovery is explicit. Call
`context.markExecutingMutation(named:idempotencyKey:)` before the external call.
Use `.nonReplayableMutation` when the destination has no idempotency contract;
if the process stops after that boundary, recovery settles the task as
`ambiguousAfterCrash`. `.idempotentMutation(idempotencyKey:)` permits replay
only when the execution factory presents the same key at the mutation boundary.
The coordinator never guesses whether an opaque native tool changed external
state. One task may cross one mutation boundary; split several independent
writes into separate tasks.

Global and per-parent concurrency, depth, fan-out, elapsed time, attempts,
turns, tool calls, and tokens are bounded. Priority aging prevents a steady
stream of urgent work from starving an older low-priority task. Cancellation
settles the selected task and its descendants deterministically, then
cooperatively cancels active execution. After a non-idempotent boundary,
cancellation or timeout settles as `ambiguousAfterCrash` because the external
effect may still finish.

This is app-managed durability, not guaranteed OS background runtime. A saved
task can resume after the app launches again, but iOS may suspend or terminate
the process at any time and does not promise arbitrary model work will keep
running. The package does not register `BGTaskScheduler` jobs or create UI for
them.

The JSON store is not encrypted and `ownerID` is not an access-control check.
Use an app-protected location, apply file protection, and encrypt sensitive
queues at the app boundary. Recovery is explicit: call `start()` after launch
and `resume()` when the app wants to reclaim expired leases.

See [Durable Background Tasks](Sources/FoundationModelsAgentBackgroundTasks/FoundationModelsAgentBackgroundTasks.docc/DurableBackgroundTasks.md)
for the state machine, crash rules, side-effect protocol, and scope boundaries.

## Production long-term memory

`FoundationModelsAgentMemory` is a separate, optional product. Checkpoints resume one native
transcript; long-term memory retrieves durable evidence across transcripts.
Neither store is a substitute for the other.

```swift
import FoundationModelsAgent
import FoundationModelsAgentMemory

let scope = try FoundationModelsAgentMemoryScope(
  applicationID: "com.example.assistant",
  userID: signedInUserID,
  agentID: "support"
)

let memoryStore = try SQLiteFoundationModelsAgentMemoryStore(
  databaseURL: URL.applicationSupportDirectory
    .appending(path: "FoundationModelsAgent/memory.sqlite")
)

let memory = FoundationModelsAgentMemoryCoordinator(
  scope: scope,
  store: memoryStore,
  disclosurePolicy: FoundationModelsAgentMemoryDisclosurePolicy(destination: .onDevice)
)

let agent = try AgentSession(
  model: model,
  plugins: [memory]
)
```

String prompts automatically become the bounded retrieval query. Rich
`Prompt` values require an explicit `contextQuery:`; otherwise automatic recall
is skipped while `memory.searchTool` remains available. Retrieved records are
inserted before the original prompt as delimited, untrusted evidence, then
removed from active and checkpointed transcript history after generation.

SQLite is canonical and uses FTS5. It stores provenance, supersessions,
pending candidates, durable consolidation jobs, and tombstones with WAL and
foreign keys enabled. There is no vector-library dependency. Apps that need a
second retrieval strategy can implement `FoundationModelsAgentMemoryIndex`; FoundationModelsAgent
always reloads and filters canonical SQLite records before disclosure.

Successful runs persist an active episode before returning. A caller-supplied
`FoundationModelsMemoryConsolidator` uses fresh model sessions to propose facts,
preferences, or procedures. Proposals remain pending until an approval provider
or an explicit `approve(_:)` call accepts them. Use `flush()` at deterministic
test or shutdown boundaries.

See [Long-Term Memory](Documentation/Long-Term-Memory.md) for correction,
deletion, export, dynamic-profile, privacy, and failure-policy details.

## Traces and receipts

```swift
let observer = ClosureFoundationModelsAgentObserver { event in
  logger.info("\(event.kind.rawValue): \(event.message)")
}

let agent = try AgentSession(
  model: model,
  observers: [observer]
)

let response = try await agent.respond(to: prompt)
let receipt = try FoundationModelsAgentRunReceipt(run: response.run)
precondition(receipt.verify())
```

Each observer has an independent, bounded serial queue, so a stalled observer
cannot stall a model, tool call, or another observer. The default queue keeps
256 pending events and drops the oldest on overflow; configure this with
`FoundationModelsAgentObserverDeliveryConfiguration`. `flushObservers()` distinguishes a
drained barrier from a timeout, cancellation, or reentrant call and reports the
cumulative number of dropped observer events:

```swift
let flush = await agent.flushObservers(timeout: .seconds(2))
guard flush.deliveredAllEvents else {
  logger.warning("Observer delivery did not drain before shutdown")
  return
}
```

Events record FoundationModelsAgent invocation IDs before execution. The post-response
transcript projection also records Foundation Models' authoritative tool-call
IDs. Prompt bodies, native tool arguments, and tool output bodies are not copied
into event attributes by default; they remain in the native transcript.

Receipts are SHA-256 hash chains. They detect mutation but do not prove
authorship; sign the root hash when cryptographic attribution is required.

## Xcode 27 Evaluations

`FoundationModelsAgentEvaluations` is an optional test-support product for
Apple's Xcode 27 `Evaluations` framework. The core target does not import or
link `Evaluations`, so adding FoundationModelsAgent to an app does not add a
production runtime dependency.

Build a stable trajectory from native transcripts and the canonical verified
receipt bundle:

```swift
let response = try await agent.respond(to: "Find the newest report.")
let receipt = try FoundationModelsAgentRunReceipt(run: response.run)
let evidence = AgentReceiptBundle(receipts: [receipt])
let trajectory = try FoundationModelsAgentTrajectory(
  transcripts: [
    response.run.lineage!.runID: try await agent.transcript()
  ],
  evidenceBundle: evidence
)

try FoundationModelsAgentTrajectoryFixtureExporter().write(
  trajectory,
  named: "newest report",
  expectedDestination: "The newest report is Q4.",
  to: fixturesDirectory.appending(path: "newest-report.json")
)
```

For a hierarchy, include every child receipt and `AgentTaskResult` in the bundle
and key each available child transcript by its canonical `AgentRunID`. The
versioned fixture preserves native tool ordering, canonical JSON arguments,
call-group and call-output linkage, terminal task settlements, verified
parent/child lineage, routing/context/tool evidence references, run status, and
unsupported segments. A run without a supplied transcript remains explicit as
`missingNativeTranscript`.
Bundles with multiple root trees retain every run but do not infer one primary
trajectory; export one root tree per evaluation fixture.
Sensitive argument names and common credential strings are redacted by
default. Native run, task, event, transcript, and segment identifiers are
deterministically remapped unless
`preservesNativeIdentifiers` is enabled.

Audited outcomes use the canonical event's `native_call_id` when present.
Legacy name-only events are applied only when the remaining call and outcome
are unambiguous. Conflicts never overwrite a native transcript output;
ambiguous or malformed linkage remains an explicit issue.

In an Xcode 27 evaluation target, add the optional product and import
`FoundationModelsAgentEvaluations`:

```swift
import Evaluations
import FoundationModelsAgentEvaluations

struct ReportEvaluation: Evaluation {
  let agent: AgentSession
  let dataset: ArrayLoader<ModelSample<String>>
  let destination = Metric("destination_exact")
  let path = ToolCallEvaluator<ModelSample<String>>(
    foundationModelsAgentMetricPrefix: "report_path"
  )

  init(agent: AgentSession, fixture: FoundationModelsAgentTrajectoryFixture) throws {
    self.agent = agent
    dataset = ArrayLoader(samples: [
      try fixture.modelSample(
        prompt: "Find the newest report.",
        disallowedToolNames: ["delete_report"],
        allowsAdditionalToolCalls: false
      )
    ])
  }

  func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
    let response = try await agent.respond(to: sample.prompt)
    return ModelSubject(
      foundationModelsAgentValue: response.content,
      transcript: try await agent.transcript()
    )
  }

  var evaluators: Evaluators {
    Evaluator { _, subject in
      subject.value == "The newest report is Q4."
        ? destination.passing()
        : destination.failing()
    }
    path
  }

  func aggregateMetrics(using aggregator: inout MetricsAggregator) {
    aggregator.computeMean(of: destination)
    aggregator.computeMean(of: path.allPass)
    aggregator.computeMean(of: path.percentagePass)
  }
}
```

Evaluate the destination with a deterministic content metric (or another Apple
evaluator appropriate to the task), and evaluate the path separately with
`ToolCallEvaluator`. `TrajectoryExpectation` helpers use exact matchers for
scalar arguments and throw for nested objects, arrays, or null because Xcode 27
Beta 4's `ArgumentValue` cannot represent those exactly. Custom and attachment
segments remain explicit unsupported records rather than disappearing.

The `FoundationModelsAgentEvaluations` DocC catalog includes more fixture and
safety guidance in “Evaluating Agent Paths.”

## Hierarchical execution evidence

FoundationModelsAgent defines lineage and settlement evidence without starting,
routing, or scheduling another agent. A caller that owns child execution creates
the lineage before invoking another native `AgentSession`:

```swift
let parentResponse = try await parent.respond(to: parentPrompt)
let parentLineage = parentResponse.run.lineage!
let childLineage = try parentLineage.descendant(
  taskID: AgentTaskID(),
  relationship: .child
)

let childResponse = try await child.respond(
  to: childPrompt,
  lineage: childLineage
)
let childReceipt = try FoundationModelsAgentRunReceipt(run: childResponse.run)

let result = try AgentTaskResult(
  lineage: childLineage,
  status: .succeeded,
  outputReferences: [
    AgentEvidenceReference(id: "answer", kind: .output)
  ],
  evidenceReferences: childResponse.run.events
    .filter { $0.kind == .contextBudgetEvaluated || $0.kind == .toolExecutionCompleted }
    .map(AgentEvidenceReference.event),
  usage: childResponse.usage,
  receipt: AgentReceiptReference(
    runID: childLineage.runID,
    rootHash: childReceipt.rootHash
  ),
  timing: AgentTaskTiming(
    startedAt: childResponse.run.startedAt,
    endedAt: childResponse.run.endedAt
  )
)
```

`AgentRunLineage` carries stable run and task IDs, the root and parent run IDs,
depth, and the `.root`, `.child`, or `.background` relationship. New
`AgentSession` runs create root lineage automatically. Runs, observer events,
trace exports, and receipts all preserve it. Legacy decoded traces and receipts
may omit lineage; a standalone legacy receipt still verifies with the original
hash-chain seed.

`AgentTaskResult` has terminal states only:

- `.succeeded` has no termination reason;
- `.denied` requires a failure reason for a policy or approval rejection;
- `.failed` requires a failure reason;
- `.cancelled` requires a cancellation reason;
- `.timedOut` requires a failure reason for a caller-owned terminal deadline;
- `.ambiguousAfterCrash` requires a failure reason and means external effects
  may have occurred but cannot be proven after recovery.

Use `AgentReceiptBundle.verify(maximumDepth:)` when verifying a complete
hierarchy. It verifies every hash chain and rejects missing roots, orphans,
cycles, inconsistent depths, rewritten lineage, and mismatched task-to-receipt
or evidence-to-event links. `AgentEvidenceReference.event(_:)` points to the
existing audited routing, context, governance, or tool event without copying
its attributes. `AgentEvidenceReference.routingDecision(for:)` points to the
full route decision already stored on the separately exported run trace.
`AgentReceiptBundleExporter` provides stable JSON and atomic file round trips.
Checkpoint format 1 remains transcript-only and is unchanged.

Future `ChildAgentTool` and background-task implementations can adopt these
types as their public evidence boundary while retaining native
`LanguageModelSession` as the execution loop. See
[Hierarchical Execution Evidence](Sources/FoundationModelsAgent/FoundationModelsAgent.docc/HierarchicalExecutionEvidence.md)
for the full contract.

## Instruments and signposts

AgentSession can emit lightweight OSLog signposts that complement Apple's
Foundation Models Instrument without copying its model telemetry:

```swift
let agent = try AgentSession(
  model: model,
  instrumentation: .init(
    correlationMetadata: ["request_id": requestID.uuidString]
  )
)

let response = try await agent.respond(
  to: prompt,
  lineage: childLineage
)
```

Instrumentation is disabled by default, leaving only a nil check at existing
event boundaries. Enabled sessions use the stable
`com.rudrankriyam.FoundationModelsAgent` subsystem and stable AgentSession
categories for lifecycle, checkpoints, policy, profiles, routing, and context.
Every projection carries the canonical lineage identifiers from
`AgentRunLineage`: `run_id`, `root_run_id`, and, for descendants,
`parent_run_id` and `task_id`. Caller metadata can add application correlation
such as a request ID, but cannot override those canonical keys.

Use Apple's Foundation Models Instrument for time to first token, tokens per
second, and native generation latency. Overlay AgentSession's `Model Attempt`
span with those metrics, then use the outer `AgentSession Run`, routing,
context-budget, checkpoint, approval, governed-tool, retry, cancellation, and
dynamic-profile signposts to explain latency outside the native model.
AgentSession does not re-emit Apple's token timing or create a separate trace
store. Apple's instrument does not carry the AgentSession run ID, so this is a
same-trace timeline correlation rather than an automatic identifier join.

If `prewarm()`, `transcript()`, or `checkpoint()` performs lazy restoration
before a response run exists, the next run receives a `Checkpoint Restore`
point event marked `restored_before_run`. This preserves correlation without
inventing a duration for work that already completed.

For deterministic tests or a private telemetry adapter, inject an
`AgentSessionInstrumentationSink`. Sink errors are ignored and cannot change a
run result. The default content policy projects no diagnostic messages and
instrumentation never receives prompts, tool arguments, tool outputs, model
outputs, or reasoning text. Bounded diagnostic messages require the conspicuous
`.unsafeExplicitlyEnabled(maximumCharacters:)` opt-in and still pass through the
session redaction policy.

See [AgentSession Instrumentation](Sources/FoundationModelsAgent/FoundationModelsAgent.docc/AgentSession-Instrumentation.md)
for span nesting, privacy, and Instruments recording guidance.

## Streaming

```swift
let response = try await agent.respondStreaming(to: prompt) { partial in
  await viewModel.update(text: partial)
}
```

Typed streaming is available with `generating:`. The callback receives the
native `PartiallyGenerated` value, and the final result includes the complete
typed value and audited run. Response timeouts apply to streaming. A failed
stream may retry only before its first partial response and before any governed
tool begins, preventing duplicate UI output or side effects.

## Provider Traits

Every conforming `LanguageModel` already works with `AgentSession`. The
optional `FoundationModelsAgentProviders` product adds one import and construction helpers
for the packages announced alongside Xcode 27.

Enable one or more SwiftPM Traits on the FoundationModelsAgent dependency:

```swift
.package(
  url: "https://github.com/rudrankriyam/FoundationModelsAgent.git",
  from: "0.4.0",
  traits: ["AppleUtilities", "Claude"]
)
```

Available traits:

| Trait | Package | FoundationModelsAgent helper |
| --- | --- | --- |
| `AppleUtilities` | `apple/foundation-models-utilities` | `chatCompletions(...)` |
| `Claude` | `anthropics/ClaudeForFoundationModels` | `claude(...)` |
| `Gemini` | Firebase AI Logic WWDC preview | `gemini(using:name:)` |
| `AllProviders` | All three | Enables every helper |

| Provider | iOS 27 | macOS 27 | visionOS 27 |
| --- | --- | --- | --- |
| Apple utilities | Yes | Yes | Yes |
| Claude | Yes | Yes | Yes |
| Gemini WWDC preview | Yes | Yes | Not officially supported |

Add `.product(name: "FoundationModelsAgentProviders", package: "FoundationModelsAgent")`, then:

```swift
import FoundationModelsAgent
import FoundationModelsAgentProviders
import Foundation
import FirebaseCore // Gemini trait only

let localModel = FoundationModelsAgentProviderModels.chatCompletions(
  name: "local-model",
  baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
  supportsGuidedGeneration: false
)
let localAgent = try AgentSession(model: localModel)

let claude = FoundationModelsAgentProviderModels.claude(
  auth: .proxied(headers: ["Authorization": appSessionToken]),
  baseURL: URL(string: "https://your-relay.example.com")!
)
let claudeAgent = try AgentSession(model: claude)

// Firebase requires a configured app and GoogleService-Info.plist first.
FirebaseApp.configure()
let gemini = FoundationModelsAgentProviderModels.gemini(
  using: FirebaseAIClient.firebaseAI(backend: .googleAI()),
  name: "gemini-2.5-flash"
)
let geminiAgent = try AgentSession(model: gemini)
```

`chatCompletions(...)` is Apple's generic protocol client for local,
self-hosted, or developer-controlled servers that implement the Chat
Completions REST API. It is not an official OpenAI SDK. Never embed a shared
provider API key in an app binary; put hosted-provider credentials behind a
server-controlled endpoint.

The Gemini example also requires `import FirebaseCore`, Firebase App Check, and
the normal Firebase AI Logic app setup. Do not call `firebaseAI()` before
`FirebaseApp.configure()`. Follow Firebase's
[Foundation Models setup guide](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started)
for the required `GoogleService-Info.plist` and App Check configuration.

Do not ship provider keys inside an app. Use a server relay or the provider's
production authentication path.

The Apple utility repository has no release tag yet and Firebase's adapter is a
WWDC preview, so FoundationModelsAgent pins both to verified commits. SwiftPM Traits avoid
compiling and linking disabled products. A clean SwiftPM 6.4 default resolution
uses no external packages; the Gemini trait is intentionally opt-in because its
current Firebase graph is exceptionally large.

The trait syntax above is for clients that own a `Package.swift`. Xcode 27's
Add Package UI does not currently expose dependency-trait selection. Xcode app
projects can add the desired upstream provider package directly and pass its
`LanguageModel` to `AgentSession`; the helper product is optional and adds
no runtime capability.

## Test without keys or Apple Intelligence

`FoundationModelsAgentTestSupport` contains a native `RecordedLanguageModel` and executor.

```swift
import FoundationModelsAgent
import FoundationModelsAgentTestSupport

let model = RecordedLanguageModel(steps: [
  .toolCall(
    name: "lookup",
    argumentsJSON: #"{"query":"FoundationModelsAgent"}"#
  ),
  .response(text: "Recorded final response")
])

let agent = try AgentSession(model: model, tools: [LookupTool()])
let response = try await agent.respond(to: "Test the flow")
```

No API key, network request, or local Apple model is involved. Captured native
request transcripts are available through `model.recorder` for assertions.
The provider-trait tests are construction/compilation smoke tests, not live API
integration tests.

Run the matrix:

```bash
swift test
swift test --filter FoundationModelsAgentEvaluationsTests
swift test --traits AppleUtilities
swift test --traits Claude
swift test --traits Gemini
swift test --traits AllProviders
```

## Deliberate boundaries

Foundation Models owns the inner model/tool loop. Consequently FoundationModelsAgent does
not claim it can generically provide:

- direct-return or action-only semantics after an arbitrary native tool;
- model-planned tool ordering or per-model-step call limits;
- inspection, truncation, or sanitization of an arbitrary tool's opaque
  `Prompt` output before the model consumes it;
- Foundation Models' native tool-call ID before `Tool.call` begins.

Profile-owned tools stay opaque and are not wrapped. On Xcode 27, the optional
dynamic-profile governance modifier can authorize or deny their native
pre-execution calls and enforce call-count budgets. It cannot time out opaque
execution, inspect or filter output before the model consumes it, undo a side
effect after output, or govern work performed by an earlier inner lifecycle
hook. Use the explicit tools initializer when execution timeouts or an
inspectable wrapper-owned output contract are required.

FoundationModelsAgent can deny calls, enforce a total budget, time out execution, apply
policy decisions, and audit the authoritative transcript afterward. Strong
output filtering belongs in a FoundationModelsAgent-owned tool whose output contract is
inspectable.

Automatic retries stop as soon as a governed tool invocation begins, including
authorization. Apps may explicitly set `allowsRetryAfterToolInvocation` only
when every side effect is idempotent.
Checkpoint write failures are recorded and return the completed model response
by default; select `.failRun` only when callers will not blindly repeat side
effects.

## Independence

> Foundation Models Agent is an independent open-source project and is not affiliated with or endorsed by Apple Inc.

## License

Foundation Models Agent is available under the MIT license.
