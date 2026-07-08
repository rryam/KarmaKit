# VibeProxy SwiftData Checkpoint Store Adjudication

Date: 2026-07-06
Endpoint: `http://127.0.0.1:8320/v1/chat/completions`
Scope: live `CoreAgentSwiftDataCheckpointStore` slice

## Model Status

- `gpt-5.5`: HTTP 200, artifact `gpt-5.5.md`
- `gemini-3.5-flash-low`: HTTP 200, artifact `gemini-3.5-flash-low.md`
- `claude-haiku-4-5-20251001`: HTTP 200, artifact `claude-haiku-4-5-20251001.md`

Prompt artifact: `prompt.md`
Diff artifact: `diff.patch`

## Accepted Findings Fixed

- `scopedRecords(for:)` fetched the whole SwiftData checkpoint table and
  filtered in memory. Fixed by using a SwiftData predicate over the deterministic
  scope key plus raw checkpoint key, authority boundary, and policy version.
- Store mutation failure recovery called `rollback()` on caller-supplied
  `ModelContext`s, which could discard unrelated pending app changes in a shared
  UI context. Fixed by adding a `ModelContainer` initializer that owns an
  isolated context and limiting automatic rollback to that path; caller-supplied
  shared contexts now own rollback policy.
- Scope-key versioning was cheap hardening. The scope key now uses
  `scope-sha256-v1:`.
- The redundant in-memory scope checks after the SwiftData predicate are now
  documented as defensive protection against manually corrupted rows.

## Adjudicated Non-Blockers

- The claim that `@MainActor` store methods violate actor isolation because
  `modelContext.fetch` lacks `await` was false. The store is globally isolated
  to the main actor, and focused tests call it through `any CoreAgentCheckpointStore`.
- The checkpoint-ID digest issue was explicitly marked as no issue by the model
  output; the current digest already binds `checkpointID` and has replay tests.
- The separator-collision concern for `scopeKey` was not valid as stated:
  length-prefixed framing is hashed, so literal `|` in fields does not create an
  ambiguous tuple. Versioning was still added for migration clarity.
- Sub-nanosecond `Date` distinctions are outside the durable checkpoint
  contract. The persisted canonical checkpoint bytes remain authoritative, and
  tests cover exact `Date` round trips through SwiftData.

## Verification

- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 26
  tests after the VibeProxy fixes.
- `swift test --skip-update` passed after the VibeProxy fixes.
- `swift build --skip-update` passed after the VibeProxy fixes.
- `git diff --check` passed after the VibeProxy fixes.
- Trailing-whitespace scan over tracked-modified and untracked text artifacts
  passed after the VibeProxy fixes.
