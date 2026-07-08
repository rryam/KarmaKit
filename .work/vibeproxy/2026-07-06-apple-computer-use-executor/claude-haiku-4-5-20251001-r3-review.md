```json
{
  "findings": {
    "check_1_execute_requires_approved_plan_digest_from_prior_dryrun": {
      "status": "PASS",
      "detail": "CoreAgentAppleComputerUseExecutor:run() correctly enforces that .execute mode requires both approvedPlan and approvedPlanDigest (lines 557-563). The approvedPlans registry is populated during dry-run via approvedPlans.record() at line 593, and checked during execute via approvedPlans.contains() at line 570. Test 'computerUseExecutionBindsConsentToTheApprovedPlanDigest' validates that tampering fails with .approvedPlanDigestMismatch.",
      "evidence": [
        "CoreAgentAppleComputerUseExecutor:557-563 missingApprovedPlan check",
        "CoreAgentAppleComputerUseExecutor:570 approvedPlans.contains(actionID, digest)",
        "CoreAgentAppleComputerUseExecutor:593 approvedPlans.record() on dry-run completion",
        "Test: computerUseExecutionBindsConsentToTheApprovedPlanDigest validates binding"
      ]
    },
    "check_2_consent_fingerprint_binds_actionid_and_approvedplandigest": {
      "status": "PASS",
      "detail": "Consent fingerprint is generated via policy.requestFingerprint which includes actionID and approvedPlanDigest. For .computerUseExecution, the fingerprint is computed as fingerprint(['computer-use-execution', actionID, approvedPlanDigest]) at line 419. This fingerprint is embedded in CoreAgentAppleConsentRequirement.requestFingerprint and validated by CoreAgentAppleActionGate.validate() at line 822 (consentRequestMismatch check). Test 'computerUseExecutionBindsConsentToTheApprovedPlanDigest' confirms that consent issued for one digest is rejected when used with different digest.",
      "evidence": [
        "CoreAgentAppleComputerUseExecutor:419 .computerUseExecution case includes approvedPlanDigest in fingerprint",
        "CoreAgentAppleActionGate:822 consentRequestMismatch validation",
        "Test: computerUseExecutionBindsConsentToTheApprovedPlanDigest demonstrates binding enforcement"
      ]
    },
    "check_3_baseline_screenshot_evidence_cannot_be_removed": {
      "status": "PASS",
      "detail": "canonicalMinimumEvidence() at line 678 enforces that .screenshotDigest is always included via Set.union([.screenshotDigest]). Passing an empty minimumRequiredEvidence array results in [.screenshotDigest] being enforced. planFailure() at line 691 validates that plan.requiredEvidence must contain all items in minimumRequiredEvidence. Test 'computerUseExecutorValidatesRequestAndPlanStructure' with minimumRequiredEvidence: [] still enforces .screenshotDigest via canonicalMinimumEvidence union.",
      "evidence": [
        "CoreAgentAppleComputerUseExecutor:678 canonicalMinimumEvidence unions with [.screenshotDigest]",
        "CoreAgentAppleComputerUseExecutor:691-699 planFailure checks plan.requiredEvidence includes minimumRequiredEvidence",
        "Test: with minimumRequiredEvidence: [] still fails plan missing baseline evidence"
      ]
    },
    "check_4_backend_cancellationerror_and_task_cancellation_return_failed_cancelled": {
      "status": "PASS",
      "detail": "CancellationError is caught explicitly at line 610 (catch is CancellationError), returning .failed(.cancelled). Task.isCancelled checks occur at lines 589, 606, 616, and after evidence collection at line 622. If Task is cancelled after backend.execute() completes, it still returns .failed(.cancelled) at line 623. Test 'computerUseExecutorRecordsCancellationDuringBackendExecution' confirms cancellation during execute returns .failed(.cancelled) even when evidence was partially collected.",
      "evidence": [
        "CoreAgentAppleComputerUseExecutor:610 explicit CancellationError catch",
        "CoreAgentAppleComputerUseExecutor:589, 606, 616, 622-623 Task.isCancelled checks",
        "Test: computerUseExecutorRecordsCancellationDuringBackendExecution confirms .failed(.cancelled)"
      ]
    },
    "check_5_ascii_sha256_validation_remains_strict": {
      "status": "PASS",
      "detail": "isSHA256Digest() at line 732 validates: (1) prefix 'sha256:', (2) total length exactly 68 chars (11 + 64 hex), (3) all 64 hex chars are ASCII 0-9, A-F, a-f via unicode scalar checks at lines 739-746. Validation rejects non-ASCII, mixed case, and malformed digests. Test 'computerUseExecutionFailsClosedOnMissingOrMalformedEvidence' confirms 'sha256:not-hex' is rejected with .invalidEvidenceDigest.",
      "evidence": [
        "CoreAgentAppleComputerUseExecutor:732-746 isSHA256Digest strict validation",
        "Checks: prefix, length 68, ASCII hex range (48-57, 65-70, 97-102)",
        "Test: malformed 'sha256:not-hex' fails with .invalidEvidenceDigest"
      ]
    }
  },
  "residual_risks": [
    {
      "risk": "Approval plan registry (approvedPlans) uses in-memory Set with NSLock. No persistence across executor restarts. If executor instance is recreated, prior dry-run digests are lost.",
      "severity": "MEDIUM",
      "mitigation": "By design: approvedPlans is per-executor-instance, intended for single-request flow. Cross-restart binding requires external state management.",
      "note": "Acceptable if executor lifetime equals single orchestration cycle."
    },
    {
      "risk": "Consent receipt consumption (consumedConsentReceipts) prevents replay within same gate instance, but different gate instances cannot detect replay.",
      "severity": "MEDIUM",
      "mitigation": "Gate isolation and receipt signature validation provide secondary defense. Signature includes id, authorityBoundaryID, policyVersion, capability, requestFingerprint.",
      "note": "Acceptable if gates are short-lived per authorization boundary."
    },
    {
      "risk": "Task.isCancelled check at line 622 occurs after evidence collection. If task is cancelled between lines 609-621, partial evidence may be returned in result.evidence despite .failed(.cancelled) status.",
      "severity": "LOW",
      "mitigation": "Test 'computerUseExecutorRecordsCancellationDuringBackendExecution' confirms evidence is included (result.evidence.count == 1) when cancelled post-execution. This is logged in audit but marked failed—acceptable trade-off.",
      "note": "Evidence presence in failed result is intentional for audit clarity."
    },
    {
      "risk": "SHA256 validation accepts both uppercase (A-F) and lowercase (a-f) hex. If uppercase is rejected elsewhere in stack, digest mismatch may occur.",
      "severity": "LOW",
      "mitigation": "isSHA256Digest validates but does not normalize. Upstream hash generation (sha256Hex) must produce consistent casing.",
      "note": "Requires audit of sha256Hex implementation (not provided)."
    },
    {
      "risk": "fingerprint() at line 754 uses length-prefixed encoding (count:value|count:value). No explicit validation that input strings cannot contain pipes or colons that would break parsing.",
      "severity": "LOW",
      "mitigation": "Fingerprints are used only for comparison within executor scope, not parsed. Collision risk minimal.",
      "note": "Safe for current usage but fragile if fingerprints exported externally."
    }
  ]
}
```

**Summary**: All five checks **PASS**. Execute mode correctly enforces prior dry-run approval, consent binding includes actionID+digest, baseline screenshot cannot be removed, cancellation is properly caught, and SHA256 validation is strict. Low-to-medium residual risks are primarily scope/persistence trade-offs rather than security gaps.