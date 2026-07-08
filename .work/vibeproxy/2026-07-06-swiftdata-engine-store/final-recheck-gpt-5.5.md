VERDICT: BLOCK

- SwiftData issue upsert still does not merge `contributingRunIDs` across all existing valid duplicate issue records for the same `issueID`. It selects only the canonical existing issue, merges incoming runs into that one, deletes all existing records, and can therefore drop provenance from non-canonical valid duplicates with the same `projectID`/`fingerprint`.