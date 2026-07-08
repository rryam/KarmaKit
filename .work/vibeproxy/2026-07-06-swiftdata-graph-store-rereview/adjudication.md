# SwiftData Graph Persistence VibeProxy Adjudication

Date: 2026-07-06
Endpoint: `http://127.0.0.1:8320/v1/chat/completions`
Models: `gpt-5.5`, `gemini-3.5-flash-low`, `claude-haiku-4-5-20251001`

## Scope

Reviewed L16: `CoreAgentApplePlatform` SwiftData graph checkpoint and graph
key/value store persistence over `CoreAgentGraph` protocols.

## Valid Findings Fixed

- Checkpoint lookup/history originally skipped corrupt matching rows via
  optional decode and `compactMap`, allowing stale fallback.
- Graph checkpoint latest/history originally sorted by step/timestamps rather
  than reverse save order.
- Store reads and key listing originally skipped corrupt rows rather than
  failing closed.
- Scope-key predicates originally allowed forged logical-sidecar rows to be
  skipped before validation.
- `latest` originally decoded full history; it now validates only the newest
  candidate for O(1) resume while `history` validates all candidates.
- Store `keys` originally decoded generic payloads and mislabeled valid
  heterogeneous rows as corruption.
- Store `put`/`removeValue` originally decoded existing rows as the current
  generic value type before mutation instead of validating structural integrity.
- Graph mutation rollback defaults originally allowed caller-supplied contexts
  to keep failed staged mutations by default.
- Scoped checkpoint tie ordering was under-specified for equal save sequences.
- `CoreAgentGraphStoreRecord` lacked conditional `Codable` conformance.
- Extreme `Date` values could overflow the nanosecond digest token conversion.

## Final R4 Result

- `gpt-5.5`: clean JSON result with no findings, residual risks, or testing gaps.
- `gemini-3.5-flash-low`: remaining comments challenge deliberate fail-closed
  behavior for corrupt/forged rows and note uniqueness constraints as residual
  risk. No code change taken; ordinary mutation should not silently delete or
  overwrite corrupt state.
- `claude-haiku-4-5-20251001`: remaining comments mark the forged-scope-key
  predicate, date clamping, rollback default, and save-sequence behavior as
  intentional or acceptable under the stated contract.

## Local Verification At Adjudication

- `swift test --skip-update --filter CoreAgentApplePlatformTests.swiftDataGraph`
  passed 11 graph-focused Apple tests.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 57
  Apple-platform focused tests.
