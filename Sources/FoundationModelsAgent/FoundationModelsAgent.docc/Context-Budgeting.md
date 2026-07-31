# Context Budgeting

FoundationModelsAgent performs context-budget preflight only for an explicit
`LanguageModelSession`. The inner inference loop remains Apple's native
session, transcript, prompt, tools, schema, and response APIs.

## Limits

`AgentSessionContextBudget` exposes three independent input limits:

- `reservedResponseTokens` keeps part of the model context available for the
  response;
- `maximumUsableFraction` caps input to a fraction of the selected model's
  context;
- `maximumUsableTokens` optionally adds an absolute input cap.

The effective input limit is the smallest of:

```text
contextSize - reservedResponseTokens
floor(contextSize * maximumUsableFraction)
maximumUsableTokens, when supplied
```

Preflight sums native token counts for instructions, governed tools, the final
prompt, an applicable schema, and transcript history. The final prompt is
measured after session plugins contribute transient context. A schema is
included unless the request's `ContextOptions` explicitly excludes it.
Restored instruction entries may already materialize tool definitions; the
component split uses the larger native aggregate when their separately
measured tool cost exceeds that entry count, so the preflight cannot undercount
tools.

The default overflow policy is `.failBeforeInference`. Exact fits are allowed.
If instructions, tools, prompt, and schema already exceed the limit, failure
occurs without invoking a history transform because rewriting history cannot
make those fixed components fit.

## Selected-model measurement

`SystemLanguageModel` is measured automatically with its native `contextSize`
and `tokenCount(for:)` overloads.

The Xcode 27 `LanguageModel` protocol itself does not require context
measurement. Custom conformers therefore supply a model-bound seam:

```swift
let measurer = AgentSessionContextMeasurer { model, request in
  guard let model = model as? MyLanguageModel else {
    throw AppMeasurementError.unexpectedModel
  }
  let contextSize = try await model.contextSizeForCurrentDeployment()
  return AgentSessionContextTokenCounts(
    contextSize: contextSize,
    instructions: try await model.tokens(for: request.instructions),
    tools: try await model.tokens(for: request.tools),
    prompt: try await model.tokens(for: request.prompt),
    schema: try await model.tokens(for: request.schema),
    transcript: try await model.tokens(for: request.transcriptEntries)
  )
}

let agent = try AgentSession(
  model: selectedModel,
  configuration: .init(
    contextBudget: .init(reservedResponseTokens: 512)
  ),
  contextMeasurer: measurer
)
```

The closure receives the exact `selectedModel` value used by
`LanguageModelSession`. The example method names are provider-specific
placeholders: use the selected model's real token-counting API. Do not estimate
tokens from characters or introduce a second tokenizer.

When using ``FoundationModelsAgentRouter``, pass its complete selection to
``AgentSession/init(selection:tools:instructions:configuration:contextMeasurer:toolConfiguration:checkpointStore:checkpointKey:transcriptRetention:requiresMatchingToolset:instructionRestorationPolicy:plugins:redactionPolicy:observers:observerDeliveryConfiguration:instrumentation:)``.
The measurer receives that selection's actual native model. The route
descriptor's declared context size is decision evidence only; it is never used
as token accounting. An unsupported selected route fails before inference and
does not silently advance to another fallback.

`PrivateCloudComputeLanguageModel` exposes a context size in Xcode 27 but no
matching public token-count overloads. It cannot use automatic preflight until
the app can provide truthful counts.

## Automatic summarization

Use ``AgentSessionContextOverflowPolicy/summarize(using:instructions:sourceRedactionPolicy:options:identifier:authoritativeTranscriptPolicy:)``
to summarize completed history only after native measurement reports overflow:

```swift
let budget = AgentSessionContextBudget(
  reservedResponseTokens: 768,
  maximumUsableFraction: 0.9,
  overflowPolicy: .summarize(
    using: summarizer,
    identifier: "support-summary-v1"
  )
)
```

The supplied `LanguageModel` runs in a fresh `LanguageModelSession` with no
tools. The current request is not part of the summary source. Completed
prompts, responses, structured content, tool calls, and tool outputs are
rendered as delimited transcript data; reasoning is omitted. Image attachments
are represented by their labels rather than copied into the summarizer prompt.
Custom segments use their public descriptions.

