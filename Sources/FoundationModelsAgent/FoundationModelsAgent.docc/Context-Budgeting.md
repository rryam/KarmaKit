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
let measurer = AgentSessionContextMeasurer<MyLanguageModel> { model, request in
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

`PrivateCloudComputeLanguageModel` exposes a context size in Xcode 27 but no
matching public token-count overloads. It cannot use automatic preflight until
the app can provide truthful counts.

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

With `.preserve`, `transcript()` and checkpoints retain the complete
authoritative history while the active native session uses the compacted
history. New prompt/response entries are appended to both views. This allows a
checkpoint restore to recompute compaction from complete evidence.

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
Apple's `foundation-models-utilities` package. FoundationModelsAgent does not
duplicate their summarization or Skills abstractions. These modifiers execute
inside the profile, and `rollingWindow(entries:)` alone is not guaranteed to
preserve prompt-led tool-turn boundaries. Test the chosen composition with the
app's real tools and persistence policy.
