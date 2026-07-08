{
  "verdict": "BLOCK",
  "findings": [
    {
      "severity": "P1",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 310,
      "title": "Concrete AppIntent wrappers can invoke host work without CoreAgent gate/consent/checkpoint",
      "description": "CoreAgentRunAppIntentRuntime.perform validates only runID and Task cancellation before calling the host-registered handler. CoreAgentOpenRunIntent, CoreAgentPauseRunIntent, and CoreAgentContinueRunIntent all delegate directly to this runtime. Nothing in the concrete wrapper path requires CoreAgentAppleActionGate evaluation, a consent receipt for mutating pause/continue, or checkpoint persistence before the handler can perform side effects. A host handler can therefore pause/continue/open a run from Siri/Shortcuts/Spotlight invocation before CoreAgent-owned consent and checkpoint ordering is satisfied.",
      "concrete_fix": "Move the CoreAgentAppIntentBridge into the runtime invocation path. For each kind, resolve the catalog descriptor, construct a CoreAgentAppIntentBridgeRequest with the CoreAgent mode/target, consent, and checkpointKey, call bridge.perform, and invoke the host operation only from the bridge operation closure. For mutating intents, deny if consent/checkpoint material is unavailable rather than calling the handler. Make the host handler represent only the post-gate operation, not the whole security decision."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 198,
      "title": "Bridge permits mutating work with no checkpoint",
      "description": "CoreAgentAppIntentBridge.perform checkpoints only when request.checkpointKey != nil. For mutating/destructive descriptors, a caller can omit checkpointKey and still reach operation after consent. That violates the intended gate/checkpoint/host-work ordering for pause/continue style actions because checkpointing is optional rather than policy-enforced.",
      "concrete_fix": "Require a checkpoint for descriptors whose mutability is .mutating or .destructive. For example, after the action gate allows the request, return .failed or a dedicated denial when request.descriptor.mutability != .readOnly && request.checkpointKey == nil. Alternatively make checkpointKey non-optional for mutating bridge requests and provide separate read-only/mutating request types."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 207,
      "title": "Cancellation can still allow host side effects",
      "description": "The bridge checks cancellation before gate evaluation and after checkpoint, but not unconditionally immediately before operation. If checkpointKey is nil, cancellation after gate evaluation can still proceed directly into host operation. Also, if operation throws CancellationError, the bridge reports .failed(String(describing: error)) instead of .cancelled. This weakens the guarantee that cancellation/denial prevents host side effects.",
      "concrete_fix": "Check request.isCancelled() immediately before invoking operation regardless of checkpointKey, and map CancellationError to .cancelled. Prefer `try Task.checkCancellation()` around checkpoint and operation boundaries and require operations to be cancellation-cooperative. Add tests for cancellation after gate, cancellation with nil checkpointKey, and operation throwing CancellationError."
    },
    {
      "severity": "P1",
      "file": "Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift",
      "line": 328,
      "title": "Run ID validation is too permissive for stable external identifiers",
      "description": "isValidRunID rejects empty, whitespace-padded, and oversized values, but accepts path separators, control characters, nulls, URL metacharacters, and other ambiguous Unicode. If runID is used in checkpoint keys, persistence paths, logs, Shortcuts parameters, or host routing, values such as `../x`, `run\\nspoof`, or strings with invisible characters can cause confused-deputy, log-injection, or storage-key ambiguity risks.",
      "concrete_fix": "Use a canonical stable identifier format. Prefer UUID/ULID validation, or enforce a strict ASCII allowlist such as `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` while explicitly rejecting `/`, `\\`, `:`, control characters, null bytes, leading dots, and reserved names. Normalize before validation only if the normalized value is the value actually passed to the host."
    }
  ],
  "testing_gaps": [
    "No test proves concrete CoreAgentOpenRunIntent/CoreAgentPauseRunIntent/CoreAgentContinueRunIntent invocation goes through CoreAgentAppIntentBridge before the host handler.",
    "No test verifies mutating/destructive bridge requests are denied or fail when checkpointKey is absent.",
    "No test covers cancellation after action-gate approval but before operation, cancellation with checkpointKey == nil, or operation throwing CancellationError.",
    "No negative tests for unsafe run IDs containing path separators, control characters, nulls, URL metacharacters, confusable Unicode, or leading dot segments.",
    "Catalog tests assert identifiers and selected OS policy fields but do not assert full parity between each concrete wrapper's public metadata and the CoreAgent descriptor/catalog fields.",
    "No app-hosted AppIntentsTesting/XCUITest or real Siri/Shortcuts/Spotlight invocation proof is present; this is acceptable as future scope but remains unverified."
  ],
  "residual_risks": [
    "The public shared runtime handler is mutable process-global state; even after gating is added, handler registration/reset should be constrained to trusted app bootstrap paths or SPI to reduce accidental replacement.",
    "Apple AppIntents availability/discovery behavior may expose intents through process surfaces not represented by CoreAgentAppleAppIntentMode unless the bridge is always in the concrete perform path.",
    "OS donation-manager bridging and end-to-end signing/team configuration remain future-scope integration risks."
  ]
}
