# CoreAgentSkills Runtime

Date: 2026-07-06
Status: Slice 4 SkillOpt local foundation, local SkillOpt-Sleep policy loop, Engine trace replay foundation, typed replay/dream execution, durable file-backed skill storage, typed multi-objective evaluator adapters, typed model-proposal backend boundary, and concrete FoundationModels proposal backend

`CoreAgentSkills` is the portable skill curation and text-space optimization
target. It follows SkillOpt's stable contract at the Swift boundary: skill
documents are trainable external state, edits are typed and bounded, held-out
validation gates acceptance, and rejected edits become optimizer memory instead
of silent prompt drift.

## Implemented

- `CoreAgentSkill`
  - Versioned skill document with ID, title, body, tags, priority, and accepted
    provenance.

- `CoreAgentSkillStore`
  - Portable actor-safe storage boundary for skill saves, current-skill lookup,
    all-current curation, optimizer memory, rejected edits, and
    meta-observations.
  - Used by the curator, direct optimizer, and sleep optimizer so durable and
    in-memory stores share the same optimization contract.

- `InMemoryCoreAgentSkillStore`
  - Actor-backed skill history and current-skill lookup.
  - Stores optimizer memory separately from the current skill body.

- `FileCoreAgentSkillStore`
  - Persists versioned skill rows under `skills/` and optimizer memory under
    `optimizer-memory/`.
  - Hashes skill IDs before using them as path components; raw model/user skill
    IDs are never filesystem names.
  - Writes `version-N.json` rows with exclusive create and maps collisions to
    `versionCollision`, preventing silent overwrite after resume.
  - Fails closed on corrupted rows, misplaced rows, filename/version mismatch,
    and decoded skill IDs that do not map back to the containing directory.
  - Rejects future rejected-edit/meta-observation mutations when optimizer
    memory is corrupt instead of overwriting it with empty memory.
  - Exports the current best skill as `best_skill.md` by default and supports
    explicit safe plain-file export names.

- `CoreAgentSkillCurator`
  - Selects current skills by tag, priority, stable ID ordering, and character
    budget.
  - Skips oversized skills rather than truncating skill text into an invalid
    partial instruction.

- `CoreAgentSkillEdit` and `CoreAgentSkillEditLimits`
  - Typed edit operations: unique-target replace and append.
  - Edit and resulting-skill character budgets enforce bounded text changes.
  - Replacement fails unless the target occurs exactly once.
  - Whitespace-only replacement targets are rejected.

- `CoreAgentSkillOptimizationPolicy` and `CoreAgentSkillOptimizer`
  - Applies candidate edits only when policy validation, held-out validation,
    split isolation, protected-region policy, edit budgets, and minimum score
    delta pass.
  - Accepted edits increment skill version and record held-out provenance.
  - Rejected edits are retained as optimizer memory without mutating the skill.
  - Duplicate skill versions are rejected to avoid lost updates.
  - Validation scores must be finite, in range, and tied to non-empty held-out
    suite IDs.

- `CoreAgentSkillSleepOptimizer`
  - Runs a bounded local SkillOpt-Sleep style proposal pass over current skill
    state.
  - Preflights duplicate proposal IDs, skill existence, validation metadata, and
    would-be-accepted edit application before any mutation, so malformed later
    proposals cannot leave a half-applied sleep run.
  - Records rollout evidence IDs, accepted/rejected decisions, skill-version
    movement, rejected edits, and meta-observations.
  - Enforces training/held-out split isolation, max accepted proposals,
    protected slow-update regions, and open-ended malformed protected markers
    fail-closed for append operations.

- `CoreAgentSkillEngineTraceHarvester`
  - Converts local `CoreAgentEngine` traces into `CoreAgentSkillRolloutEvidence`
    for SkillOpt loops.
  - Locally filters out non-finalized traces and traces whose receipts do not
    verify the exact stored run events, so custom `CoreAgentEngineStore`
    conformers cannot feed partial or tampered evidence into Skills.
  - Emits deterministic transcript/tool-event digests, safe issue/run
    references, typed status/score metadata, token counts, and issue lifecycle
    status.
  - Does not copy raw event messages, tool arguments, failure attributes,
    issue titles, issue fingerprints, or verifier prose into evidence.

- `CoreAgentSkillReplayGenerator`
  - Creates deterministic replay and dream rollout request records from
    harvested rollout evidence.
  - Validates held-out suite IDs and request caps.
  - Excludes configured source/training suites and treats missing source-suite
    metadata as unknown when a split-exclusion policy is active.
  - Preserves only digest/reference metadata needed for replay selection, not
    verifier feedback or raw trace payloads.

