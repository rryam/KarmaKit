# CoreAgentDeep Filesystem Tool Surface Parity

Created: 2026-07-08

## Objective

Align CoreAgentDeep's model-facing filesystem surface with current Deep Agents
0.7 documentation while preserving source compatibility for existing hosts.

## External Contract

- Current Deep Agents docs list the destructive filesystem tool as `delete`,
  not `delete_file`.
- `FilesystemMiddleware(tools=...)` exposes a built-in filesystem allowlist;
  `read_file` is required for that allowlist.
- Unsupported capabilities are hidden from the model-facing surface. CoreAgent
  has no default shell `execute` tool in CoreAgentDeep; sandbox/interpreter
  authority remains in CoreAgentApplePlatform.

## Design

- Add a typed `CoreAgentDeepFilesystemToolName` enum for built-in filesystem
  tool names.
- Add `CoreAgentDeepFilesystemToolSurface` as the Swift-native equivalent of
  Deep Agents' filesystem allowlist and excluded-tools surface.
- Add canonical `CoreAgentDeepDeleteTool` with model-facing name `delete`.
- Keep `CoreAgentDeepDeleteFileTool` as a compatibility alias for existing
  code, but exclude it from the default model-facing surface.
- Wire CoreAgentAgenticKit through the typed surface so the integrated default
  exposes current Deep-compatible names.

## TDD Checklist

- [x] Red: filesystem tests fail on missing `CoreAgentDeepFilesystemToolSurface`
      and canonical `delete`.
- [x] Green: implement typed surface, excluded-tools validation, and delete
      tool without widening filesystem permissions.
- [x] Green: update AgenticKit default and read-only surface tests.
- [x] Docs: update runtime docs and task ledger with L50 evidence.
- [x] Verify: focused Deep tests, AgenticKit tests, full tests/build, lint or
      scoped formatting, and diff hygiene.

## Non-Goals

- Do not add shell `execute` to CoreAgentDeep.
- Do not remove `delete_file` source compatibility.
- Do not change filesystem permission semantics.
- Do not implement LangGraph `Send` in this slice.
