# ``FoundationModelsAgentEvaluations``

Bridge native Foundation Models agent evidence to Apple's Xcode 27 Evaluations framework.

## Overview

The optional `FoundationModelsAgentEvaluations` product adds small adapters for
Apple's `ToolCallEvaluator`, `TrajectoryExpectation`, `ModelSample`, and
`ModelSubject`. The core `FoundationModelsAgent` target remains independent of
the developer-only Evaluations framework.

Use `FoundationModelsAgentTrajectory` to capture an
inspectable, versioned path from native `Transcript` values and the verified
canonical `AgentReceiptBundle`, and
`FoundationModelsAgentTrajectoryFixtureExporter` to
write deterministic regression fixtures. Then convert a fixture to Apple's
evaluation types without replacing `LanguageModelSession` or its structured
transcript.

## Topics

### Evaluating paths

- <doc:Evaluating-Agent-Paths>

### Apple Evaluations adapters

- ``FoundationModelsAgentEvaluationsError``
- ``FoundationModelsAgent/FoundationModelsAgentTrajectory/Step/exactToolExpectation()``
- ``Evaluations/TrajectoryExpectation/init(foundationModelsAgentTrajectory:disallowedToolNames:allowsAdditionalToolCalls:)``
- ``Evaluations/ModelSubject/init(foundationModelsAgentValue:transcript:)``
- ``Evaluations/ToolCallEvaluator/init(foundationModelsAgentMetricPrefix:)``
