I'll verify the three critical areas you specified across the provided code excerpts.

## Area 1: Forged traceScopeKey rows

**Status: PASS**

- `scopeKey()` (CoreAgentApplePlatform.swift:502-508) uses deterministic SHA256 hash of `[projectID, runID.uuidString.lowercased()]`
- `integrityDigest()` (lines 510-533) includes `traceScopeKey` in the digest computation
- Verification at lines 466-467 rejects any record where `traceScopeKey != Self.scopeKey(projectID, runID)`
- Test confirms rejection at line 1478: `"engine-trace-scope-sha256-v1:forged"` is properly rejected

## Area 2: Issue contributingRunIDs provenance across partial upserts and duplicate rows

**Status: PASS**

- `upsertIssue()` in CoreAgentEngine.swift (lines 242-270) correctly merges runs:
  - Lines 255-259: Computes set union via filter, preserving order
  - No duplicates introduced (filter prevents re-adding existing runs)
- SwiftData implementation (CoreAgentApplePlatform.swift:714-754) mirrors this logic identically
- `canonicalIssues()` (lines 926-941) deduplicates by issueID before returning
- Tests confirm:
  - Line 207: Partial upserts merge correctly `[uuid(461), uuid(462)]`
  - Line 1657: SwiftData also merges correctly `[uuid(750), uuid(751)]`
  - Line 1783: Duplicate collapse preserves all contributing runs `[uuid(748), uuid(749), uuid(752)]`

## Area 3: issueID project/fingerprint collision rejection

**Status: PASS**

- `validateIssueIdentity()` (CoreAgentApplePlatform.swift:943-960) enforces:
  - Lines 948-949: `existing.projectID == issue.projectID` AND `existing.fingerprint == issue.fingerprint`
  - Throws `issueIdentityMismatch` if either differs
- InMemory implementation (CoreAgentEngine.swift:243-254) has identical validation
- Tests confirm rejection:
  - Line 226-232: Different projectID + fingerprint correctly throws
  - Line 1659-1676: SwiftData also rejects mismatches

---

**VERDICT: PASS**

All three areas demonstrate correct correctness and data-integrity enforcement with no unresolved defects in the specified scope.