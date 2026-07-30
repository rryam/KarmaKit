# Dynamic-profile tool governance

`AgentSession` preserves `LanguageModelSession` as the model/tool inner loop.
On Xcode 27, it can apply a native `DynamicProfileModifier` that authorizes a
profile-owned tool call before Foundation Models invokes the tool.

This API is available on iOS 27, macOS 27, visionOS 27, and watchOS 27. It is
unavailable on tvOS, and its declarations are compiler-gated. The current
package requires Swift tools 6.4; Xcode 26.6 RC2's SwiftPM 6.3.3 therefore stops
at the package manifest before source compatibility can be evaluated.

## Establish the trust boundary

Foundation Models does not expose a dynamic profile's complete tool collection
for external introspection. The application must build a registry from the same
tool values it puts in the profile:

```swift
let lookup = LookupTool(client: client)
let registry = try DynamicProfileToolRegistry(tools: [lookup])

let governance = try DynamicProfileToolGovernanceConfiguration(
  trusting: registry,
  authorizer: ClosureDynamicProfileToolAuthorizer { request in
    switch await approvalService.decision(
      tool: request.manifest.name,
      argumentsJSON: request.canonicalArgumentsJSON
    ) {
    case .approved:
      return .allow
    case .declined(let reason):
      return .deny(reason: reason)
    }
  },
  maximumCallsPerRun: 8,
  maximumCallsPerToolPerRun: ["lookup": 4]
)

let agent = try AgentSession(
  checkpointCompatibilityID: "assistant-profile-v2",
  toolGovernance: governance
) {
  LanguageModelSession.Profile {
    Instructions("Use lookup only when current data is required.")
    lookup
  }
  .model(model)
}
```

`DynamicProfileToolRegistry` rejects duplicate tool names. Unknown names fail
closed before the authorizer runs. The `trusting:` configuration initializer
pins the digest of every current registry manifest.

For separately stored approvals, use
`init(registry:trustedManifestDigests:authorizer:maximumCallsPerRun:maximumCallsPerToolPerRun:)`.
The registry describes the current profile tools; the trusted set describes the
contracts the application has approved. A tool description, schema, name, or
`includesSchemaInInstructions` change updates its digest, so a current manifest
paired with a previously approved digest fails closed.

Because the native callback carries a tool name but not its full declaration,
the registry is an explicit application invariant. Failing to update the
registry when the opaque profile changes cannot be detected from the callback
alone. Constructing the registry and profile from the same tool values keeps
that invariant reviewable.

## Authorization sequence

For every `Transcript.ToolCall`, governance performs these steps before the tool
implementation:

1. Resolve the tool name in the explicit registry.
2. Verify the resolved manifest's exact digest is trusted.
3. Reserve the total and per-tool call budgets atomically.
4. Pass the native `GeneratedContent`, sorted-key canonical JSON, metadata,
   native call ID, and manifest to the authorizer.
5. Allow execution only after an `.allow` decision and a cancellation check.

Budget reservation happens before awaiting approval. Concurrent native calls
therefore cannot race past a limit. An attempted call that reaches approval
consumes its reservation even when approval is denied or fails.

The following run events preserve the native call ID in `native_call_id`:

- `profileToolAllowed`
- `profileToolDenied`
- `profileToolApprovalFailed`
- `profileToolBudgetExhausted`

Unknown and untrusted tools are recorded as denied. An authorizer error and
cancellation are recorded as approval failures. Foundation Models may wrap the
thrown governance error in its native `ToolCallError`; the audited event retains
the stable classification.

## Lifecycle ordering and limits

AgentSession applies governance outside the profile returned by the factory.
Native lifecycle modifiers execute from the supplied inner profile outward:

```text
supplied profile onToolCall -> AgentSession governance -> tool implementation
```

This ordering preserves existing profile behavior and is covered by a
deterministic test. It also defines the boundary:

- A governance denial prevents the `Tool.call` implementation from running.
- An inner lifecycle hook can run before governance and can preempt it by
  throwing.
- Governance cannot undo a side effect performed by an inner hook.
- The pre-execution callback does not wrap opaque tool execution, so it cannot
  enforce an execution timeout.
- Governance cannot inspect, replace, or filter opaque output before the model
  consumes it and cannot undo a side effect after output.
- `onToolOutput` observation remains best effort because an earlier throwing
  output hook can preempt an outer observer.

Use `AgentSession(model:tools:instructions:toolConfiguration:)` when the package
must own the tool wrapper, enforce a cooperative execution timeout, or inspect
the wrapper's output contract. Explicit model/tools mode is otherwise unchanged.
