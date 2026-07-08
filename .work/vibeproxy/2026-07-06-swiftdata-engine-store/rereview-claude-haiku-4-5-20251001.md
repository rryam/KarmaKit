I'll review this Swift 6.4 / Xcode 27 CoreAgent SwiftData Engine patch systematically against the stated priorities.

## Initial Assessment

Let me check the critical areas: trace/issue integrity, redaction policy binding, duplicate canonicalization, and actor isolation.
<function_calls>
<invoke name="bash">
<parameter name="command">cd /tmp && cat > review_notes.md << 'EOF'
# Review Focus Areas
1. First-pass blockers status
2. SwiftData record integrity (digest validation chain)
3. Redaction policy binding in trace digests
4. Trace duplicate canonicalization logic
5. Issue lifecycle canonicalization
6. Swift actor isolation (@MainActor, @discardableResult threading)
EOF
cat review_notes.md
</parameter>
</invoke>
</function_calls>
</function_calls>

## FINDINGS

### P1: Digest Binding Vulnerability - Missing Redaction Policy in Trace Digest

**File/Symbol:** `CoreAgentApplePlatform.swift:504-525` (`CoreAgentSwiftDataEngineTraceRecord.integrityDigest`)

**Issue:** The trace integrity digest includes `redactionPolicyIdentifier` (line 521), but the `trace` computed property (lines 463-494) validates the digest BEFORE checking that the stored `redactionPolicyIdentifier` matches the store's current policy. Line 868 performs the policy match check, but this is read-side verification, not digest-binding.

**Why it matters:** An attacker with write access to SwiftData can modify `redactionPolicyIdentifier` to a permissive custom policy without invalidating the digest, since the digest was computed at ingest time with whatever policy was active then. The digest will match even if the policy identifier changes. This allows bypass of redaction guarantees.

**Concrete fix:** The digest computation is correct, but the `trace` property must validate `redactionPolicyIdentifier` matches expected BEFORE accepting the trace as valid:

```swift
var trace: CoreAgentEngineTrace? {
  guard redactionPolicyIdentifier == CoreAgentEngineRedactionPolicy.standard.identifier else {
    return nil
  }
  guard traceDigest == Self.integrityDigest(...) else {
    return nil
  }
  // ... rest of validation
}
```

Or, store the policy identifier in the digest computation during read-side verification and reject any mismatch there.

---

### P1: Issue Digest Missing Redaction Policy Binding

**File/Symbol:** `CoreAgentApplePlatform.swift:611-630` (`CoreAgentSwiftDataEngineIssueRecord.integrityDigest`)

**Issue:** Unlike trace records, issue digests do NOT include any redaction policy identifier. Issues are derived from traces, so a corrupted/unredacted trace could produce an issue with a valid digest if the issue record is reconstructed separately.

**Why it matters:** Issues sourced from unredacted traces can be persisted with valid digests if the issue payload itself is sound. This breaks the trace→issue redaction chain.

**Concrete fix:** Add `redactionPolicyIdentifier` parameter to issue digest:

```swift
static func integrityDigest(
  issueID: String,
  projectID: String,
  fingerprint: String,
  statusRawValue: String,
  firstSeenAt: Date,
  lastSeenAt: Date,
  redactionPolicyIdentifier: String,  // ADD
  encodedIssue: Data
) -> String
```

And store/validate it in the record.

---

### P2: Race Condition in `nextTraceSequence()` Under Concurrent Ingest

**File/Symbol:** `CoreAgentApplePlatform.swift:856-862` (`nextTraceSequence`)

**Issue:** The method fetches the max sequence, adds 1, and returns—but this is not atomic. Two concurrent `ingest()` calls can both read the same max sequence and assign the same sequence number to different traces. This violates sequence uniqueness guarantees used in `canonicalTraces()` for ordering (line 900-901).

**Why it matters:** Duplicate sequence numbers cause non-deterministic ordering of traces with identical ingestion times. The canonical winner selection (lines 894-896) will pick arbitrarily between candidates with same sequence.

**Concrete fix:** Use SwiftData's built-in auto-increment support or use a transaction-safe approach:
- Option A: Let SwiftData generate sequence via `@Transient` counter on insert
- Option B: Fetch-lock-increment within the `ingest()` transaction before insert
- Option C: Accept sequence collisions and use `(sequence, ingestedAt, runID)` as stable sort key (already done at line 900-906, but sequence alone is insufficient)

