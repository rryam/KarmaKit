# L17 VibeProxy Adjudication: Apple Deterministic Interpreter

Date: 2026-07-06
Endpoint: `http://127.0.0.1:8320/v1/chat/completions`
Models: `gpt-5.5`, `gemini-3.5-flash-low`, `claude-haiku-4-5-20251001`

## Fixed

- Non-finite numeric values entering through request inputs, literals, emit,
  output, concatenate, and arithmetic results. The interpreter now preflights
  inputs and instruction literals, validates resolved values before use, rejects
  non-finite arithmetic results, and uses deterministic JSON digest encoding
  without `String(describing:)` fallback.
- Unbounded intermediate state. Execution limits now cover input bytes, value
  bytes, state bytes, operand count, variable count, identifier length,
  instruction count, and output bytes. Assignment checks run before storing
  variables.
- Cancellation. The async interpreter now checks `Task.isCancelled` before
  execution and inside the instruction loop and returns typed `.cancelled`
  failure status with audit metadata.
- Unsafe identifiers and output names. Variable/input identifiers are bounded
  ASCII identifiers; output names are bounded and path-contained. Duplicate
  output names fail closed without overwriting prior output.
- Consent receipt replay. Consent-required actions now consume receipt IDs once
  per authority/policy/capability/request fingerprint.
- Future-dated grants. Consent validation rejects receipts whose `grantedAt` is
  after the gate clock.
- Weak consent signing keys. `CoreAgentAppleConsentSigningKey` now requires at
  least 32 bytes of key material.

## Adjudicated As False Or Out Of Scope

- App Intent descriptor validation bypass: false against current code. Descriptor
  validation is returned as `preflightDenial` and `evaluate` checks preflight
  denial before capability or consent handling.
- App Intent manifest signing: valid future hardening, not L17 scope. Current
  descriptors are already fingerprint-bound into consent receipts; a trusted
  manifest registry should be added when concrete `AppIntent` wrappers exist.
- Append-only audit sink: valid future hardening, not L17 scope. L17 returns a
  typed audit envelope; durable append-only logging belongs in the later engine
  or host integration layer.
- OS sandbox enforcement: not claimed by L17. The deterministic interpreter has
  no file/network/process instruction authority. WASI/helper/remote/container
  backends remain future slices and must enforce isolation separately.

## Verification

- `swift test --skip-update --filter CoreAgentApplePlatformTests.deterministicCodeInterpreter`
  and the focused action-gate signing-key/receipt tests passed after fixes.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 66
  Apple-platform tests after fixes.
