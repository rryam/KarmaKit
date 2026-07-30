# Changelog

## Unreleased

- Renamed the primary runtime APIs to `AgentSession`, `AgentSessionPlugin`, and
  `AgentSessionMode`. This is a source-breaking change with no compatibility
  aliases.
- Added native explicit-model context budgeting with reserved response
  headroom, fractional and absolute input limits, deterministic overflow
  policy, per-component accounting, and fail-before-inference behavior.
- Added audited app-owned history transforms with authoritative-checkpoint
  preservation, tool-turn validation, cancellation, and a documented
  dynamic-profile boundary that composes with Apple's history utilities.
- Added atomic routed-session construction so context measurement receives the
  actual selected native model without treating route metadata as token counts.
- Added explicit app-policy routing among native `LanguageModel` values with typed
  availability, privacy/network, context, reasoning, quota, accounting, fallback,
  and per-candidate decision evidence.
- Added truthful on-device and Private Cloud Compute snapshots plus routed
  `AgentSession` provenance on completed and failed runs.
- Added Xcode 27 dynamic-profile tool governance with explicit manifest
  registries, fail-closed unknown and changed-tool handling, canonical native
  arguments, async approval, total and per-tool call budgets, and audited
  pre-execution outcomes carrying native tool-call IDs.

## 0.4.0 - 2026-07-30

- Renamed the package, products, modules, and public APIs to Foundation Models
  Agent.
- Updated the Apple utilities, Claude, and Gemini provider revisions for the
  Xcode 27 Beta 4 Foundation Models sampling and usage APIs.
- Added an explicit note that the project is independent and is not affiliated
  with or endorsed by Apple.

## 0.3.0 - 2026-06-24

- Renamed the Apple utilities helper from `openAICompatible(...)` to
  `chatCompletions(...)` and removed the OpenAI-specific type alias. The helper
  is a generic Chat Completions protocol client, not an official OpenAI SDK.

## 0.2.0 - 2026-06-23

- Rebuilt FoundationModelsAgent on native Xcode 27 Foundation Models types.
- Added persistent `AgentSession` text, structured, schema, and streaming
  response APIs.
- Added a dynamic-profile factory path with history-only restore and explicit
  checkpoint compatibility revisions.
- Added best-effort lifecycle auditing and an explicit audit-boundary event for
  profile-owned tools, including later failures that revert the transcript.
- Added governed native tools with approval, allowlist, trusted-manifest,
  timeout, and total-call-budget policies.
- Added versioned transcript checkpoints with restore-time toolset validation.
- Added fail-fast disk checks for custom segments and typed metadata that cannot
  round-trip with concrete Swift type identity.
- Added ordered run events, bounded per-observer delivery, usage, and
  tamper-evident receipts.
- Added `RecordedLanguageModel` for deterministic, zero-network tests.
- Added optional Apple utilities, Claude, and Gemini provider Traits.
- Added session plugins with bounded pre-run context, post-run capture hooks,
  governed plugin tools, and transcript sanitization across retries and streams.
- Added the optional `FoundationModelsAgentMemory` product with scoped canonical SQLite
  records, FTS5 retrieval, provenance, supersession, tombstones, and Apple file
  protection defaults.
- Added automatic episode capture, durable three-attempt consolidation jobs,
  pending semantic candidates, approval policies, and a fresh-session
  Foundation Models consolidator.
- Added bounded untrusted-evidence injection, the governed
  `foundationmodelsagent_search_memory` tool, disclosure filtering, optional index repair,
  deterministic Markdown export, and hard-purge cleanup.
- Suppressed retries after tool invocation (including authorization) and
  applied timeout/retry semantics to streaming before its first partial
  response.
- Removed the 0.1 provider/message/tool abstraction, adapter, tools product, and
  CLI.
