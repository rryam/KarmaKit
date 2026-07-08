# P0: Run-ID validation bypass via `validate()` not called in `donate()`

**Location:** CoreAgentAppIntents.swift:312–332

The `CoreAgentIntentDonationManagerRunBackend.donate()` method calls `validate()` at line 315 but **does not use its return value**. The validation only confirms the descriptor is exposure-safe, but **does not re-validate the runID against `isValidRunID()`** after the policy check.

However, the actual blocker: `validate()` is called but its result is discarded. More critically, **the runID is passed directly to intent constructors (lines 320, 324, 328) without re-validation**. If `validate()` passes but intent construction fails due to malformed runID, the error propagates to the caller without clear semantics.

**Risk:** Inconsistent validation contract. The bridge validates at line 494, but the backend also validates—creating two validation points with different error types (`CoreAgentRunAppIntentDonationBackendError` vs `CoreAgentRunAppIntentDonationRejection`). This splits the contract.

**Recommendation:** Remove the backend's `validate()` method entirely. The bridge (line 494) already checks `isValidRunID()` before creating the backend request. The backend should trust its input (it's an internal API) and fail fast with precise errors if intent construction fails.

---

# P1: Cryptographic digest mismatch on token identity

**Location:** CoreAgentAppIntents.swift:249–252, 258–260

`CoreAgentAppIntentOSDonationToken` encodes `IntentDonationIdentifier` as JSON and hashes it. But **invalidation at line 569 deletes by token, then maps the deleted results back to tokens**:

```swift
let deleted = try await backend.deleteDonation(request.osDonationToken)
let invalidationRecords: [CoreAgentAppIntentDonationInvalidationRecord]
```

The OS may return multiple deleted `IntentDonationIdentifier`s for a single deletion request. The code assumes round-tripping through `osIdentifier()` decode and re-encoding preserves identity. **If JSON encoding is non-canonical** (key order, whitespace), the digest will differ even for identical semantic identifiers.

**Risk:** Invalidation records claim digests don't match the donation receipt's digest, breaking audit trails.

**Recommendation:** Use `JSONEncoder` with `sortedKeys` option, or better: hash the decoded `IntentDonationIdentifier` directly (as a struct) using a stable serialization, not JSON round-trip.

---

# P1: Consent/capability gate order inversion in invalidation

**Location:** CoreAgentAppIntents.swift:557–598

`invalidate()` does **not** check the action gate or consent before calling `backend.deleteDonation()`. The flow is:

1. Match receipt against request (line 560)
2. Call backend to delete (line 569)
3. Return result

**But the donation was gated on consent at line 518.** Invalidation should enforce that the same caller (same consent basis) can revoke it, or the gate should gate *invalidation* requests.

Currently, **any caller with the token can invalidate**, even if they lack the consent/capability that allowed the original donation.

**Recommendation:** Add `actionGate.evaluate(appIntentDonationInvalidation(...), consent)` before backend deletion, or document that token possession = invalidation authority (and make tokens non-transferable).

---

# P2: Invalidation matching logic is incomplete

**Location:** CoreAgentAppIntents.swift:600–611

```swift
let matchesDonation = request.donationIdentifier.map { $0 == record.donationIdentifier } ?? false
let matchesScope = request.scopeID.map { $0 == record.subject.scopeID } ?? false
return matchesDonation || matchesScope
```

If `request.donationIdentifier` is `nil` and `request.scopeID` is `nil`, both are `false`, and invalidation is **skipped** (line 565). But the caller may expect "invalidate everything" semantics.

**Risk:** Silent no-op. Caller provides incomplete invalidation request, thinks it succeeded, but nothing was invalidated.

**Recommendation:** Either require at least one of the two fields (throw if both nil), or explicitly document that nil means "skip this invalidation" and require the caller to provide specifics.

---

# No other blockers found.

Concurrency, Sendability, serialization of records/tokens, and donation policy checks are sound.