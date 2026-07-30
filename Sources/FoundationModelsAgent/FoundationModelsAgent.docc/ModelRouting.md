# Selecting a Native Model Route

Choose a native `LanguageModel` before creating an explicit-model ``AgentSession`` and
retain evidence explaining the decision.

## Overview

``FoundationModelsAgentRouter`` evaluates typed
``FoundationModelsAgentRouteCandidate`` values. Each candidate contains the native model
and a serializable ``FoundationModelsAgentRouteDescriptor`` covering:

- a stable application route ID and declared purpose;
- declared capabilities and reasoning support;
- a point-in-time availability and quota snapshot;
- privacy and network classes;
- known or unknown context size; and
- the system responsible for accounting or billing.

The router does not invoke the model and does not define a response, message, transcript,
or provider protocol. Pass the complete selection to
``AgentSession/init(selection:tools:instructions:configuration:contextMeasurer:toolConfiguration:checkpointStore:checkpointKey:transcriptRetention:requiresMatchingToolset:instructionRestorationPolicy:plugins:redactionPolicy:observers:observerDeliveryConfiguration:)``
so its native model and routing evidence cannot diverge.

## Supply deterministic application policy

Conform to ``FoundationModelsAgentRoutingPolicy`` or use
``ClosureFoundationModelsAgentRoutingPolicy``. The policy returns one primary route and
an ordered fallback list:

```swift
let policy = ClosureFoundationModelsAgentRoutingPolicy { request, candidates in
  FoundationModelsAgentRoutePlan(
    primaryRouteID: "local",
    fallbackRouteIDs: request.requiresReasoning ? ["private-cloud"] : []
  )
}
```

Return the same plan for the same inputs. The library records the returned plan but cannot
make a stateful or random application closure deterministic.

Fallback is disabled unless its route ID appears in
``FoundationModelsAgentRoutePlan/fallbackRouteIDs``. A fallback plan also does not grant
permission to cross a data boundary. ``FoundationModelsAgentRouteRequirements`` defaults
to ``FoundationModelsAgentRouteDataPolicy/onDeviceOnly``; the app must separately allow
the candidate's privacy and network classes.

## Snapshot Apple model state

Use ``FoundationModelsAgentRouteCandidate/onDevice(id:purpose:model:observedAt:)`` to
capture `SystemLanguageModel` availability, capabilities, context size, and the
on-device/no-network boundary.

Use
``FoundationModelsAgentRouteCandidate/privateCloudCompute(id:purpose:model:observedAt:)``
on supported systems to capture `PrivateCloudComputeLanguageModel` availability and
native quota state. The snapshot distinguishes below-limit, approaching-limit, and
limit-reached states. Its async context-size query runs only when the model is available;
a failed query remains explicit as an unknown context size.

These snapshots are point-in-time evidence, not a lease on future availability. Native
execution can still fail after selection, and ``AgentSession`` records that failure
without inventing usage the model did not expose.

A zero native context size is retained as `.known(tokenLimit: 0)`. Xcode 27 Beta 4 can
report that value for an available `SystemLanguageModel`; the router does not replace it
with a guessed capacity. A positive
``FoundationModelsAgentRouteRequirements/minimumContextTokens`` rejects that candidate,
while omitting the minimum leaves it eligible if its other requirements pass.

## Preserve evidence with the run

``FoundationModelsAgentRouteDecision`` includes the selected route, fallback status, and
one selected or rejected outcome for every candidate. Pass it alongside the selected
model:

```swift
guard case .selected(let selection) = router.select(
  from: candidates,
  requirements: requirements,
  policy: policy
) else {
  // Handle the no-route evidence in application UI.
  return
}

let session = try AgentSession(selection: selection)
```

The session records `routeSelected` and every `routeCandidateRejected` event before its
first model attempt. ``FoundationModelsAgentRun/routingDecision`` persists the complete
decision on both completed and failed runs. Completed responses retain native token usage;
failed runs leave usage `nil` when the native failure does not expose it.

## Keep third-party authentication outside routing

Third-party `LanguageModel` packages remain responsible for credentials, authentication,
entitlements, rate limits, and billing. Construct those native models outside the router
using the package's own secure setup. Use
``FoundationModelsAgentRouteAccountingProvenance/externalProvider(providerID:accountReference:)``
only to identify the accounting source.

The router does not accept secrets, authenticate providers, or verify billing state.
Never place API keys, tokens, or other credentials in route IDs, purposes, explanations,
or account references because routing decisions are intended to be exported as evidence.

Use this layer only with the explicit-model ``AgentSession`` initializer. The
dynamic-profile initializer intentionally accepts no routing decision because Foundation
Models selects its model internally, where external evidence could not prove which model
executed. Dynamic-profile tool governance remains available independently; governed
profile runs keep their governance events and a `nil`
``FoundationModelsAgentRun/routingDecision``.