- `CoreAgentSkillReplayBackend`, `CoreAgentSkillReplayOutcome`,
  `CoreAgentSkillReplayExecutionPolicy`, and `CoreAgentSkillReplayExecutor`
  - Execute replay/dream request records through a typed backend boundary and
    convert outcomes into `CoreAgentSkillRolloutEvidence`.
  - Preflight the full request batch before backend calls so malformed later
    requests cannot leave a partial replay execution run.
  - Reject duplicate request IDs, empty request identity fields, invalid
    held-out suite IDs, invalid lowercase `sha256:` digests, invalid scores,
    backend/request ID mismatches, empty source-suite metadata, same
    source/held-out suite execution, and excluded source suites.
  - Copy only allowed replay/reference metadata into evidence, canonicalize
    source-suite metadata, store raw verifier-feedback digests instead of
    prose, and emit sanitized verifier feedback.
  - Produce deterministic replay evidence IDs from request/outcome digests,
    score, and verifier-feedback digest.

- `CoreAgentSkillModelProposalRequest`,
  `CoreAgentSkillModelProposalEvidenceReference`,
  `CoreAgentSkillModelProposalBackend`,
  `CoreAgentSkillModelProposalCandidate`, and
  `CoreAgentSkillModelProposalGenerator`
  - Provide a typed backend boundary for model-generated SkillOpt proposals.
  - Build sanitized backend requests by stripping skill provenance, omitting
    rollout verifier feedback, allowlisting evidence metadata, and validating
    evidence identity, lowercase SHA-256 digests, scores, and duplicate
    evidence IDs before backend exposure.
  - Treat backend candidates as untrusted: validate safe proposal IDs,
    duplicate IDs, matching skill/baseline, non-empty edits, edit-count caps,
    validation scores/suites, training-suite leakage, edit applicability, known
    evidence IDs, empty evidence IDs, and duplicate candidate evidence IDs.
  - Return existing `CoreAgentSkillSleepOptimizationProposal` values with
    sanitized validation notes and sanitized evidence references so mutation
    remains in `CoreAgentSkillSleepOptimizer`.

- `CoreAgentSkillFoundationModelsProposalBackend`
  - Provides the concrete FoundationModels-native SkillOpt proposal backend over
    `CoreAgentSession.respond(generating:)` and private `@Generable` structured
    proposal DTOs.
  - Sanitizes direct backend requests before prompt construction: validates
    policy, max proposal counts, baseline scores, evidence identity fields,
    lowercase `sha256:` transcript/tool digests, duplicate evidence IDs, and
    evidence scores.
  - Strips skill provenance, allowlists evidence metadata, omits rollout
    verifier feedback, and prompts with explicit `replace`/`append` edit
    operation literals.
  - Maps only exact literal edit operations into typed `CoreAgentSkillEdit`
    values; whitespace-padded, differently cased, or unknown operations fail
    closed before candidate handoff.
  - Does not mutate skill stores. Candidate trust and mutation remain governed
    by `CoreAgentSkillModelProposalGenerator` and `CoreAgentSkillSleepOptimizer`.

- `CoreAgentSkillExporter`
  - Exports the current skill as `best_skill.md`-style Markdown.

- `CoreAgentHarnessOptimizer`
  - Selects the best harness candidate from held-out evaluation results.
  - Keeps an audit trail sorted by mean held-out score.
  - Duplicate candidate IDs are rejected before lookup construction.

- `CoreAgentHarnessObjectiveID`, `CoreAgentHarnessObjective`, and
  `CoreAgentHarnessObjectiveEvaluation`
  - Provide typed multi-objective evaluation inputs for SkillOpt and harness
    optimization.
  - Objectives have positive finite weights, maximize/minimize direction, and
    optional required normalized mean gates.
  - Evaluations bind candidate ID, held-out suite ID, objective ID, and finite
    `0...1` scores.

- Multi-objective `CoreAgentHarnessOptimizer.selectBest`
  - Aggregates objective scores by candidate/objective across held-out suites.
  - Normalizes minimize objectives as `1 - score` before weighting or required
    gate checks.
  - Ranks eligible candidates before ineligible candidates, then by weighted
    score descending, then candidate ID ascending.
  - Emits objective-aware audit entries with raw mean, normalized mean,
    weighted contribution, sorted held-out suites, and required-gate result.
  - Fails closed for duplicate objective IDs, duplicate
    candidate/suite/objective evaluation triples, unknown candidates, unknown
    objectives, missing rows, invalid weights/scores/required means, empty
    objective IDs, empty held-out suite IDs, and no eligible candidate.
  - Uses typed evaluation keys for duplicate detection, so IDs containing
    delimiter characters cannot collide.

- `CoreAgentSkillMultiObjectiveValidationAdapter`
  - Collapses one candidate's typed objective evaluations into the existing
    scalar `CoreAgentSkillValidationResult` accepted by SkillOpt proposal
    gates.
  - Preserves caller-supplied held-out suite ID and notes.
  - Rejects mismatched evaluation suite labels so scalar validation cannot be
    mislabeled.

