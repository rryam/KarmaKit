# L18 VibeProxy Adjudication: Apple Computer-Use Executor

Date: 2026-07-06
Endpoint: `http://127.0.0.1:8320/v1/chat/completions`
Models: `gpt-5.5`, `gemini-3.5-flash-low`, `claude-haiku-4-5-20251001`

## Fixed

- Execution consent was initially bound only to `actionID`. Fixed by adding
  `.computerUseExecution(actionID:approvedPlanDigest:)` and requiring execute
  requests to carry an approved plan plus digest from a prior dry-run in the
  same executor. The executor no longer re-plans after consent.
- Backend-controlled evidence requirements were too weak. Fixed by enforcing a
  non-removable baseline `.screenshotDigest` requirement even when
  `minimumRequiredEvidence` is initialized as an empty array.
- Request/plan structure was under-validated. Fixed with bounded non-empty
  request IDs/action IDs, non-empty bounded plan steps, unique step IDs,
  bounded and unique evidence requirements, and invalid-plan failures.
- Evidence digest validation accepted broad Unicode numeric characters. Fixed
  with exact `sha256:` prefix, 64-character length, and ASCII hex scalar
  validation.
- Cancellation after `backend.execute` could report success. Fixed by checking
  cancellation after backend execution and preserving returned evidence with
  `.failed(.cancelled)`.
- Backend `CancellationError` during planning/execution could be reported as
  `.backendFailed`. Fixed by catching `CancellationError` and checking
  `Task.isCancelled` in catch paths.
- The approved-plan registry could grow without bound. Fixed with a bounded
  FIFO in-memory registry.

## Adjudicated As False Or Stale

- Claims that `sha256Hex` and `stableTimeToken` were undefined were stale
  against the full source file. Both helpers exist in
  `CoreAgentApplePlatform.swift`.
- Claims that HMAC verification does not compile were stale. The full package
  and Apple-platform suite compile and pass.
- Claims that `issuerID` is not signed were false against the current
  `CoreAgentAppleConsentReceipt.signaturePayload`, which includes `issuerID`.

## Deferred Residual Risks

- Approved dry-run plan digests and consumed consent receipts are in-memory
  process-local state. Durable cross-process registries belong in a later host
  integration or SwiftData-backed authority store.
- Evidence digests prove syntax and required presence, not capture honesty,
  freshness, or OS-level attestation. Raw UI automation backends must provide
  trusted screenshot/accessibility capture and digest computation.
- Dry-run `plan` is a host-supplied closure. The type and docs enforce
  side-effect-free planning by contract, but a malicious backend can still do
  side effects inside its planning closure. A real backend should split planning
  from privileged automation implementation.

## Verification

- `swift test --skip-update --filter CoreAgentApplePlatformTests.computerUse`
  passed 7 focused tests.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 73
  Apple-platform tests.
- Final VibeProxy r3 recheck passed targeted checks on all three models.