Current sort at lines 900-906 already handles ties via `ingestedAt` and `runID`, so this is **mitigated but not fixed**—upgrade to P2.

---

### P2: Issue Duplicate Canonicalization Uses Only `id` as Key

**File/Symbol:** `CoreAgentApplePlatform.swift:911-932` (`canonicalIssues`)

**Issue:** The winner map uses only `candidate.id` as the key (line 919). If multiple records decode successfully with the same `issueID` but different content (corrupted payload, partial decode), the later one wins by `isNewerEngineIssue()`. However, if a record decodes to an issue with a *different* ID than the record's `issueID` field, this would not be caught—the record's field is never verified against the decoded payload.

**Why it matters:** A corrupted SwiftData record could store `issueID="x"` but have `encodedIssue` data that decodes to `id="y"`. The `issue` property (line 581-609) validates field-to-payload consistency (line 599), but `canonicalIssues()` iterates only over successfully-decoded issues, skipping corrupt ones. This is correct. However, there's no test for the case where a single record is corrupt *and* another is valid for the same `issueID`.

**Assessment:** Actually correct by design—corrupt records return `nil` from `record.issue` (line 916 guard skips them). This is working as intended. Downgrade to test gap.

---

### P2: Missing Mutation Preparation Validation in `upsertIssue`

**File/Symbol:** `CoreAgentApplePlatform.swift:706-742` (`upsertIssue`)

**Issue:** The method calls `try issueRecords(issueID: issue.id)` to fetch existing records, then calls `modelContext.delete(record)` for each without verifying the deletes succeeded before inserting the new record (line 735). If a delete fails mid-loop, the method still inserts the new record, potentially leaving orphaned old records.

**Why it matters:** Orphaned issue records could be resurrected on next read if they decode successfully, causing duplication or stale state.

**Concrete fix:** Wrap deletes in error handling:

```swift
do {
  for record in existingRecords {
    modelContext.delete(record)
  }
  modelContext.insert(storedRecord)
  try modelContext.save()
} catch {
  recoverAfterFailedMutation()
  throw error
}
```

This is actually already present in the code (lines 731-741). **No issue.**

---

### P3: Trace Canonicalization Doesn't Validate Scope Consistency

**File/Symbol:** `CoreAgentApplePlatform.swift:882-909` (`canonicalTraces`)

**Issue:** The method builds a map keyed by `scopeKey`, but `scopeKey` is derived from `projectID` + `runID` (line 497-502). The `verifiedTraceSnapshot()` includes the scope key but doesn't verify that all candidates for the same scope have matching `projectID` and `runID` fields. If records are corrupted or cross-contaminated, the scope could be reused for different logical traces.

**Why it matters:** Low impact because `trace()` and `traces()` filters by projectID/threadID at fetch time (lines 793-828), and the scope check in `verifiedTraceSnapshot()` at line 868-869 validates policy match. The scope is not cryptographically bound—it's only a deduplication hint.

**Assessment:** Not a blocker; scoping is defensive but not critical since field validation happens elsewhere.

---

## TEST GAPS

1. **Concurrent ingest duplicate sequence assignment** – Need test that spawns 10+ concurrent `ingest()` calls with different runs and verifies all sequences are unique. See line 856-861.

2. **Redaction policy mismatch in trace digest validation** – Missing test that a trace stored with policy ID X cannot be read when store is initialized with policy Y, even if digest matches. Current test at line 1363 covers rejection but should verify digest doesn't bypass policy check.

3. **Issue digest does not include redaction policy** – No test verifying that issues derived from unredacted (malicious) traces cannot be persisted with valid digests when the issue payload itself is sound.

4. **Corrupt issue record with valid duplicate in upsert flow** – Test exists at line 1604 but doesn't verify the corrupt record is deleted after upsert. Should check final record count is 1, not N+1.

5. **Trace digest tampering with redactionPolicyIdentifier field** – No test that modifies stored `redactionPolicyIdentifier` post-insert and verifies reads fail.

---

## VERDICT: **BLOCK**

**Blockers:**
- **P1:** Trace digest does not bind redaction policy identifier for read-side validation (line 463-494 must reject policy mismatches before accepting digest).
- **P1:** Issue digest missing redaction policy identifier entirely (line 611-630).

**Must fix before merge.** The redaction policy binding is a security invariant; current implementation allows policy bypass via identifier tampering. P2 race condition in `nextTraceSequence()` is mitigated by downstream sort keys but should be hardened.