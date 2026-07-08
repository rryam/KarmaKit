```json
{
  "findings": [
    {
      "severity": "high",
      "file": "CoreAgentApplePlatform.swift",
      "line": 247,
      "title": "Consent receipt replay vulnerability: no rate limiting or temporal ordering",
      "description": "CoreAgentAppleConsumedConsentReceipts tracks consumed receipts by a single fingerprint key but does not validate temporal ordering. An attacker could construct multiple valid receipts with the same actionID at different times and replay the oldest one if the consumption tracking is cleared or in a different process instance. The consumption key does not include a nonce or timestamp.",
      "concrete_fix": "Add a required nonce field to CoreAgentAppleConsentReceipt and include it in consumptionKey(). Require that grantedAt is recent (within policy-defined window, e.g. 5 minutes) to prevent old receipts from being replayed even if consumption tracking is reset."
    },
    {
      "severity": "high",
      "file": "CoreAgentApplePlatform.swift",
      "line": 362,
      "title": "HMAC signature verification uses custom hex parsing with no constant-time comparison",
      "description": "authenticationCode() parses hex manually and the HMAC.isValidAuthenticationCode call may not be constant-time safe. The hex parsing at line 128-143 is vulnerable to timing attacks if an attacker can measure verification speed. Additionally, the signature format 'hmac-sha256:' prefix is not cryptographically bound to the payload.",
      "concrete_fix": "Replace manual hex parsing with Data(hexEncoded:) if available, or use a constant-time comparison library. Include a version/algorithm field in the signature payload itself. Consider using HMAC-SHA256 in a standard format (e.g., RFC 4648) or a sealed box (EncryptedBox) instead of raw HMAC."
    },
    {
      "severity": "high",
      "file": "CoreAgentApplePlatform.swift",
      "line": 358,
      "title": "Consent receipt signature does not include issuerID in payload, allowing issuer spoofing",
      "description": "The signaturePayload at line 148-157 does not include the issuerID, only authorityBoundaryID. An attacker who compromises one issuer's signing key could issue receipts that pass verification as if from a different trusted issuer, since issuerID is validated after signature verification (line 358) but not covered by the signature.",
      "concrete_fix": "Add issuerID to the signaturePayload fields before the first field. Update test cases to regenerate receipts with the new payload format."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 163,
      "title": "timeToken() implementation not visible; stableTimeToken() may allow precision attacks",
      "description": "The call to stableTimeToken() at line 163 is not defined in the provided code. If it uses Date.timeIntervalSince1970 with second-level precision, two receipts granted in the same second could produce identical signatures even with different grantedAt values, reducing entropy.",
      "concrete_fix": "Ensure stableTimeToken() includes millisecond or microsecond precision: e.g., String(format: '%.3f', date.timeIntervalSince1970). Add a test that verifies two receipts with 1ms difference produce different signatures."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 340,
      "title": "Consent expiry check allows receipts valid until exactly expiresAt; should use strict less-than",
      "description": "Line 340: `if expiresAt <= currentTime` rejects expired receipts. However, if expiresAt == currentTime due to clock skew or rounding, a receipt is rejected. This is correct, but the inverse (accepting expiresAt > currentTime) creates a 1-second window of ambiguity. A receipt expiring at T can be used at T-1ms but not at T.",
      "concrete_fix": "Add a clock skew tolerance parameter (e.g., ±5 seconds) to CoreAgentAppleActionGate.init(). Update the check to: `if expiresAt.addingTimeInterval(-clockSkewTolerance) <= currentTime`."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 308,
      "title": "Policy fingerprint construction is order-dependent but fields are not versioned",
      "description": "The fingerprint() method at line 368 concatenates fields without a schema version. If policy changes add a new field, old fingerprints become invalid and receipts issued under old policies cannot be validated against new policies. This breaks forward compatibility.",
      "concrete_fix": "Prefix the fingerprint with a version: e.g., `'v1|' + fields.map(...).joined(...)`. Increment version if policy fields change. Validate that receipt.requestFingerprint matches the current version during validate()."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 325,
      "title": "Consent receipt issuerID validation happens after signature verification; should validate first",
      "description": "At line 358, issuerID is compared against trustedConsentIssuerID after signature verification. If the signing key is issuer-specific, this order doesn't matter. But if one key signs for multiple issuers, validating issuerID before signature verification prevents a malicious issuer from using another issuer's key.",
      "concrete_fix": "Move the issuerID check (line 358) to immediately after extracting the receipt, before signature verification. Add a comment explaining the security rationale."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 228,
      "title": "CoreAgentAppleConsentSigningKey initializer silently fails on short keys without error logging",
      "description": "The failable initializer at line 195 returns nil if material.count < 32, but provides no feedback on why. If a developer initializes with a 16-byte key, they'll get nil and may not understand that key length is the issue. This could lead to silent failures in production.",
      "concrete_fix": "Add an assertion or throw a typed error: `public init(_ material: Data) throws { guard material.count >= 32 else { throw CoreAgentAppleConsentError.keyTooShort(required: 32, got: material.count) } ... }`."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 378,
      "title": "Computer use evidence digest validation only checks SHA256 format, not actual cryptographic integrity",
      "description": "The isSHA256Digest() at line 477 validates the format (prefix + 64 hex chars) but does not verify that the digest actually matches the evidence content. A backend could return a well-formed but incorrect digest, and the executor would accept it. No re-computation of evidence digest occurs.",
      "concrete_fix": "Add a computed digest property to CoreAgentAppleComputerUseEvidence or pass the raw evidence blob to executor. Compute sha256Hex(evidence) and verify it matches the provided digest before accepting."
    },
    {
      "severity": "medium",
      "file": "CoreAgentApplePlatform.swift",
      "line": 467,
      "title": "Plan digest computed after execution but not validated against request or pre-execution expectations",
      "description": "At line 447, planDigest is computed after plan is received but there's no mechanism to validate that the plan matches the actionID or request context. A malicious backend could return a valid plan for a different action, and it would be recorded in the audit log with the wrong action ID.",
      "concrete_fix": "Compute and store a requirement digest before calling backend.plan(). After receiving the plan, verify that the plan's actionID (if present in the plan schema) matches the request.actionID. Add a test case for plan tampering."
    },
    {
      "severity": "low",
      "file": "CoreAgentApplePlatform.swift",
      "line": 445,
      "title": "Empty receipt ID check uses whitespace trimming which may be overly permissive",
      "description": "At line 315, the check `receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` allows receipt IDs that contain only internal whitespace (e.g., ' a b '). This could lead to collisions if two receipts differ only in whitespace.",
      "concrete_fix": "Change to: `guard !receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && receipt.id == receipt.id.trimmingCharacters(in: .whitespacesAndNewlines) else { ... }`. Validate that receipt ID contains no leading/trailing whitespace."
    },
    {
      "severity": "low",
      "file": "CoreAgentApplePlatformTests.swift",
      "line": 90,
      "title": "Test uses hardcoded timestamp but does not test time boundary conditions",
      "description": "Tests use `Date(timeIntervalSince1970: 1_800_000_200)` but do not test receipt expiry at boundaries (grantedAt == now, expiresAt == now, or microsecond precision). Missing edge case coverage for clock skew scenarios.",
      "concrete_fix": "Add test cases: (1) receipt.grantedAt == now (should be valid), (2) receipt.expiresAt == now (should be rejected), (3) receipt.expiresAt == now + 1ns (should be valid), (4) verify that a receipt issued 1s in the future is rejected."
    },
    {
      "severity": "low",
      "file": "CoreAgentApplePlatformTests.swift",
      "line": 145,
      "title": "Test does not verify that dryRun mode bypasses consent even for capabilities that normally require it",
      "description": "The test passes .notRequired consent in dryRun mode, but does not explicitly verify that dryRun accepts .notRequired *and* would also accept a denied receipt without failing. Current code at line 265 passes .notRequired for dryRun, which is correct, but no test confirms that dryRun mode gatekeeping is independent of receipt validation.",
      "concrete_fix": "Add test: `func testDryRunBypassesConsentValidation()` that calls executor.run() with .dryRun mode and .granted(invalidReceipt) to confirm that mode gate check at line 265 overrides consent validation."
    }
  ],
  "residual_risks": [
    {
      "category": "Cryptography",
      "description": "HMAC-SHA256 is used for receipt signing, but the signature scheme is custom (length-prefixed plaintext fields). If a field is omitted or reordered, the signature is invalid, but there is no algorithm versioning. If HMAC is ever replaced with a different algorithm, old receipts become unverifiable.",
      "mitigation": "Use a standard serialization format (e.g., CBOR or protobuf) with explicit schema versioning before signing. Consider using Crypto.Signature.HMAC<SHA256> signing keys with a dedicated key ID."
    },
    {
      "category": "Consent Lifecycle",
      "description": "Receipts are consumed (marked as 'used') in memory only (CoreAgentAppleConsumedConsentReceipts). If the executor restarts, consumed receipts are forgotten, allowing re-use. Distributing executors across processes will not share consumption state.",
      "mitigation": "Persist consumed receipt IDs to disk or a shared store. Use a distributed lock or append-only log for tracking consumption. Implement a TTL on in-memory consumed receipts to garbage-collect old entries."
    },
    {
      "category": "Evidence Integrity",
      "description": "Computer use evidence (screenshots, accessibility trees) is digested by the backend, but the executor only validates digest format, not correctness. A compromised backend or man-in-the-middle could return evidence with a valid digest that does not reflect actual system state.",
      "mitigation": "Require evidence to be captured by the executor itself or a cryptographically attested subsystem. Compute evidence digests in the executor and compare them to backend-provided values. Consider adding a timestamp to evidence and validating it matches the execution timeframe."
    },
    {
      "category": "Action ID Binding",
      "description": "The actionID in the request is user-provided and used in the fingerprint, but there is no schema or validation of actionID format. An attacker could submit actionID = 'click-toolbar-save' for one request and 'click-toolbar-save' for a different request, and both would appear valid if consent is reused.",
      "mitigation": "Add actionID to the consent requirement validation. Require that the actionID in the request exactly matches the actionID in the receipt fingerprint. Consider adding a signature or HMAC over the actionID."
    },
    {
      "category": "Sandbox Bypass",
      "description": "The sandbox profile (capabilities, workspaceRoot, networkPolicy) is checked at the gate, but the executor does not re-validate it during execution. A mutable CoreAgentAppleSandboxProfile could be modified between gate evaluation and execution, bypassing policy.",
      "mitigation": "Make CoreAgentAppleSandboxProfile immutable or store a hash of it. Re-validate the sandbox profile in the executor before executing. Ensure that the audit record includes a hash of the sandbox state at the time of execution."
    },
    {
      "category": "Timing Attacks",
      "description": "Clock skew between the issuer (who signs receipts) and the executor (who validates them) is not accounted for. If issuers and executors have clocks that differ by more than ~1 second, valid receipts may be rejected as not-yet-valid or expired.",
      "mitigation": "Add a clock skew tolerance parameter to CoreAgentAppleActionGate (e.g., ±10 seconds). Document the expected NTP synchronization requirement for production deployments."
    }
  ],
  "testing_gaps": [
    {
      "area": "Consent Receipt Replay",
      "gap": "No test confirms that a receipt can only be used once. Test should submit the same receipt twice and verify the second attempt is rejected with .reusedConsentReceipt.",
      "test_case": "func testConsentReceiptCannotBeReusedForMultipleExecutions() async { let receipt = ...; let result1 = await executor.run(request1, consent: .granted(receipt)); let result2 = await executor.run(request1, consent: .granted(receipt)); #expect(result2.status == .denied(.reusedConsentReceipt(_))) }"
    },
    {
      "area": "Consent Issuer Validation",
      "gap": "No test validates that a receipt from an untrusted issuer is rejected. Test should issue a receipt with issuerID != trustedConsentIssuerID and confirm .untrustedConsentIssuer denial.",
      "test_case": "func testConsentFromUntrustedIssuerIsRejected() async { let receipt = CoreAgentAppleConsentReceipt.issue(..., issuerID: 'evil-issuer', ...); let result = await executor.run(request, consent: .granted(receipt)); #expect(result.status == .denied(.untrustedConsentIssuer(...))) }"
    },
    {
      "area": "Consent Expiry Boundaries",
      "gap": "No test validates the exact boundaries of grantedAt and expiresAt. Tests should verify: (1) grantedAt in future is rejected, (2) expiresAt == now is rejected, (3) expiresAt > now is accepted.",
      "test_case": "func testConsentExpiryBoundaryConditions() async { let now = Date(); let futureGrant = CoreAgentAppleConsentReceipt(..., grantedAt: now.addingTimeInterval(1), ...); let result = await executor.run(request, consent: .granted(futureGrant)); #expect(result.status == .denied(.notYetValidConsentReceipt(_))) }"
    },
    {
      "area": "Evidence Validation",
      "gap": "No test confirms that evidence digest validation fails for valid format but incorrect content. Test should return an evidence item with a valid SHA256 format but wrong hash.",
      "test_case": "func testEvidenceDigestMustMatch() async { let wrongDigest = 'sha256:' + '0' * 64; let result = await executor.run(request, consent: .granted(receipt)); #expect(result.status == .failed(.invalidEvidenceDigest(.screenshotDigest))) }"
    },
    {
      "area": "Plan Integrity",
      "gap": "No test validates that the plan returned by the backend is not tampered with or substituted. Test should return a plan for action X but request action Y, and verify it is detected or the audit records the mismatch.",
      "test_case": "func testPlanMustMatchRequestActionID() async { /* backend returns plan for 'close-window' when actionID is 'click-button' */ let result = ...; #expect(result.audit.actionID == 'click-button') #expect(plan validation failure or warning) }"
    },
    {
      "area": "Signature Verification",
      "gap": "No test confirms that a receipt with an invalid signature (corrupted HMAC) is rejected. Test should modify the signature string and verify verification fails.",
      "test_case": "func testInvalidConsentSignatureIsRejected() async { var receipt = ...; var signature = receipt.signature; signature.removeLast(); receipt = CoreAgentAppleConsentReceipt(..., signature: signature, ...); let result = await executor.run(request, consent: .granted(receipt)); #expect(result.status == .denied(.invalidConsentSignature(_))) }"
    },
    {
      "area": "Capability Mismatch",
      "gap": "No test validates that a receipt for capability X is rejected when capability Y is required. Test should issue a receipt for .appIntentDonation but try to execute .computerUse.",
      "test_case": "func testConsentCapabilityMismatchIsRejected() async { let receipt = ...; requirement = .capability(.appIntentDonation); /* but request requires .computerUse */ let result = await executor.run(request, consent: .granted(receipt)); #expect(result.status == .denied(.consentCapabilityMismatch(...))) }"
    },
    {
      "area": "Network Policy Enforcement",
      "gap": "No test confirms that remote code interpreter requires network policy to be .allowed. Test should try to execute .codeInterpreter(tier: .remote) with networkPolicy: .denied.",
      "test_case": "func testRemoteCodeInterpreterRequiresNetworkPolicy() async { let gate = CoreAgentAppleActionGate(sandbox: CoreAgentAppleSandboxProfile(..., networkPolicy: .denied, ...)); let requirement = gate.consentRequirement(for: .codeInterpreter(tier: .remote)); let decision = gate.evaluate(.codeInterpreter(tier: .remote), consent: .notRequired); #expect(decision == .denied(.remoteExecutionRequiresNetworkPolicy)) }"
    },
    {
      "area": "Cancellation During Execution",
      "gap": "Test exists but only tests cancellation before planning. Should also test cancellation after planning but before execution to confirm no evidence is recorded.",
      "test_case": "func testCancellationDuringExecutionPhase() async { let task = Task { await executor.run(request, consent: .granted(receipt)) }; await Task.sleep(nanoseconds: 100_000); task.cancel(); let result = await task.value; #expect(result.status == .failed(.cancelled)); #expect(result.evidence.isEmpty) }"
    },
    {
      "area": "Missing Consent Expiry",
      "gap": "No test confirms that a receipt with expiresAt: nil is rejected. Test should create a receipt without an expiry and verify .missingConsentExpiry denial.",
      "test_case": "func testMissingConsentExpiryIsRejected() async { let receipt = CoreAgentAppleConsentReceipt(..., expiresAt: nil, ...); let result = await executor.run(request, consent: .granted(receipt)); #expect(result.status == .denied(.missingConsentExpiry(_))) }"
    }
  ]
}
```

---

## Summary

The implementation demonstrates **solid foundational design** for consent-gated computer use execution with dry-run planning. However, there are **3 high-severity issues**:

1. **Replay vulnerability**: Consumed receipts lack temporal ordering and nonce protection.
2. **Signature verification**: Custom HMAC scheme with no constant-time comparison and issuerID not bound to signature.
3. **Evidence integrity**: No validation that digests actually match evidence content.

**Medium risks** include clock skew, policy versioning, and distributed consumption tracking. The test suite covers happy paths well but **misses 10 critical edge cases** (replay, untrusted issuer, expiry boundaries, signature tampering, capability mismatch, network policy enforcement).

**Recommend**: Add nonce + timestamp to receipts, move issuerID into signed payload, compute and validate evidence digests, and expand test coverage for denial paths.