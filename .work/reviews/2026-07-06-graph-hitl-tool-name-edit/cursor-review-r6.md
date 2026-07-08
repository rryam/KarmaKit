**Verdict: No remaining P0/P1 blockers in this slice.**

The prior P1 is fixed in current source. Both construction gates are `fileprivate` in `CoreAgentDeepHITLBatch.swift`:

```122:146:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  fileprivate init(
    reviewedActionName: String,
    editedActionName: String,
    allowedEditedActionNames: Set<String>,
    reviewedActionIdentity: CoreAgentDeepHITLActionIdentity
  ) {
    // ...
  }
}

public struct CoreAgentDeepHITLExecutableAction: Equatable, Sendable {
  // ...
  fileprivate init(
```

Only `CoreAgentDeepHITLBatchResolver.resolution(for:decision:)` constructs executable actions (lines 528 and 562). External forgery of retargeted executables is no longer possible.

---

### Concern-by-concern

| Concern | Status | Evidence |
|---|---|---|
| **Invalid retarget execution** | Closed | Resolver enforces `allowedEditedActionNames.contains(editedAction.name)` before building authorization (547–559). Same-tool edits skip authorization when names match (544–545). `fileprivate` init blocks bypass. |
| **Stale resume replay** | Closed | Digest v1 binds `actionName`, `argsJSON`, `description`, `toolCallID`, `allowedDecisions`, `allowedEditedActionNames`, and config description (605–614). Positional `toolCallID` + `actionDigest` checks (485–494). Tests: `actionDigestMismatchCatchesReviewedArgumentTampering`, `editedTargetPolicyParticipatesInActionIdentity`. |
| **Malformed resume acceptance** | Closed | Decode failure → `invalidBatchResumeValue` (649–652, tested). Count mismatch, duplicate decisions, wrong identity at index, disallowed decision type, non-edit carrying `edited_action`, empty respond message all throw before resolution. Wrong interrupt ID re-interrupts instead of executing (654–655) — fail-closed, tested in `resumeInterruptIDMustMatchPendingReview`. |
| **Native args-only retarget leakage** | Closed | Per-call policy rejects non-empty `allowedEditedActionNames` before reviewer (409–414). Native batch adapter rejects at rule scan (313–318) and again at args-only boundary if `name != requestedName` (374–379). Tests in both HITL test files. |

---

### Prior P1 — resolved

The old concern was a **public** `CoreAgentDeepHITLExecutableAction` init with release-stripped `precondition`s. That path is gone. `CoreAgentDeepHITLEditedTargetAuthorization` is also resolver-only. The remaining `precondition`s are debug-only defense-in-depth inside the file, not the security boundary.

---

### Out of slice (not P0/P1 here)

1. **Downstream executor dispatch** — The resolver returns evidence (`executableName`, `editedTargetAuthorization`); it does not run tools. Docs correctly place manifest lookup and `CoreAgentToolPolicy` on the executor (lines 161–164, 208–223 in `CoreAgentDeep-Runtime.md`). A future executor that ignores `executableName` would be a product bug outside this file set.

2. **Event projection omitting `allowedEditedActionNames`** — Adjacent audit surface; not in the four resolver/native-guard concerns you listed.

---

**Bottom line:** For invalid retarget execution, stale replay, malformed resume acceptance, and native args-only leakage, this slice is clean. Ship-ready from a P0/P1 perspective on those axes.
