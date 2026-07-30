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

Policy denial and child tool denial are returned as
``ChildAgentResultStatus/denied`` with a bounded ``ChildAgentFailure``. Child
cancellation, timeout, tool-call exhaustion, depth rejection, and other
failures also have distinct structured statuses. The parent model sees the
result as stable JSON and decides how to use it.

## Understand the limits

One tool call performs one foreground child turn. A zero turn limit rejects the
call. ``ChildAgentLimits/maximumDepth`` is carried through task-local child
calls, and ``ChildAgentLimits/maximumToolCalls`` narrows the child
`AgentSession` run budget. Dynamic-profile child tools are counted by the
profile's pre-execution tool-call lifecycle hook.

The wall-clock timeout covers policy, session construction, and generation.
It propagates Swift cancellation into the child, so custom factories, models,
and tools must cooperate with cancellation. Successful content and failure
messages are independently bounded by UTF-8 size without splitting extended
grapheme clusters.

This API intentionally has no background queue, detached execution, durable
child handle, generic task-result schema, or receipt-lineage model.

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
