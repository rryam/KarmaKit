```json
{
  "findings": [
    {
      "id": "F1",
      "category": "EXECUTION CONSENT BINDING",
      "severity": "FIXED",
      "description": "Execution consent now bound to approved dry-run plan digest",
      "details": "CoreAgentAppleExecutionRequest.computerUseExecution includes approvedPlanDigest parameter. CoreAgentAppleComputerUseExecutor.executeApprovedPlan validates approvedPlan.digest == approvedPlanDigest before gate evaluation. Gate evaluates .computerUseExecution(actionID, approvedPlanDigest) which produces requestFingerprint including both parameters via fingerprint([\"computer-use-execution\", actionID, approvedPlanDigest]).",
      "evidence": "executeApprovedPlan:506-517, policy(:501), fingerprint payload at :461"
    },
    {
      "id": "F2",
      "category": "BASELINE TRUSTED EVIDENCE",
      "severity": "FIXED",
      "description": "Baseline trusted evidence requirement enforced at planning and execution phases",
      "details": "minimumRequiredEvidence parameter (default [.screenshotDigest]) passed to executor. planFailure validates plan.requiredEvidence.contains(requiredKind) for each minimumRequiredEvidence item (:441-443). evidenceFailure merges plan.requiredEvidence and minimumRequiredEvidence, validates all required kinds present in evidence (:480-484).",
      "evidence": "planFailure:435-444, evidenceFailure:477-485, init:371-376"
    },
    {
      "id": "F3",
      "category": "STRUCTURAL VALIDATION",
      "severity": "FIXED",
      "description": "Request and plan structure validated at entry and plan generation",
      "details": "requestFailure validates request.id and request.actionID bounded non-empty strings (:417-424). planFailure validates step count [1,32], step.id/summary bounded strings, unique step IDs, evidence requirement count ≤8, no duplicate evidence kinds (:427-444).",
      "evidence": "requestFailure:417-424, planFailure:427-444, isBoundedNonEmpty:499-502"
    },
    {
      "id": "F4",
      "category": "ASCII SHA256 VALIDATION",
      "severity": "FIXED",
      "description": "Evidence digests validated as ASCII SHA256 format (sha256:HEXHEX...)",
      "details": "isSHA256Digest validates prefix 'sha256:', total length prefix.count+64, all 64 hex characters in ranges 0-9, A-F, a-f (:503-517). evidenceFailure applies isSHA256Digest to all evidence.digest values (:479).",
      "evidence": "isSHA256Digest:503-517, evidenceFailure:479"
    },
    {
      "id": "F5",
      "category": "CANCELLATION POST-BACKEND",
      "severity": "FIXED",
      "description": "Cancellation detected and recorded after backend.execute completes",
      "details": "executeApprovedPlan calls backend.execute, then checks Task.isCancelled (:540-544). If cancelled after backend returns, returns result with .failed(.cancelled) status but preserves evidence returned by backend.",
      "evidence": "executeApprovedPlan:540-544"
    }
  ],
  "residual_risks": [
    {
      "id": "R1",
      "severity": "HIGH",
      "category": "CONSENT REPLAY ATTACK",
      "description": "One-time consumption enforcement may have window vulnerability",
      "details": "CoreAgentAppleConsumedConsentReceipts.consume uses lock-protected Set, preventing immediate reuse. However, consumptionKey includes [receipt.id, authorityBoundaryID, policyVersion, capability, requestFingerprint]. If two execution requests with identical fingerprints are submitted concurrently, both could pass consume() check before first insert completes in extremely tight race. Additionally, consumedConsentReceipts is instance-specific—separate executor instances do not share state, enabling cross-executor replay.",
      "recommendation": "Use distributed consensus (e.g., backend-backed receipt UUID registry) or enforce serial execution ordering at orchestration layer. Current design assumes single executor instance."
    },
    {
      "id": "R2",
      "severity": "MEDIUM",
      "category": "PLAN TAMPERING DETECTION TIMING",
      "description": "Plan digest mismatch detected before consent validation in execute mode",
      "details": "executeApprovedPlan checks approvedPlan.digest == approvedPlanDigest (:509) before gate evaluation (:520). Attacker with non-matching plan can observe failure pattern (.approvedPlanDigestMismatch) vs consent failures (.missingConsent, .invalidConsentSignature), potentially leaking consent state.",
      "recommendation": "Reorder: validate plan digest match after successful consent validation to maintain constant-time failure signature or batch failures."
    },
    {
      "id": "R3",
      "severity": "MEDIUM",
      "category": "EVIDENCE DIGEST FORMAT VALIDATION INCOMPLETE",
      "description": "isSHA256Digest accepts uppercase A-F but plan digest uses lowercase sha256Hex output",
      "details": "isSHA256Digest (:503-517) accepts both uppercase (65-70) and lowercase (97-102) hex. sha256Hex function (not shown) implementation unclear—if it produces lowercase, test data uses Self.screenshotDigest but actual evidence from real system might differ. No canonicalization enforced.",
      "recommendation": "Define canonical form (lowercase recommended per RFC 4648) and enforce case-insensitive comparison or normalize on input."
    },
    {
      "id": "R4",
      "severity": "MEDIUM",
      "category": "REQUEST FINGERPRINT LENGTH UNBOUNDED",
      "description": "fingerprint() function concatenates arbitrary-length strings without length validation",
      "details": "fingerprint (:495-497) builds 'len:field|len:field|...' encoding but no total length cap. Extremely large actionID or plan digests could produce massive requestFingerprint used in consent signature, potentially exceeding signature payload validation bounds.",
      "recommendation": "Add max total length check on fingerprint output or individual field lengths beyond current 256-byte actionID cap."
    },
    {
      "id": "R5",
      "severity": "LOW",
      "category": "CLOCK DEPENDENCY PRECISION",
      "description": "Receipt timestamp validation uses Date equality comparisons without timezone/precision handling",
      "details": "validate() checks receipt.grantedAt > currentTime and expiresAt <= currentTime (:472-475). Date comparison in Swift is nanosecond-precise. Receipts issued and validated within same nanosecond could fail due to monotonicity edge case.",
      "recommendation": "Use >= currentTime for grantedAt check or add small grace period (e.g., 1 second) for clock skew tolerance."
    }
  ],
  "testing_gaps": [
    {
      "id": "T1",
      "category": "CONCURRENT EXECUTION",
      "description": "No test for concurrent execute requests with same consent receipt",
      "impact": "Race condition in CoreAgentAppleConsumedConsentReceipts not exercised; replay attack mitigations untested under contention"
    },
    {
      "id": "T2",
      "category": "CROSS-INSTANCE SHARING",
      "description": "No test for receipt reuse across separate CoreAgentAppleComputerUseExecutor instances",
      "impact": "Absence of distributed consent state validation not detected; allows replay across independent executors"
    },
    {
      "id": "T3",
      "category": "EDGE CASE DIGESTS",
      "description": "No test for uppercase vs lowercase SHA256 hex in evidence digests",
      "impact": "Case sensitivity mismatch between plan digest generation and evidence validation not caught"
    },
    {
      "id": "T4",
      "category": "CANCELLATION TIMING",
      "description": "Test cancels during execute but only validates final state; no test for cancellation during planning phase",
      "impact": "Cancellation between gate evaluation and backend.plan not verified to set .failed(.cancelled) status"
    },
    {
      "id": "T5",
      "category": "MALFORMED CONSENT SIGNATURE",
      "description": "No test for truncated, non-hex, or oversized HMAC values in signature field",
      "impact": "authenticationCode parsing robustness (hex validation, length check) not stress-tested"
    },
    {
      "id": "T6",
      "category": "REQUEST FINGERPRINT EXTREMES",
      "description": "No test for extremely large actionID or evidence kind combinations exceeding typical bounds",
      "impact": "Fingerprint concatenation DoS potential not explored"
    },
    {
      "id": "T7",
      "category": "CONSENT EXPIRY BOUNDARY",
      "description": "Tests use expiresAt with sufficient margin; no test for expiry at exact currentTime boundary",
      "impact": "Edge case of expiresAt == now (which should deny via <=) not validated"
    },
    {
      "id": "T8",
      "category": "EVIDENCE ORDERING",
      "description": "No test verifying evidence order preservation or handling duplicate evidence kinds",
      "impact": "Evidence array mutation or reordering side effects not detected"
    }
  ]
}
```

**Summary:** All five prior findings are fixed. Residual risks center on distributed replay prevention (R1), timing-based information leakage (R2), and digest format canonicalization (R3). Testing gaps expose concurrency, cross-instance sharing, and boundary condition blindspots.