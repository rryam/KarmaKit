## Verdict

**One P1 remains in this slice.** The other areas you called out (stale resume replay, malformed resume acceptance, native args-only retarget leakage) look closed on the resolver/native-policy paths. **No P0** in those paths.

The claimed P1 fix is **not present in current source**: `CoreAgentDeepHITLExecutableAction## Verdict

**One P1 remains in this slice.** The prior P1 fix is **not present in source**: `CoreAgentDeepHITLExecutableAction` still has a **public** initializer with release-stripped `precondition`s. Everything else you called out — stale replay, malformed resume, native args-only leakage — looks closed inside the resolver/native-guard paths.

**No P0 blockers** on the graph batch resolver contract itself.

---

## P1 (remaining)

### Public `CoreAgentDeepHITLExecutableAction` init still bypasses retarget invariants

```146:174:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  public init(
    name: String,
    argsJSON: String,
    description: String,
    toolCallID: String,
    source: CoreAgentDeepHITLExecutionSource,
    requestedName: String? = nil,
    requestedArgsJSON: String? = nil,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity? = nil,
    editedTargetAuthorization: CoreAgentDeepHITLEditedTargetAuthorization? = nil
  ) {
    // ...
    precondition(
      effectiveRequestedName == name || editedTargetAuthorization != nil,
      "Retargeted executable actions require edited-target authorization."
    )
```

**Problem:** This is still `public init`, not `fileprivate`. Only `CoreAgentDeepHITLBatchDecision` got a `fileprivate` initializer (line 43). In release builds, `precondition` is stripped, so any downstream executor/test/helper can construct a retargeted `.execute` action without going through `CoreAgentDeepHITLBatchResolver`.

Worse, `CoreAgentDeepHITLEditedTargetAuthorization` is also publicly constructible with no policy binding:

```122:132:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  public init(
    reviewedActionName: String,
    editedActionName: String,
    allowedEditedActionNames: Set<String>,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity
  )
```

A caller can forge self-consistent authorization (including a fake `allowedEditedActionNames`) and satisfy the preconditions in debug, or skip them entirely in release. That reopens **invalid retarget execution** outside the resolver path — the exact hole the last P1 was meant to close.

**Fix:** Make `CoreAgentDeepHITLExecutableAction.init` `fileprivate` (same file as the resolver), and ideally make `CoreAgentDeepHITLEditedTargetAuthorization.init` resolver-only too.

---

## Closed (no remaining P0/P1 in these areas)

| Concern | Status | Evidence |
|---|---|---|
| **Stale resume replay** | Closed | Digest v1 binds `actionName`, `argsJSON`, `description`, `toolCallID`, `allowedDecisions`, `allowedEditedActionNames`, and config description. Tests: `actionDigestMismatchCatchesReviewedArgumentTampering`, `editedTargetPolicyParticipatesInActionIdentity`. |
| **Malformed resume acceptance** | Closed | Fail-closed on decode (`invalidBatchResumeValue`), count mismatch, identity mismatch, digest mismatch, duplicate decisions, disallowed decisions, missing edit payload, non-edit carrying `edited_action` (JSON decode test). Wrong interrupt ID re-interrupts instead of executing (tested, intentional). |
| **Invalid retarget via resume** | Closed on resolver path | `editedToolNameNotAllowed` when target ∉ `allowed_edited_action_names`; authorization attached only after allowlist check (`resolution(for:decision:)` lines 543–572). |
| **Native args-only retarget leakage** | Closed | `CoreAgentDeepHITLPolicy` rejects non-empty `allowedEditedActionNames` before reviewer (`CoreAgentDeepHITL.swift` 409–414). Native batch adapter rejects at rule scan (313–318) and again at args-only boundary if `name != requestedName` (374–379). Tests in both `CoreAgentDeepHITLTests` and `CoreAgentDeepHITLBatchTests`. |
| **Same-tool edit identity split** | Closed | `requestedName` / `executableName` / `editedTargetAuthorization == nil` tested in `sameToolEditsKeepReviewedIdentityWithoutRetargetAuthorization`. |

---

## Intentional boundary (not an in-slice P0/P1)

The slice stops at **resolution evidence**, not executable dispatch. `graphResumeReturnsAllowedRetargetExecutableEvidence` proves fields only; no in-repo graph executor yet enforces `executableName` + `CoreAgentToolPolicy` on retargets. That matches `CoreAgentDeep-Runtime.md` (lines 161–164, 208–223). It is a downstream wiring obligation, not a resolver bug — but it means **shipping a retarget executor without reading `executableName`/`editedTargetAuthorization` would be a product-level P1 outside this file set**.

---

## Bottom line

Apply the `fileprivate` initializer change on `CoreAgentDeepHITLExecutableAction` (and lock down `CoreAgentDeepHITLEditedTargetAuthorization` construction) and this slice has **no remaining P0/P1 blockers** for the four concerns you listed. As checked in right now, that one P1 is still open because the init remains public.
