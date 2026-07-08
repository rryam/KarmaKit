# VibeProxy SwiftData Engine Store Adjudication

Date: 2026-07-06
Gateway: `http://127.0.0.1:8320/v1/chat/completions`
Models: `gpt-5.5`, `gemini-3.5-flash-low`, `claude-haiku-4-5-20251001`

## Artifacts

- Initial review: `prompt.md`, `status.tsv`, `gpt-5.5.md`, `gemini-3.5-flash-low.md`, `claude-haiku-4-5-20251001.md`
- Re-review: `rereview-prompt.md`, `rereview-status.tsv`, `rereview-*.md`
- Final checks: `final-recheck-*.md`, `final-recheck-2-*.md`, `final-recheck-3-*.md`

## Valid Findings Fixed

- Public decoded `trace`/`issue` record accessors were reduced to internal access so store-level policy remains the readback path.
- Trace readback now collapses duplicate valid rows by logical project/run identity and rejects forged scope keys.
- Trace integrity now binds the trace scope key and redaction policy identifier.
- SwiftData `nextTraceSequence()` now fetches one max-sequence row instead of loading the table.
- Issue readback collapses duplicate valid rows without losing contributing-run provenance.
- Issue upsert unions contributing run IDs across partial updates.
- Issue upsert rejects same issue ID with different project/fingerprint identity; readback fails closed on valid same-ID identity collisions.
- Mutation paths now construct replacement records before destructive deletes.

## Final Recheck

Final narrow recheck passed on all three models:
gpt-5.5	200	1088
gemini-3.5-flash-low	200	400
claude-haiku-4-5-20251001	200	2923
