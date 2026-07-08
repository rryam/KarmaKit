Here is the security and correctness review of the CoreAgent AppIntents donation bridge slice.

---

### **Verdict: REJECTED**
The slice contains critical compilation errors due to API contract mismatches with Apple's `AppIntents.IntentDonationManager` and a P1 security vulnerability allowing scope-boundary bypass during donation invalidation.

---

### **Findings**

#### **P0: Compilation Error — `IntentDonationManager.donate` Returns `Void`**
* **File/Line:** `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift` (Lines 319–329)
* **Issue:** The system `IntentDonationManager.shared.donate(intent:)` API returns `Void` (no return value). The code attempts to assign its result to `identifier` (e.g., `identifier = try await IntentDonationManager.shared.donate(...)`), which will fail to compile.
* **Fix:** Remove the expectation of receiving an identifier from the OS donation call. If tracking is required, generate a stable, non-sensitive local identifier (e.g., a hash of the run ID and intent type) before donating.

---

#### **P0: Compilation Error — `IntentDonationManager.deleteDonations` Returns `Void`**
* **File/Line:** `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift` (Lines 338–341)
* **Issue:** `IntentDonationManager.shared.deleteDonations(matching:)` returns `Void`. The code assigns this to `deleted` and attempts to call `deleted.map(...)`, which results in a compiler error since `Void` does not conform to `Sequence` or support `map`.
* **Fix:** Change the backend protocol signature or return the input token upon successful execution of the deletion:
  ```swift
  try await IntentDonationManager.shared.deleteDonations(matching: .donationIdentifier(identifier))
  return [token]
  ```

---

#### **P1: Security — Scope Boundary Bypass in Invalidation Matcher**
* **File/Line:** `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift` (Lines 600–611)
* **Issue:** The helper `invalidationRequest(_:matches:)` uses logical OR (`||`) to evaluate matches:
  ```swift
  return matchesDonation || matchesScope
  ```
  If an invalidation request specifies both a `donationIdentifier` and a restricting `scopeID`, the record is invalidated if *either* matches. This allows a caller to bypass scope boundaries (e.g., invalidating a donation belonging to a different scope/tenant if they know the donation ID, or invalidating a donation within their scope even if the specific donation ID does not match).
* **Fix:** Enforce logical AND (`&&`) when both filters are present:
  ```swift
  let matchesDonation = request.donationIdentifier.map { $0 == record.donationIdentifier } ?? true
  let matchesScope = request.scopeID.map { $0 == record.subject.scopeID } ?? true
  return (request.donationIdentifier != nil || request.scopeID != nil) && matchesDonation && matchesScope
  ```

---

#### **P2: Logic Bug — Misleading Invalidation Reason on Backend Failure**
* **File/Line:** `Sources/CoreAgentAppIntents/CoreAgentAppIntents.swift` (Lines 546–552)
* **Issue:** If the OS backend donation fails (e.g., due to transient OS errors or timeout), the bridge invalidates the local store record using `reason: .policyChanged`. This is incorrect and pollutes the audit trail, as the policy did not change.
* **Fix:** Roll back the record from the store entirely on failure, or use a specific error reason (e.g., `.donationFailed` or `.systemError`).