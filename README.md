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

Profile-owned tools are intentionally not advertised as governed: Foundation
Models keeps those tools opaque to FoundationModelsAgent's `AnyTool` wrappers. Use the
explicit `model:tools:instructions:` initializer when approval, call budgets,
trusted manifests, or per-tool execution timeouts are required. Profile mode
rejects multi-attempt retries because FoundationModelsAgent cannot safely observe
profile-owned tools, lifecycle hooks, or transcript-policy modifiers before
they take effect. FoundationModelsAgent attaches best-effort observation-only `onToolCall`
and `onToolOutput` modifiers. They preserve native call/output IDs when their
lifecycle chain completes, including when a later model continuation reverts
the transcript. An earlier throwing hook inside the supplied profile can
preempt FoundationModelsAgent's outer observer and erase that evidence; every profile run
contains `profileToolAuditBestEffort` to make this limit machine-visible.

## Foreground child agents

Use `ChildAgentTool` for Apple's phone-a-friend pattern: the parent pauses,
creates a fresh child `AgentSession`, gives it one focused task, receives a
bounded structured result, and then writes the final answer itself.

```swift
let researcher = try ChildAgentDefinition(
  identifier: "research_child",
  description: "Research one focused question, then return findings to the parent.",
  limits: ChildAgentLimits(
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
`ChildAgentResult` statuses rather than opaque thrown text.

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

Choose the dynamic-profile initializer on `AgentSession` for baton-pass
behavior: one native session changes model, instructions, tools, or history
handling while retaining that session's transcript. Choose `ChildAgentTool`
for phone-a-friend behavior: a separate session receives an isolated task,
returns bounded findings, and never replaces the parent as final-answer owner.

Child consultations are foreground-only and exactly one child turn. Depth and
tool-call limits are enforced before recursive consultation or native tool
execution. Wall-clock timeouts use Swift cooperative cancellation, so session
factories and custom model/tool implementations must honor cancellation. This
API does not create background jobs, durable child handles, or a workflow DSL.

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

Tools owned by a dynamic profile also stay outside FoundationModelsAgent's pre-execution
policy wrapper. Their lifecycle audit is best effort: a throwing inner profile
hook can prevent FoundationModelsAgent's observer from seeing a completed effect. Use the
explicit tools initializer for governance and audit guarantees.

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
