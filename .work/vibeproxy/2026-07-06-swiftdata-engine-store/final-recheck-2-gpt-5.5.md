VERDICT: BLOCK

- `canonicalIssues(from:)` collapses duplicate issue rows by `issue.id` only, with no projectID/fingerprint identity check before merging. Valid duplicate rows with the same `issueID` but different `projectID` and/or `fingerprint` can be merged on read paths, contaminating `contributingRunIDs` provenance across distinct issue identities.

- Because that read-side canonicalization does not reject identity collisions, SwiftData issue readback can silently accept/merge an `issueID` project/fingerprint collision even though `upsertIssue` rejects such collisions.