- `CoreAgentSkillOptimizationRunExecutor` and typed run request/report types
  - Orchestrates the local SkillOpt cross-run workflow: optional Engine trace
    harvest, replay request generation/execution, optional model-proposal
    generation, optional meta-skill branch-state audit, and
    `CoreAgentSkillSleepOptimizer` mutation.
  - Fails closed when harvest is configured without an executor `engineStore`,
    when harvested Engine token usage exceeds `maximumTotalTokens`, when
    proposal generation is configured without optimization targets, or when
    seed/supplied proposal IDs are invalid or duplicated. The token gate aborts
    before proposal generation and before the sleep optimizer can mutate a
    skill.
  - Dedupes rollout evidence by ID across seed, harvested, and replay phases
    before proposal generation.
  - Emits ordered phase records (`harvested`, `replayGenerated`,
    `replayExecuted`, `proposalsGenerated`, `frontierSelected`,
    `sleepOptimized`) for audit/UI.

- `CoreAgentSkillOptimizationCrossRunSchedulerPlan` and policy/decision values
  - Provide a pure, deterministic, host-invoked plan for ordering the next
    `CoreAgentSkillOptimizationRunRequest` backlog from prior
    `CoreAgentSkillOptimizationRunReport` records.
  - Carry over backlog requests whose run IDs have not appeared in prior
    reports, expose the full carried-over run ID order, and limit the returned
    next requests per host invocation.
  - Optionally prioritize carry-over requests targeting skills that had
    rejected sleep proposals in prior reports, with stable run-ID/report
    canonicalization so input report ordering does not affect output ordering.
  - Are `Sendable` data values only. They expose a `.hostInvoked` trigger and
    no timer, thread, daemon, `Task`, or dispatch/run entry point.

- `CoreAgentSkillMetaEvolutionFrontierSelector`
  - Selects and orders a typed proposal frontier before sleep optimization,
    inspired by MetaSkill-Evolve productivity/novelty scoring and RQGM
    strict/loose evaluator checks.
  - Filters high hack-ratio proposals and low-novelty proposals through explicit
    policy gates before mutation.
  - Validates proposal IDs, score identity, finite normalized scores, nested
    objective evidence, duplicate score rows, unknown proposals, policy weights,
    novelty gates, and hack-ratio gates fail-closed.
  - Wires into `CoreAgentSkillOptimizationRunExecutor` as an optional
    `frontierSelected` phase. The selector can only filter/order proposals;
    skill mutation still runs through `CoreAgentSkillSleepOptimizer`.

- `CoreAgentSkillMetaSkillBranchSnapshot` and
  `CoreAgentSkillMetaSkillEvolutionRecord`
  - Store MetaSkill-Evolve-style branch-local meta-skill state in
    `CoreAgentSkillOptimizerMemory`, keyed by skill ID, without raw prompts,
    transcripts, evaluator prose, or branch payloads.
  - Snapshot analyzer/retriever/allocator/proposer/evolver identity with
    lowercase SHA-256 component digests, policy versions, objective digest,
    branch ID, optional parent branch ID, and epoch.
  - Record evolution audits with advancing epochs and separate
    `frontierRejectedProposalIDs`, `sleepAcceptedProposalIDs`, and
    `sleepRejectedProposalIDs` so frontier filtering is not conflated with
    sleep-optimizer rejection.
  - Fail closed on unsafe branch/run/proposal IDs, invalid digests,
    non-advancing epochs, duplicate snapshot/evolution identities, duplicate
    proposal IDs, and corrupt file-backed optimizer memory.
  - `CoreAgentSkillOptimizationRunRequest.metaSkill` records a snapshot before
    harvest/replay/memory/proposal/frontier/sleep work, and records one
    `metaSkillEvolved` audit after a sleep report exists. Scheduler cadence,
    recursion budgets, and branch selection remain host-owned non-goals.

## Explicit Non-Goals For This Slice

- No scheduled/nightly daemon or self-triggering scheduler in the library. The
  cross-run plan is host-invoked and does not execute requests.
- No production model-backed replay/dream simulator yet.
- No autonomous production proposer scheduler yet; callers provide the
  `CoreAgentSession` and run policy.

Those should build on this typed edit, validation, and optimizer-memory
contract.

## Verification

- `swift test --skip-update --filter CoreAgentSkillsTests` passed 5 Skills
  tests after the initial foundation implementation.
- `swift test --skip-update` passed the full package suite after adding the
  Skills target.
