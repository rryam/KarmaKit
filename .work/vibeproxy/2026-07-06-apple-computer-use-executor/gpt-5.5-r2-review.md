{
  "findings": [
    {
      "id": "CU-REV-001",
      "severity": "medium",
      "area": "execution_consent_plan_digest_binding",
      "status": "partially_fixed",
      "finding": "Execution consent is now bound to a plan digest through .computerUseExecution(actionID:approvedPlanDigest), and execution rejects an approvedPlan whose digest does not match approvedPlanDigest. However, the executor does not verify that the approvedPlanDigest originated from an earlier dry-run result produced by backend.plan for the same action. A caller can supply any structurally valid plan plus its digest; if a consent receipt is issued for that digest, execution proceeds.",
      "evidence": "CoreAgentAppleComputerUseRequest.init defaults approvedPlanDigest to approvedPlan?.digest. run() checks approvedPlan.digest == approvedPlanDigest, then executeApprovedPlan() evaluates consent for .computerUseExecution(actionID: request.actionID, approvedPlanDigest: approvedPlanDigest). No dry-run audit, nonce, cache, or issued-plan registry is consulted.",
      "impact": "The consent is bound to the submitted plan digest, but not cryptographically or statefully bound to a previously generated dry-run plan. If the consent issuer can be induced to sign an arbitrary digest without independently verifying dry-run provenance, the dry-run approval invariant can be bypassed.",
      "recommendation": "Persist or attest dry-run plan digests with request/action context and require execute mode to reference a previously issued dry-run approval token or registry entry. Bind consent to that dry-run approval identifier as well as the digest."
    },
    {
      "id": "CU-REV-002",
      "severity": "medium",
      "area": "baseline_trusted_evidence_requirement",
      "status": "partially_fixed",
      "finding": "A baseline evidence requirement is enforced only through the configurable minimumRequiredEvidence parameter. Because the public initializer accepts an arbitrary array, including an empty array, the default screenshot baseline can be disabled by construction.",
      "evidence": "CoreAgentAppleComputerUseExecutor.init has minimumRequiredEvidence: [CoreAgentAppleComputerUseEvidenceKind] = [.screenshotDigest]. planFailure() only enforces the provided minimumRequiredEvidence. evidenceFailure() also unions plan.requiredEvidence with the provided minimumRequiredEvidence.",
      "impact": "Instances constructed with minimumRequiredEvidence: [] can approve plans and executions without the intended baseline screenshot evidence, provided the plan also omits it.",
      "recommendation": "Make the baseline evidence invariant non-optional, or validate initializer input so required baseline kinds such as .screenshotDigest cannot be removed except by an explicitly privileged/test-only configuration."
    },
    {
      "id": "CU-REV-003",
      "severity": "low",
      "area": "cancellation_after_backend_execute",
      "status": "partially_fixed",
      "finding": "Cancellation is checked after backend.execute returns normally, but cancellation that causes backend.execute to throw is reported as .backendFailed rather than .cancelled.",
      "evidence": "executeApprovedPlan() catches all errors from try await backend.execute(request, plan: plan) and immediately returns .failed(.backendFailed). The subsequent Task.isCancelled check is only reached if backend.execute returns evidence.",
      "impact": "Cancellation during backend execution may be misclassified depending on backend behavior. The included test covers a backend that suppresses cancellation and returns evidence, but not one that throws CancellationError.",
      "recommendation": "Catch CancellationError separately, or check Task.isCancelled in the catch path before returning .backendFailed."
    }
  ],
  "residual_risks": [
    {
      "area": "structural_request_plan_validation",
      "assessment": "Substantially improved. The executor validates request id/actionID bounds and whitespace, plan step count, step id/summary bounds, duplicate step ids, evidence requirement count, duplicate evidence requirements, and baseline evidence inclusion according to the configured minimumRequiredEvidence.",
      "residual_risk": "Validation is still limited to structural shape. It does not validate semantic safety of step summaries or whether a plan is an expected transformation of the requested actionID."
    },
    {
      "area": "ascii_sha256_evidence_digest_validation",
      "assessment": "Fixed for syntax. Evidence digests must have the sha256: prefix, exactly 64 hex characters, and only ASCII hex scalar values.",
      "residual_risk": "The executor validates digest syntax only. It does not authenticate that the digest was produced by a trusted capture pipeline, nor does it validate capturedAt freshness or monotonicity."
    },
    {
      "area": "consent_binding",
      "assessment": "Improved. Consent receipts include authority boundary, policy version, capability, request fingerprint, issuer, expiry, signature verification, and one-time-use consumption. The computer-use execution fingerprint includes actionID and approvedPlanDigest.",
      "residual_risk": "The binding depends on the consent issuer only signing the exact digest that the user approved. The executor itself does not verify user-visible approval provenance."
    }
  ],
  "testing_gaps": [
    {
      "area": "dry_run_digest_provenance",
      "gap": "Add a test proving execute mode rejects a valid arbitrary plan plus digest unless the digest came from a prior dry-run approval or persisted approval token."
    },
    {
      "area": "baseline_evidence_configuration",
      "gap": "Add a test constructing CoreAgentAppleComputerUseExecutor with minimumRequiredEvidence: [] and verify whether this is intentionally allowed. If baseline evidence is mandatory, the test should expect initializer rejection or execution failure."
    },
    {
      "area": "backend_execute_cancellation",
      "gap": "Add a test where backend.execute throws CancellationError after the task is cancelled. Expected result should be .failed(.cancelled), not .failed(.backendFailed)."
    },
    {
      "area": "evidence_digest_validation",
      "gap": "Add edge-case tests for wrong digest length, missing sha256: prefix, non-ASCII lookalike characters, uppercase ASCII hex, lowercase ASCII hex, and mixed-case ASCII hex."
    },
    {
      "area": "plan_validation",
      "gap": "Expand structural validation tests to cover empty step list, more than 32 steps, whitespace-padded step ids/summaries, oversized ids/summaries, more than 8 evidence requirements, duplicate evidence requirements, and missing configured baseline evidence."
    },
    {
      "area": "request_validation",
      "gap": "Add execute-mode tests for invalid request id/actionID before consent evaluation and before backend execution, including oversized values and whitespace-padded values."
    }
  ]
}