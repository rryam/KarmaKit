P1 — `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:312`  
`CoreAgentIntentDonationManagerRunBackend.donate(_:)` is public and can call `IntentDonationManager.shared.donate(...)` with only run-ID + descriptor policy validation. It does **not** require/verify CoreAgent action-gate consent, capability gating, or a validated local donation record. Any caller with this backend can donate `.pauseRun` / `.continueRun` for any syntactically valid run ID, bypassing the bridge contract.  
**Fix:** make the OS backend non-public/internal and only callable from the bridge after gate evaluation, or change the backend API to require a validated/gated `CoreAgentAppIntentDonationRecord` plus consent/gate proof and reject otherwise.

P1 — `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:500` / `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:536`  
The bridge builds the policy/gate/store record from caller-supplied `request.subject`, but donates the OS intent using independently supplied `request.runID`. There is no binding check between the stable donation identity and the run ID. A caller can obtain consent/gate approval for subject/scope A while donating an OS intent for run B. This breaks stable identity, consent scope, and invalidation correctness.  
**Fix:** derive the donation subject/stable identifier from `runID` inside the bridge, or enforce a canonical equality/binding rule before gate evaluation and backend donation.

P1 — `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:539` / `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:429`  
`donate(_:)` discards the `CoreAgentAppIntentOSDonationToken` and returns only its digest in the receipt, but `invalidate(_:)` requires the full token. A caller using only the public donation result cannot later invalidate the OS donation. This violates the invalidation semantics contract and encourages out-of-band token handling.  
**Fix:** include the OS donation token in the receipt or persist it in the store behind the receipt ID so invalidation can be performed from the receipt alone.

P1 — `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:560` / `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift:569`  
Invalidation checks that the invalidation request matches the receipt record, but never verifies that `request.osDonationToken.digest == request.receipt.osDonationIdentifierDigest`. A mismatched receipt/token pair can delete OS donation B while recording invalidation for donation A.  
**Fix:** before `backend.deleteDonation`, reject/skip unless the token digest matches the receipt digest.

Verdict: blockers present. The slice does not yet satisfy the required OS donation contract.