The default instructions tell the summarizer to preserve established facts,
decisions, preferences, consequential tool results, and unresolved work while
treating the transcript as data rather than instructions. Supply custom
`Instructions` when an app needs a domain-specific continuation state. Change
the transform `identifier` whenever that contract changes.

Automatic summarization inherits the transform safety boundary below:

- complete tool exchanges are validated before installation;
- the rematerialized native session is measured again;
- an empty summary, summarizer failure, or summary that still does not fit
  fails before main-model inference;
- complete authoritative history and checkpoints are preserved by default.

The summarizer receives the conversation text. Passing a network-backed model
is an explicit application data-disclosure decision. The package does not
route or authenticate that model call. Set `sourceRedactionPolicy` when the
rendered source must be filtered before disclosure; `.none` preserves the
conversation by default. A source transcript may also exceed the summarizer's
own context window; use a model with sufficient capacity or an app-owned
chunking transform for that case.

## App-owned transforms

When history can be compacted safely, configure an audited transform:

```swift
let compact = AgentSessionContextTransform(identifier: "support-summary-v1") {
  request in
  let result = try await appHistoryPolicy.compact(request.transcript)
  return AgentSessionContextTransformResult(
    transcript: result.transcript,
    affectedHistoryRange: result.sourceRange,
    provenance: result.summaryRecordID,
    authoritativeTranscriptPolicy: .preserve
  )
}

let budget = AgentSessionContextBudget(
  reservedResponseTokens: 768,
  maximumUsableFraction: 0.9,
  overflowPolicy: .transform(compact)
)
```

FoundationModelsAgent checks cancellation, validates the affected range and
provenance, requires the range to cover every rewrite while preserving
instruction entries, rejects orphaned or incomplete tool exchanges, remeasures
every component from the candidate native session after current instructions
and tools are rematerialized, and installs the rewrite only when it fits. A
changed transcript creates a new native session and invalidates the model's
prompt cache.

With `.preserve`, `transcript()` retains the complete authoritative history
while the active native session uses the compacted history. New
prompt/response entries are appended to both views. The default `.complete`
transcript retention also persists that complete checkpoint, allowing restore
to recompute compaction from complete evidence. An explicitly configured
`.latestHistoryEntries` or custom retention policy remains a separate lossy
checkpoint choice.

Use `.replace` only when the app intentionally makes the rewrite authoritative
and accepts a lossy checkpoint. FoundationModelsAgent never silently drops
history.

Transforms run once per public request before retry attempts. Their closures
must be `@Sendable`, cooperate with cancellation, and must not re-enter the
same `AgentSession` while its operation lease is held.

## Audit evidence

Runs contain:

- `contextBudgetEvaluated` with the selected policy, context size, usable input
  limit, and every component count;
- `contextBudgetTransformed` with before/after counts, the affected numeric
  range and stable transcript entry IDs, provenance, authoritative policy, and
  cache invalidation;
- `contextBudgetFailed` with the error type, selected policy, and all counts
  available before failure.

Numeric token-count attributes are not treated as credentials by the standard
event redaction policy. Actual token or authorization values remain redacted.

## Dynamic profiles and Apple utilities

A dynamic profile may select a model and mutate history inside native
`onPrompt` modifiers. The outer session cannot truthfully know either result,
so profile mode rejects `contextBudget`.

Apply Apple's native history utilities at that layer:

```swift
import FoundationModelsUtilities

LanguageModelSession.Profile {
  Instructions("Help with the current project.")
  tools
}
.model(model)
.summarizeHistory(entryThreshold: 50, model: summarizer)
.rollingWindow(entries: 10)
.droppingCompletedToolCalls()
```

`summarizeHistory`, `rollingWindow`, and `droppingCompletedToolCalls` come from
Apple's `foundation-models-utilities` package. They execute inside an opaque
dynamic profile and use entry-based policy. FoundationModelsAgent's
`.summarize(using:)` is the explicit-model alternative: native token overflow
triggers it and the outer session validates, remeasures, and audits the result.
It does not replace Apple's profile modifiers or Skills abstractions.

`rollingWindow(entries:)` alone is not guaranteed to preserve prompt-led
tool-turn boundaries. Test the chosen composition with the app's real tools
and persistence policy.
