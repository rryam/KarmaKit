# Evaluating Agent Paths

Measure destination quality and the path an agent took as separate concerns.

## Capture a deterministic fixture

Build the trajectory from authoritative native transcripts and a canonical
`AgentReceiptBundle`:

```swift
let response = try await agent.respond(to: prompt)
let receipt = try FoundationModelsAgentRunReceipt(run: response.run)
let evidence = AgentReceiptBundle(receipts: [receipt])
let trajectory = try FoundationModelsAgentTrajectory(
  transcripts: [
    response.run.lineage!.runID: try await agent.transcript()
  ],
  evidenceBundle: evidence
)

let data = try FoundationModelsAgentTrajectoryFixtureExporter().data(
  for: trajectory,
  named: "read-only report lookup",
  expectedDestination: "Q4 is the newest report."
)
```

The validating initializer verifies every receipt, lineage, task settlement,
and evidence reference before conversion. For child-agent evaluation, put all
root and child receipts plus their `AgentTaskResult` values in the bundle and
key each available transcript by its canonical `AgentRunID`. The projected
evidence graph preserves only relationships already present in that bundle,
including child/task lineage and routing, context, governance, or tool event
references. Missing child transcripts remain explicit issues.
If a bundle contains multiple rooted trees, every run is exported but no
primary trajectory is selected; export one root tree per evaluation fixture.

The default exporter remaps run, task, event, evidence-reference, transcript,
and segment identifiers while retaining their relationships. It sorts JSON
keys and redacts common credential strings, sensitive argument names, evidence
attributes, locations, and terminal reasons. Check the resulting JSON into a
fixture directory and review changes like ordinary source changes.

Unsupported attachment, custom, and future transcript segments produce
explicit segment records and issues. Provider-specific code can export those
values separately; the generic exporter never claims to preserve opaque
content it cannot inspect.

Canonical events carrying `native_call_id` link terminal outcomes to that exact
native call. Legacy name-only events use a conservative fallback only when one
remaining call and outcome are unambiguous. A native output stays authoritative
if event evidence conflicts, and duplicate IDs, missing outputs, or conflicting
events produce explicit issues instead of guessed linkage.

## Evaluate the destination

The fixture's `expectedDestination` becomes the expected value of the generated
`ModelSample<String>`. Apply a deterministic `Evaluator`, or an Apple-provided
content evaluator suited to the task, to compare the subject value with that
expectation.

Do not infer destination quality from a passing path. A correct sequence of
tools can still produce the wrong answer.

## Evaluate the path

Convert the fixture to a model sample:

```swift
let sample = try fixture.modelSample(
  prompt: "Find the newest report.",
  disallowedToolNames: ["delete_report"],
  allowsAdditionalToolCalls: false
)
```

Observed tool calls become ordered `ToolExpectation` values. Scalar arguments
become exact `ArgumentMatcher` values in sorted key order. Nested objects,
arrays, and null throw ``FoundationModelsAgentEvaluationsError`` because Xcode
27 Beta 4's `ArgumentValue` has no lossless representation for them.

Return the destination and Apple's structured view of the same native
transcript from the evaluation subject:

```swift
let response = try await agent.respond(to: sample.prompt)
return ModelSubject(
  foundationModelsAgentValue: response.content,
  transcript: try await agent.transcript()
)
```

Add a typed tool-call evaluator with consistent metrics:

```swift
let path = ToolCallEvaluator<ModelSample<String>>(
  foundationModelsAgentMetricPrefix: "report_path"
)
```

`path.allPass` reports strict success. `path.percentagePass` helps distinguish a
nearly correct path from one that missed every expected call. Disallowed calls
fail the path even if the final text looks correct, and
`allowsAdditionalToolCalls: false` makes any unexpected call fail.

## Keep evaluation out of production

Add `FoundationModelsAgentEvaluations` only to an Xcode 27 test or evaluation
target. Application targets need only `FoundationModelsAgent`. The optional
bridge does not add a model-as-judge layer, provider abstraction, message
format, or second agent loop.