- `swift build --skip-update` completed successfully.
- VibeProxy Engine/Skills review produced valid findings that were fixed with
  regressions. `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 17 focused tests after those fixes.
- SkillOpt-Sleep hardening added 12 more focused tests; `swift test
  --skip-update --filter CoreAgentSkillsTests` passed 17 Skills tests after
  fixing VibeProxy blockers. Final L20 VibeProxy recheck passed on GPT-5.5,
  Gemini 3.5 full-file rerun, and Haiku.
- Engine trace harvest/replay request hardening added 4 more focused tests;
  `swift test --skip-update --filter CoreAgentSkillsTests` passed 21 Skills
  tests, and `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 32 focused Engine/Skills tests.
- Initial L22 VibeProxy review found valid privacy and trust-boundary blockers:
  raw failure attributes and issue titles could have entered SkillOpt evidence,
  and a custom Engine store could have returned unverified or non-finalized
  traces. Those blockers were fixed with regression coverage.
- Final L22 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku.
- Final L22 verification passed `swift test --skip-update`, `swift build
  --skip-update`, and the focused commands above.
- File-backed store hardening added 6 more focused tests; `swift test
  --skip-update --filter CoreAgentSkillsTests` passed 27 Skills tests, and
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 38 focused Engine/Skills tests.
- Initial L23 VibeProxy review found valid durability and integrity blockers:
  corrupt optimizer memory could be reset, valid rows could be accepted from
  the wrong skill directory, filename/version mismatches were not rejected, and
  explicit export filenames needed path-safety checks. Those blockers were
  fixed with regression coverage.
- Final L23 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku.
- Final L23 verification passed `swift test --skip-update`, `swift build
  --skip-update`, `git diff --check`, and a targeted trailing-whitespace scan
  over the touched Skills/package/docs files.
- Multi-objective evaluator hardening added 5 more focused tests; `swift test
  --skip-update --filter CoreAgentSkillsTests` passed 32 Skills tests, and
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 43 focused Engine/Skills tests.
- Initial L24 VibeProxy review found valid blockers around minimize
  required-score gates using raw means and delimiter-joined duplicate
  evaluation keys. Those blockers were fixed with regression coverage.
- A follow-up GPT residual risk around adapter held-out suite mislabeling was
  fixed by rejecting mismatched evaluation suite labels before scalar
  validation is returned.
- Final L24 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku.
- Final L24 verification passed `swift test --skip-update`, `swift build
  --skip-update`, `git diff --check`, and a targeted trailing-whitespace scan
  over the touched Skills/package/docs files.
- Replay executor hardening added 2 more focused tests; `swift test
  --skip-update --filter CoreAgentSkillsTests` passed 34 Skills tests, and
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 45 focused Engine/Skills tests.
- Sidecar review found valid blockers around non-hex digest acceptance,
  request-time split bypass, and raw backend verifier-feedback leakage. Those
  blockers were fixed with regression coverage.
- Initial L25 VibeProxy review found valid blockers around empty
  `source_suite_id` using the wrong error path and whitespace-padded
  `source_suite_id` bypassing held-out/excluded-suite checks. Those blockers
  were fixed with regression coverage.
- Final L25 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku.
- Focused L25 verification passed `swift test --skip-update --filter
  CoreAgentSkillsTests`, `swift test --skip-update --filter
  'CoreAgentEngineTests|CoreAgentSkillsTests'`, `swift test --skip-update`,
  `swift build --skip-update`, `git diff --check`, and a targeted
  trailing-whitespace scan over the touched Skills/package/docs files.
- Model-proposal boundary hardening added typed request/backend/candidate/
  generator APIs and two focused model-proposal tests. `swift test
  --skip-update --filter CoreAgentSkillsTests` passed 36 Skills tests, and
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
  passed 47 focused Engine/Skills tests.
- Initial L26 VibeProxy review passed on GPT-5.5, Gemini 3.5, and Haiku.
  Follow-up coverage addressed reviewer gaps around invalid policy before
  backend calls, backend maxProposals overflow, unsafe/path-shaped proposal
  IDs, empty held-out suites, empty candidate evidence IDs, and duplicate
  candidate evidence IDs.
- L26 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku.
- FoundationModels proposal backend hardening added 3 focused backend tests;
  `swift test --skip-update --filter
  CoreAgentSkillsTests/foundationModelsProposalBackend` passed those tests,
  `swift test --skip-update --filter CoreAgentSkillsTests` passed 39 Skills
  tests, and `swift test --skip-update --filter
  'CoreAgentEngineTests|CoreAgentSkillsTests'` passed 50 focused
  Engine/Skills tests.
- Initial L27 VibeProxy review found a valid literal-operation blocker:
  whitespace-padded operation strings were accepted. A red/green regression now
  proves `" replace"` fails closed, and the backend requires exact `replace` or
  `append` literals.
- L27 VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku. Full-package
  verification then passed `swift test --skip-update`, `swift build
  --skip-update`, `git diff --check`, and a targeted trailing-whitespace scan
  over the touched Skills/package/docs files.
