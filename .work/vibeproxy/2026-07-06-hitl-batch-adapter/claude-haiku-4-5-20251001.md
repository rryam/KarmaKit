# Code Review: CoreAgentDeep HITL Batch Adapter

**Verdict: BLOCK**

---

## Findings

### 🔴 Critical

**Severity: Critical | File: `CoreAgentDeepHITLBatch.swift:551-567` | Symbol: `CoreAgentGraphRuntimeContext.requestDeepHITLReview`**

**Issue:** Logic error in resume recovery. The code checks `guard let encodedResume = command?.resumeValue, let resume = try?...` then calls `try interrupt(...)` on failure. If `encodedResume.decode` throws OR if `resume.interruptID` does not match, the guard fails silently and interrupts again. This means a malformed resume is indistinguishable from a missing resume—both re-interrupt instead of surfacing the mismatch error.

**Why it matters:** HITL authorization contract broken. A resumed-with-wrong-interrupt-ID scenario must fail audibly before resolver runs, not silently re-interrupt and allow a second human review loop. This violates the ordered decision binding contract and creates audit ambiguity.

**Fix:** Split the guard into two stages:
```swift
guard let encodedResume = command?.resumeValue else {
  try interrupt(bundle, id: reviewID)
  // Should not reach here
}
let resume = try encodedResume.decode(as: CoreAgentDeepHITLBatchResume.self)
// Now always call resolve; mismatch errors surface explicitly
return try CoreAgentDeepHITLBatchResolver.resolve(...)
```

---

### 🔴 Critical

**Severity: Critical | File: `CoreAgentDeepHITLBatch.swift:294-305` | Symbol: `CoreAgentDeepNativeToolBatchHITLAdapter.decide`**

**Issue:** Race condition on mutable `decisions` array. The code builds `decisions` sequentially, then iterates `zip(interrupted, zip(actionIdentities, resolutions))` to mutate it by index. If two interrupted requests map to the same index (impossible by construction) or if the zipped triplet iteration fails to align, array bounds are violated. More critically, **there is no Sendable guarantee that `decisions` safely escapes the async boundary**—it's a local `var` array mutated across await points without explicit isolation.

**Why it matters:** Memory safety and concurrency contract. Swift Concurrency will reject this array if a downstream reviewer is an actor or lock-protected type. The async context boundary is crossed without proving the array is safe to share.

**Fix:** Build the result inline:
```swift
var results: [CoreAgentDeepNativeToolBatchDecision] = []
for (index, request) in requests.enumerated() {
  if let ruleIdx = interrupted.firstIndex(where: { $0.request.invocationID == request.invocationID }) {
    let (identity, resolution) = (actionIdentities[ruleIdx], resolutions[ruleIdx])
    results.append(CoreAgentDeepNativeToolBatchDecision(...))
  } else {
    results.append(CoreAgentDeepNativeToolBatchDecision(request: request, decision: .approve))
  }
}
return results
```
Or use a dictionary keyed by `invocationID` to avoid index alignment entirely.

---

### 🔴 Critical

**Severity: Critical | File: `CoreAgentDeepHITLBatch.swift:518-525` | Symbol: `CoreAgentDeepHITLBatchResolver.identity` | DigestPayload**

**Issue:** Digest computation includes `configDescription` (optional) and `allowedDecisions.sorted()`, but the review bundle structure allows the same action to have different configs at different indices if a host supplies mismatched bundles. The digest is computed per action+config pair, so it binds to the *index-matched* config, not to the action name alone. However, the tests and the adapter assume the digest is stable regardless of config order. If a resume arrives with decisions in a different order than the bundled configs, the digests will not match even for the same actions.

**Why it matters:** Identity binding contract broken. The digest should represent the *immutable action request* alone, not the paired config. If the config changes (e.g., allowed decisions are restricted), the same action should still validate if the digest is based on action only. Current design couples action identity to config state, making reconfigs impossible and allowing config-order sensitivity.

**Fix:** Compute digest over action request only; validate allowed-decisions separately:
```swift
let payload = DigestPayload(
  actionName: action.name,
  argsJSON: action.argsJSON,
  description: action.description,
  toolCallID: action.toolCallID
)
// No config fields in digest
let digest = SHA256.hash(data: try encoder.encode(payload))...
```
Then validate `decision.type ∈ boundAction.config.allowedDecisions` as a separate check (already done in `validate(decision:for:)`).

---

### 🟠 P1

**Severity: P1 | File: `CoreAgentDeepHITL.swift:308-340` | Symbol: `CoreAgentDeepHITLPolicy.decide`**

**Issue:** The single-tool decision flow does not call `CoreAgentDeepHITLBatchResolver.resolve()` or any digest-binding logic. If a reviewer returns a decision for a different tool or with tampered arguments, the policy does not validate it. The batch resolver *does* validate digest/action identity; the single-tool policy does not. This is an asymmetric authorization contract.

**Why it matters:** HITL authorization asymmetry. A single-tool HITL call can accept a decision bound to the wrong tool or a digest mismatch without error. The batch path is hardened; the single-tool path is not. Hosts may assume single-tool calls are equally validated.

**Fix:** Reuse `CoreAgentDeepHITLBatchResolver` for single-tool validation:
```swift
let bundle = CoreAgentDeepHITLReviewBundle(
  actionRequests: [actionRequest],
  reviewConfigs: [reviewConfig]
)
let actionIdentities = try CoreAgentDeepHITLBatchResolver.identities(for: bundle)
let resume = CoreAgentDeepHITLBatchResume(
  interruptID: "single-tool-review",
  decisions: [CoreAgentDeepHITLBatchDecision(...)]  // from reviewer
)
let resolutions = try CoreAgentDeepHITLBatchResolver.resolve(
  bundle: bundle,
  resume: resume,
  expectedInterruptID: "single-tool-review"
)
// Now safely map resolutions to CoreAgentToolInterventionDecision
```

---

### 🟠 P1

**Severity: P1 | File: `CoreAgentDeepHITLBatch.swift` | Test: `CoreAgentDeepHITLBatchTests.swift`**

**Issue:** Tests do not cover the resume-with-wrong-interrupt-ID re-interrupt case described in the Critical logic-error finding above. The test `resumeInterruptIDMustMatchPendingReview` only checks the error path; it does not verify that a fresh interrupt is issued on mismatch. Similarly, no test covers the case where `encodedResume.decode` throws (e.g., corrupted JSON). Re-interrupt behavior on decode failure is untested.

**Why it matters:** Test brittl