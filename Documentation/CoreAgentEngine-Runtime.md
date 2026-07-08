# CoreAgentEngine Runtime

Date: 2026-07-08
Status: M3 closed-loop feedback gate foundation

`CoreAgentEngine` is the portable, Foundation Models-native trace foundation for
the broader LangSmith Engine-style improvement loop. It stores local run
evidence, groups typed issues, and now exposes host-owned Engine/Skills feedback
gates without autonomous PR creation or skill mutation.

## Implemented

- `CoreAgentEngineTrace`
  - Stores a project ID, optional thread ID, redacted `CoreAgentRun`,
    `CoreAgentRunReceipt`, and ingestion timestamp.
  - Receipt verification is over the stored redacted run, not the pre-redaction
    input.

- `CoreAgentEngineStore`
  - Portable async store protocol for trace ingestion, trace queries, issue
    upserts, issue status changes, and issue queries.
  - Ingestion rejects non-finalized runs and event run-ID mismatches.
  - Read APIs return only receipt-verified traces.

- `InMemoryCoreAgentEngineStore`
  - Actor-backed store for deterministic tests and local embedding.
  - Queries traces by project and optional thread.
  - Queries issues by project and optional lifecycle status.

- `CoreAgentEngineRedactionPolicy`
  - Redacts common token/API-key/password patterns in event messages.
  - Redacts attribute values when the attribute key is secret-marked, including
    canary values that do not match generic token regexes.

- `CoreAgentEngineIssueScanner`
  - Scans stored traces for `runFailed` events.
  - Builds deterministic issue fingerprints from typed failure evidence:
    event kind, `error_type`, and `tool`/`tool_name`.
  - Uses length-prefixed fingerprint fields so delimiter characters in typed
    attributes cannot merge unrelated failures.
  - Does not cluster from arbitrary prose.
  - Preserves existing issue lifecycle status on rescan.
  - Reopens resolved issues when a new contributing run appears.

- `CoreAgentRunObserver`
  - A CoreAgent hook that receives the finalized `CoreAgentRun` after all run
    events have been recorded.

- `CoreAgentEnginePlugin`
  - Session plugin/run observer that ingests the finalized `CoreAgentRun`
    object into a configured Engine store.
  - Reports ingestion failures through an explicit async callback.

- `CoreAgentSkillProposedFixArtifact`
  - Represents model-proposed fixes as typed Skills artifacts, not store writes.
  - The sleep optimizer is still the only mutation path and can require
    `CoreAgentSkillHeldoutValidationProof`; absent or invalid proof fails closed
    as `.validationDidNotImprove`.

## Downstream Integration

- `CoreAgentSkills` now consumes Engine traces through
  `CoreAgentSkillEngineTraceHarvester`.
  - The harvester treats the Engine store as a source boundary, not a blind
    trust boundary: it filters non-finalized traces and traces whose receipts do
    not verify the exact stored run events before creating SkillOpt rollout
    evidence.
  - Engine issue IDs are linked through safe digests/references in Skills;
    issue titles, fingerprints, failure attributes, event messages, and tool
    arguments are not copied into SkillOpt evidence.

- `CoreAgentAgenticKitFeedbackLoop` wires Deep rubric/RLM completion verdicts
  through Engine issue linkage into Skills proposals.
  - The bridge lives in `CoreAgentAgenticKit`, so `CoreAgentDeep` does not import
    Engine or Skills.
  - It requires an already verified Engine trace, upserts a typed rubric issue,
    harvests digest-bound evidence, and delegates mutation decisions to the
    proof-gated Skills sleep optimizer.

## Explicit Non-Goals For This Slice

- No LangSmith cloud export.
- No SQLite trace store yet.
- No cloud dataset/evaluator service yet.
- No autonomous PR creation.
- No autonomous self-improvement loop; hosts invoke feedback gates explicitly.
- No SwiftData, SwiftUI, App Intents, sandbox, or computer-use adapters.

Those should layer on this portable trace contract instead of replacing it.

## Verification

- `swift test --skip-update --filter CoreAgentEngineTests` passed 6 Engine
  tests after implementation.
- `swift test --skip-update --filter CoreAgentTests` passed 45 CoreAgent tests
  after adding the finalized-run observer hook.
- `swift test --skip-update` passed the full package suite.
- `swift build --skip-update` completed successfully.
- VibeProxy Engine/Skills review produced valid findings that were fixed with
  regressions. `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 17 focused tests after those fixes.
- `swift test --filter enginePluginProducesNoAutonomousMutation` passed after a
  red compile failure on the missing typed artifact/proof gate.
- `swift test --filter rubricVerdictGatesEngineSkillsFeedbackLoop` passed after
  a red compile failure on the missing AgenticKit feedback loop.
