# Changelog

## Unreleased (hard fork)

- Declared this repository (`24601/coreagent`) an independent **hard fork** of the
  upstream `rudrankriyam/CoreAgent` project. Added a `NOTICE` file and README
  attribution covering the upstream MIT license and the behavioral port of
  runtime concepts from LangChain, Inc.'s MIT-licensed LangGraph, Deep Agents,
  and LangChain, plus closed-loop behaviors popularized by LangSmith (LangChain,
  Inc.'s proprietary hosted product). No source was copied from those projects.
- Versioning now diverges from upstream; releases are cut independently from this
  fork rather than tracking upstream `0.3.0` tags.
- Added the portable `CoreAgentTalon` product with per-conversation host
  serialization, conversation-scoped stop/new commands, injected-clock cron
  scheduling, and Codable `talon_event` records.
- Added the optional `TalonChannels` trait target with host-provided WhatsApp,
  Telegram, and MCP channel adapter contracts plus fail-closed exposure and
  single-operator policies.
- Added CoreAgentGraph deferred node scheduling with typed
  `addNode(_:defer:...)` builder support for map-reduce joins after `Send`
  fanout.
- Ongoing: Swift, Foundation Models-native ports of graph runtime
  (`CoreAgentGraph`), deep-agent harness (`CoreAgentDeep`), run/evidence engine
  (`CoreAgentEngine`), skills/RSI optimization (`CoreAgentSkills`), and the
  portable Talon core with optional channel adapters (`CoreAgentTalon`,
  `CoreAgentTalonChannels`).

## 0.3.0 - 2026-06-24

- Renamed the Apple utilities helper from `openAICompatible(...)` to
  `chatCompletions(...)` and removed the OpenAI-specific type alias. The helper
  is a generic Chat Completions protocol client, not an official OpenAI SDK.

## 0.2.0 - 2026-06-23

- Rebuilt CoreAgent on native Xcode 27 Foundation Models types.
- Added persistent `CoreAgentSession` text, structured, schema, and streaming
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
- Added the optional `CoreAgentMemory` product with scoped canonical SQLite
  records, FTS5 retrieval, provenance, supersession, tombstones, and Apple file
  protection defaults.
- Added automatic episode capture, durable three-attempt consolidation jobs,
  pending semantic candidates, approval policies, and a fresh-session
  Foundation Models consolidator.
- Added bounded untrusted-evidence injection, the governed
  `coreagent_search_memory` tool, disclosure filtering, optional index repair,
  deterministic Markdown export, and hard-purge cleanup.
- Suppressed retries after tool invocation (including authorization) and
  applied timeout/retry semantics to streaming before its first partial
  response.
- Removed the 0.1 provider/message/tool abstraction, adapter, tools product, and
  CLI.
