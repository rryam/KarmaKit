# Hierarchical Execution Evidence

Model parent, child, and background work without replacing Foundation Models
execution primitives.

## Overview

FoundationModelsAgent owns evidence types, not child execution. A
`ChildAgentTool`, application-owned task, or future background-task product can
create an ``AgentRunLineage`` and pass it to `AgentSession/respond(to:options:contextOptions:metadata:contextQuery:lineage:)`.
The receiving ``AgentSession`` continues to use its native
`LanguageModelSession` inner loop.

Lineage is immutable and contains:

- ``AgentRunID`` for the current and root runs;
- the optional parent ``AgentRunID``;
- an ``AgentTaskID`` for child and background work;
- zero-based ``AgentRunDepth``;
- ``AgentRunRelationshipKind/root``, ``AgentRunRelationshipKind/child``, or
  ``AgentRunRelationshipKind/background``.

A root run has depth zero and no parent or task. Child and background runs must
have a distinct root, a parent, a task, and positive depth. Use
``AgentRunLineage/descendant(runID:taskID:relationship:)`` to construct the
common case.

### Preserve lineage in evidence

New `AgentSession` responses create root lineage by default. Explicit lineage is
copied into ``FoundationModelsAgentRun`` and every
``FoundationModelsAgentEvent`` delivered to observers. Trace exports therefore
preserve the same ancestry.

``FoundationModelsAgentRunReceipt`` includes lineage in its version 2 chain
seed and in every hashed event. Changing a parent, root, task, depth, or
relationship without rebuilding the chain changes verification. Applications
that need attribution should still sign the final root hash.

Use ``AgentReceiptBundle`` to verify a complete forest. Its
`verify(maximumDepth:)` operation:

1. verifies every event hash chain;
2. requires unique run IDs and explicit lineage for hierarchical bundles;
3. rejects missing roots, missing parents, cycles, inconsistent roots, and
   inconsistent depths;
4. applies an optional caller-owned maximum depth;
5. checks each ``AgentTaskResult`` against its linked run receipt.

A single legacy receipt with no lineage remains valid and uses the original
version 1 seed. Legacy run and event exports decode missing lineage as `nil`.
Transcript checkpoints remain format 1 and do not persist execution evidence.

### Settle tasks deterministically

``AgentTaskResult`` is a terminal envelope for child and background work. It
contains lineage, status, output and evidence references, optional usage, an
optional receipt link, timing, and a typed termination reason.

The valid settlements are:

- ``AgentTaskSettlementStatus/succeeded`` with no failure or cancellation
  reason;
- ``AgentTaskSettlementStatus/failed`` with a failure reason;
- ``AgentTaskSettlementStatus/cancelled`` with a cancellation reason;
- ``AgentTaskSettlementStatus/ambiguousAfterCrash`` with a failure reason when
  recovery cannot prove whether an external effect happened.

The last state is deliberately distinct from failure. A scheduler or child tool
must not retry a possibly escaped side effect merely because its local receipt
was not durably settled.

``AgentEvidenceReference`` keeps output bodies and evidence storage
application-owned. Use `AgentTaskResult/redacted(using:)` before disclosure
when identifiers, locations, attributes, or termination messages may contain
credentials.

### Adopt from child and background work

A future child or background implementation should:

1. derive descendant lineage from the active parent before starting work;
2. pass that lineage to the child `AgentSession`;
3. export the child run receipt;
4. settle exactly one ``AgentTaskResult``;
5. persist or transmit the receipt bundle using application-owned storage.

It should not add a provider, message, transcript, routing, context-management,
or scheduler abstraction to these evidence types.
