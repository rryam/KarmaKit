# VibeProxy Apple Platform Foundation Adjudication

Date: 2026-07-06
Endpoint: `http://127.0.0.1:8320/v1/chat/completions`
Scope: `CoreAgentApplePlatform` foundation diff

## Model Status

- `gpt-5.5`: HTTP 200, artifact `gpt-5.5.md`
- `gemini-3.5-flash-low`: HTTP 200, artifact `gemini-3.5-flash-low.md`
- `claude-haiku-4-5-20251001`: HTTP 200, artifact `claude-haiku-4-5-20251001.md`

Prompt artifact: `prompt.md`
Diff artifact: `diff.patch`

## Accepted Findings Fixed

- Checkpoint sidecar `savedAt` was digest-bound but not compared to the decoded
  canonical checkpoint payload after decode. Fixed with
  `savedAtMismatch(expected:actual:)` and a recomputed-digest regression.
- Checkpoint logical identity was not in the envelope digest. Fixed by binding
  `checkpointID` into the digest and adding replay regression coverage.
- Digest timestamp framing used raw `Double.bitPattern`. Fixed with a stable
  rounded nanosecond token and verified through an in-memory SwiftData
  `ModelContext` round trip.
- `CoreAgentRunProjectionStore.apply(traces:)` replaced existing projections
  with only the supplied batch. Fixed by seeding from existing projections and
  adding incremental merge coverage.
- Consent receipt verification used string equality. Fixed with CryptoKit
  `HMAC<SHA256>.isValidAuthenticationCode`.
- `CoreAgentAppleConsentReceipt.issue` could create receipts with nil expiry
  even though the gate requires expiry. Fixed by requiring `expiresAt` for
  issued receipts and keeping only the transport initializer capable of
  representing legacy invalid receipts.
- App Intent execution and donation consent fingerprints needed an explicit
  request-type split. Fixed with an `app-intent-execution` discriminant and
  donation-to-execution replay regressions.
- Descriptor validation unexpected errors were mislabeled as consent receipt
  errors. Fixed with `unexpectedAppIntentDescriptorError`.
- Projection docs did not explain why raw messages/attributes/receipts are
  omitted from SwiftUI state. Fixed in
  `Documentation/CoreAgentApplePlatform-Runtime.md`.

## Adjudicated Non-Blockers

- The claim that nil `consentSigningKey` accepts arbitrary receipts was false:
  the gate returns `.consentVerifierUnavailable(...)` before signature
  verification. Added a regression so the intended fail-closed behavior is
  explicit.
- The claim that digest verification happens after JSON decode was false in the
  current code path. Digest verification runs before decoding canonical
  checkpoint bytes.
- The claim that two different checkpoints with the same timestamp can produce
  the same digest was false: the digest includes a SHA-256 of the canonical
  checkpoint bytes, not only timestamp metadata.
- SwiftData ORM mutation/migration barriers remain a live-store implementation
  requirement, not something this foundation wrapper can fully enforce. The
  current record exposes metadata as `public private(set)`, keeps canonical
  bytes authoritative, and detects inconsistent readback through the digest.
  Live `ModelContext` store conformances and migration barriers remain recorded
  future work.

## Verification

- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 17
  tests after the fixes.
- `swift test --skip-update` passed after the fixes.
- `swift build --skip-update` passed after the fixes.
- `git diff --check` passed after the fixes.
- Trailing-whitespace scan over tracked-modified and untracked text artifacts
  passed after the fixes.
