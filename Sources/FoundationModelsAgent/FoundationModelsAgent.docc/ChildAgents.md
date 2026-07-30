# Consulting foreground child agents

Use ``ChildAgentTool`` when a parent needs a focused second opinion without
giving up ownership of the user-facing answer.

## Keep the native session boundary

A ``ChildAgentDefinition`` stores a stable tool identifier, a model-visible
description, ``ChildAgentLimits``, an explicit ``ChildAgentPolicy``, and a
factory for a fresh ``AgentSession``. The child continues to use
`LanguageModelSession` as its inner model/tool loop. There is no provider,
message, transcript, or workflow abstraction between them.

```swift
let definition = try ChildAgentDefinition(
  identifier: "review_child",
  description: "Review one proposed change and return concise findings.",
  limits: ChildAgentLimits(
    maximumChildrenPerParentRun: 2,
    maximumDepth: 1,
    maximumTurns: 1,
    maximumToolCalls: 2,
    wallClockTimeout: .seconds(15),
    maximumOutputBytes: 4_096
  )
) { invocation in
  try AgentSession(
    model: reviewModel,
    tools: reviewTools,
    instructions: Instructions {
      "Review only the delegated task: \(invocation.task)"
    }
  )
}

let parent = try AgentSession(
  model: parentModel,
  tools: [ChildAgentTool(definition: definition)]
)
```

Every call asks the factory for a new actor. Do not return the parent session or
reuse an earlier child. A new session has independent native history and has no
checkpoint store, memory plugin, or other plugin unless the factory installs
one explicitly.

## Narrow permissions explicitly

The child does not receive the parent's positive permissions. Use
``ChildAgentPolicy`` to inherit denials or reject delegation, and build the
child session with a narrower `FoundationModelsAgentToolConfiguration`.
``ClosureChildAgentPolicy`` is the adapter seam for an application policy
system; FoundationModelsAgent does not define a parallel capability hierarchy.

Policy denial, child tool denial, cancellation, timeout, tool-call exhaustion,
depth rejection, and other failures are returned as canonical
``AgentTaskResult`` settlements inside ``ChildAgentResult``. Successful results
include a tamper-evident child receipt and an ``AgentRunLineage`` descendant of
the parent run. The parent model sees a bounded JSON projection, without the
full receipt payload, and decides how to use it.

## Understand the limits

One tool call performs one foreground child turn. A zero turn limit rejects the
call. ``ChildAgentLimits/maximumChildrenPerParentRun`` bounds consultations
from the same tool in a parent run. ``ChildAgentLimits/maximumDepth`` is
carried through canonical task-local lineage and cannot be widened by a nested
definition. ``ChildAgentLimits/maximumToolCalls`` narrows an explicit-model
child run budget.

For profile-owned tools, pass a
``DynamicProfileToolGovernanceConfiguration`` to `toolGovernance:`. The child
definition narrows the canonical governance total-call budget. Without that
configuration, an opaque dynamic profile remains observable but the package
cannot truthfully limit its tool execution.

The wall-clock timeout covers policy, session construction, and generation.
It propagates Swift cancellation into the child, so custom factories, models,
and tools must cooperate with cancellation. Successful content and failure
messages are independently bounded by UTF-8 size without splitting extended
grapheme clusters.

Routing, context budgeting, tool governance, plugins, checkpoint and memory
scope, and instrumentation are explicit choices in the fresh session factory.
The canonical lineage supplied to the child correlates its receipts and
Instruments projection automatically. This API intentionally has no background
queue, detached execution, durable child handle, or workflow DSL.

## Choose baton pass or phone a friend

Use `AgentSession(checkpointCompatibilityID:profile:)` when one native session
should change its active model, instructions, tools, lifecycle hooks, or
history transform while continuing its own transcript. That is baton pass.

Use ``ChildAgentTool`` when the consultation needs a fresh transcript and
separate checkpoint or memory scope, and the parent must resume afterward to
write the final answer. That is phone a friend.

The profile convenience on ``ChildAgentDefinition`` accepts a caller-supplied
native `DynamicProfile` and constructs a fresh profile-backed `AgentSession`
per call. It requires a `Sendable` profile value. Use the general session
factory when a profile needs fresh non-`Sendable` state.
