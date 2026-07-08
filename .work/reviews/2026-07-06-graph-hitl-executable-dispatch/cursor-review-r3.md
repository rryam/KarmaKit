## Verdict: **GO**

The L32 re-review fixes are correct and complete. The prior P1 digest divergence is resolved, `source` is surfaced on the executed result, and the test suite now covers the previously missing fail-closed and identity-sensitivity contracts. I found **no remaining P0/P1 blockers** in scope.

---

## CRITICAL (P0)

None.

---

## IMPORTANT (P1)

None.

The first-review P1 is fixed end-to-end:

1. **Digest alignment** — The executor computes both digests from parsed `GeneratedContent` via `CoreAgentArgumentAudit.digest`, and feeds the canonical executable digest into `invocationID(...)`:

```124:132:Sources/CoreAgentDeep/CoreAgentDeepHITLExecution.swift
    let requestedArgumentsDigest = CoreAgentArgumentAudit.digest(requestedArguments)
    let executableArgumentsDigest = CoreAgentArgumentAudit.digest(arguments)
    let request = CoreAgentToolRequest(
      runID: runID,
      invocationID: Self.invocationID(
        runID: runID,
        action: action,
        manifest: manifest,
        executableArgumentsDigest: executableArgumentsDigest
```

2. **Canonicalization contract** — `CoreAgentArgumentAudit.digest` round-trips through `JSONSerialization` with sorted keys before hashing:

```66:80:Sources/CoreAgent/CoreAgentArgumentAudit.swift
  private static func canonicalJSONString(_ content: GeneratedContent) -> String {
    let source = content.jsonString
    guard let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      ),
      let encoded = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .fragmentsAllowed]
      )
    else {
      return source
    }
    return String(decoding: encoded, as: UTF8.self)
  }
```

This matches native governed-tool/session audit usage in `CoreAgentPolicy.swift` and `CoreAgentSession.swift`.

3. **Source passthrough** — `CoreAgentDeepHITLExecutedAction.source` is populated and tested for both `.edit` and `.approve`.

4. **Execution order** — manifest lookup → JSON parse (fail-closed) → digest → request build → `policy.authorize` → `withCurrent` → backend. Malformed requested/executable args are rejected before policy/backend, with tests asserting empty recorder state.

---

## MINOR (P2)

These are residual risks or small contract gaps, not ship blockers for this slice.

### 1. Two different digest domains still exist (host integration)

| Digest | Purpose | Input |
|--------|---------|-------|
| `reviewedActionIdentity.actionDigest` | Resume binding for graph interrupt | Structured payload with **raw** `argsJSON` |
| `requestedArgumentsDigest` / `executableArgumentsDigest` | Audit correlation with CoreAgent tool events | **Canonical** `CoreAgentArgumentAudit` |

Hosts must not treat `actionDigest` as interchangeable with `requestedArgumentsDigest`. The executor exposes the right fields; conflation would be a host wiring mistake.

### 2. HITL executor path lacks explicit key-order/whitespace parity test

`CoreAgentTests.argumentAuditDigestCanonicalizesJSONObjects` covers the helper, and `executableDispatchReturnsRedactedArgumentEvidence` proves parity with `CoreAgentArgumentAudit.digest(result.request.arguments)`. There is no executor test that feeds semantically equivalent but differently formatted `argsJSON` strings through the full dispatch path. Low risk given shared helper usage.

### 3. No native→graph digest bridge test

No test proves `digest(model GeneratedContent)` == `digest(GeneratedContent(json: stored argsJSON))` across the graph checkpoint round-trip. Reasonable follow-up, not a current correctness hole.

### 4. Trusted-backend secret exposure (pre-existing)

The backend still receives the full `CoreAgentDeepHITLExecutableAction`, including raw `requestedArgsJSON`. Redacted fields on `ExecutedAction` are for audit emission; a logging backend could leak secrets. Mitigation is trusted host code.

### 5. `TaskLocal` propagation (pre-existing)

`CoreAgentToolInvocation.withCurrent` has the same child-task propagation limitation as governed tools. Not introduced by this fix.

### 6. `source` is enum, not receipt literal

Native receipts use strings like `intervention_edit` / `model_request`. `ExecutedAction` exposes `CoreAgentDeepHITLExecutionSource` (`.approve` / `.edit`); hosts must map to receipt literals. Docs correctly place receipt emission on the host.

---

## What the fixes verified

| First-review item | Status | Evidence |
|-------------------|--------|----------|
| Raw JSON digest mismatch | Fixed | Shared `CoreAgentArgumentAudit.digest`; invocation ID uses canonical executable digest |
| Missing `source` on result | Fixed | Field + approve/edit tests |
| `invalidRequestedArguments` untested | Fixed | `malformedRequestedArgumentsFailBeforePolicyAndBackendExecution` |
| Identity sensitivity gaps | Fixed | Run ID, tool-call ID, manifest digest tests |
| Digest parity test | Fixed | `executableDispatchReturnsRedactedArgumentEvidence` |
| Authorization evidence passthrough | Fixed | `retargetedActionsDispatchThroughExecutableTargetManifest` |
| Approve path smoke test | Fixed | `approvedActionsPreserveSourceWithoutEditedTargetAuthorization` |

---

## Security / concurrency

- **Security:** Executable-target authorization is enforced (`retargetedActionsAuthorizeExecutableTargetNotReviewedTool`); duplicate/missing manifests fail closed; sensitive keys are redacted in emitted evidence.
- **Concurrency:** `CoreAgentDeepHITLExecutableActionExecutor` is immutable/`Sendable`; no shared mutable executor state; policy/backend are `Sendable`. Test backends use actors appropriately.

---

## Documentation

`CoreAgentDeep-Runtime.md` and `DeepAgents-Port-Task-Ledger.md` accurately describe canonical digests, `source`, invocation-ID inputs, fail-closed behavior, and the explicit non-substitute status for `CoreAgentSession` receipts. No doc/code drift found in scope.

---

## FIXES REQUIRED

None for merge.

---

## RESIDUAL RISK

- Host receipt wiring remains host-owned (by design).
- `actionDigest` vs argument-audit digests serve different contracts.
- Backend trust boundary for raw requested JSON.
- `TaskLocal` inheritance limits for nested backend work.

---

**Bottom line:** Ship. The re-review fixes close the only material contract bug from L32 r1. Remaining items are P2 host-integration and test-hardening notes, not correctness/security blockers introduced by this patch.
