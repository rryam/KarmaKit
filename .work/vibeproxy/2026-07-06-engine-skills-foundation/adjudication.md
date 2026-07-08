# VibeProxy Adjudication: Engine And Skills Foundation

Date: 2026-07-06
Scope: `CoreAgentEngine`, `CoreAgentSkills`, and the finalized-run observer hook.

## Inputs

- Prompt: `.work/vibeproxy/2026-07-06-engine-skills-foundation/prompt.md`
- Responses:
  - `gpt-5.5.md`
  - `gemini-3.5-flash-low.md`
  - `claude-haiku-4-5-20251001.md`

## Reviewer Outcomes

- `gpt-5.5`: BLOCK before fixes. Valid findings: verified readback, finalized-run validation, plugin ingestion failure reporting.
- `gemini-3.5-flash-low`: BLOCK before fixes. Valid findings: verified readback, skill version collisions, resolved issue reopening, duplicate harness candidate crash. False findings: `.v27` platform support and corrupted `CoreAgentSession` syntax; the local Xcode 27 build/test run proves both are false.
- `claude-haiku-4-5-20251001`: BLOCK before fixes. Valid findings: bounded redaction regexes and delimiter-safe issue fingerprints. Partially valid: whitespace-only replacement targets should fail explicitly. False findings: actor-isolated `recordRejected` is not unsafe because Swift actor methods are asynchronously isolated from outside the actor; receipt timestamp binding is a later trace-envelope enhancement, not a blocker for `CoreAgentRunReceipt` integrity.

## Fixes Applied

- `InMemoryCoreAgentEngineStore` now rejects non-finalized runs and event run-ID mismatches before storage.
- Engine trace read APIs now return only receipt-verified traces.
- `CoreAgentEnginePlugin` now accepts an `onIngestFailure` callback instead of silently swallowing ingestion errors.
- Resolved Engine issues transition to `reopened` when a new contributing run appears.
- Engine failure fingerprints use length-prefixed fields to avoid delimiter collisions.
- Engine redaction regex quantifiers are bounded.
- `InMemoryCoreAgentSkillStore.save(_:)` rejects duplicate skill versions.
- `CoreAgentSkillEdit.replace` rejects whitespace-only targets.
- `CoreAgentHarnessOptimizer` rejects duplicate candidate IDs before building lookup tables.

## Regression Evidence

- `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'` passed 17 focused tests after fixes.
- `swift test --skip-update` passed the full package suite after fixes.
- `swift build --skip-update` completed successfully after fixes.
- `git diff --check` completed successfully after fixes.
- Direct trailing-whitespace scan over changed text files found no matches after generated artifact cleanup.

