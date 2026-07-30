# AgentSession Instrumentation

Correlate AgentSession orchestration with Apple's Foundation Models Instrument.

## Overview

``AgentSession`` preserves ``LanguageModelSession`` as its inner loop. Its
signposts describe only the production harness around that native session:

- `AgentSession Run` spans the complete run.
- `Model Attempt` spans each native response or stream attempt.
- `Checkpoint Restore` and `Checkpoint Write` expose persistence latency and
  failure.
- `Approval Wait`, `Governed Tool Call`, and `Tool Execution` are nested policy
  and side-effect spans.
- `Retry` and `Cancellation` are point events.
- `Profile Lifecycle` and `Profile Transition` mark the dynamic-profile
  boundaries AgentSession can observe.

The stable default subsystem is
`com.rudrankriyam.FoundationModelsAgent`. Categories are
`AgentSession.Lifecycle`, `AgentSession.Checkpoint`, `AgentSession.Policy`, and
`AgentSession.Profile`.

## Enable signposts

Instrumentation is opt-in:

```swift
let session = try AgentSession(
  model: model,
  instrumentation: AgentSessionInstrumentationConfiguration()
)
```

The default ``AgentSessionInstrumentationConfiguration/disabled`` value avoids
creating OSLog objects or projection events. Enabled instrumentation has no
correctness dependency on OSLog delivery.

Every projected span contains the AgentSession run ID. Pass optional child or
task correlation as generic string metadata without adopting another public
lineage type:

```swift
let instrumentation = AgentSessionInstrumentationConfiguration(
  correlationMetadata: [
    "root_id": rootID.uuidString,
    "parent_id": parentID.uuidString,
    "task_id": taskID.uuidString,
  ]
)
```

Unified logging renders identifiers with private hashed privacy. An injected
``AgentSessionInstrumentationSink`` receives typed run and span IDs plus the
generic metadata so deterministic tests can verify nesting and ordering without
scraping unified logs. Sink failures are isolated from the model response, tool
call, checkpoint, observers, and receipts.

## Record with Instruments

1. Add Apple's Foundation Models Instrument and the Points of Interest
   instrument to a trace.
2. Filter Points of Interest to the
   `com.rudrankriyam.FoundationModelsAgent` subsystem.
3. Align `Model Attempt` with Apple's native generation interval.
4. Read time to first token, tokens per second, token counts, and native total
   latency from Apple's instrument.
5. Use the enclosing `AgentSession Run` and its checkpoint, approval, governed
   tool, retry, cancellation, and profile spans to identify time outside native
   generation.

AgentSession deliberately does not duplicate Apple's token-rate metrics. A run
can therefore be interpreted as:

```
AgentSession Run
├─ Checkpoint Restore
├─ Model Attempt
│  └─ Governed Tool Call
│     ├─ Approval Wait
│     └─ Tool Execution
└─ Checkpoint Write
```

Retries produce multiple sibling `Model Attempt` spans and a `Retry` event
between them. Cancellation closes every still-open child span before the run
span.

If `prewarm()`, `transcript()`, or `checkpoint()` performs lazy checkpoint
restoration before a response run exists, the next run projects a
`Checkpoint Restore` point event with `restored_before_run` set to `true`.
AgentSession does not backdate or invent an interval for already-completed work.

## Privacy

The default content policy is
``AgentSessionInstrumentationContentPolicy/redacted``. It projects no
diagnostic message. Prompt bodies, tool arguments, tool outputs, model outputs,
identifiers, secrets, and reasoning text are not recorded as public signpost
content.

Use
``AgentSessionInstrumentationContentPolicy/unsafeExplicitlyEnabled(maximumCharacters:)``
only when bounded diagnostic messages are required. This conspicuous opt-in is
still subject to the session's ``FoundationModelsAgentRedactionPolicy`` and
does not enable prompt, argument, output, or reasoning capture.

Instrumentation is ephemeral. Use existing observers and
``FoundationModelsAgentRunReceipt`` when an ordered or tamper-evident durable
record is required.
