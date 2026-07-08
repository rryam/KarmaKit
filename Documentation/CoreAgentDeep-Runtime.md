# CoreAgentDeep Runtime

Created: 2026-07-05

`CoreAgentDeep` is the Swift-native Deep Agents harness layer that builds on
`CoreAgent` and `CoreAgentGraph`. This document describes the behavior
implemented so far; it is not a claim that the full Deep Agents port is done.

## Implemented

- `CoreAgentDeepTodoStatus` with protocol literals:
  `pending`, `in_progress`, and `completed`.
- Typed `CoreAgentDeepTodo` state and `CoreAgentDeepTodoStore`.
- Model-facing `write_todos` tool that replaces the current typed todo list.
  The model-facing payload uses raw status strings and converts at the tool
  boundary, while stored state remains typed.
- Optional `CoreAgentDeepTodoWriteGuard` for enforcing one `write_todos` call
  per turn scope. Direct tool callers can still supply an explicit async
  `turnID` closure for custom host scopes.
- `CoreAgentDeepTodosPlugin`, an ergonomic `CoreAgentSessionPlugin` that
  exposes `write_todos` and binds the default guard scope to
  `CoreAgentToolInvocation.current.runID` during governed CoreAgent tool
  execution. Any scoped `write_todos` invocation reserves that turn scope before
  status validation, so an invalid first attempt cannot be followed by a valid
  second mutation in the same run. A second `write_todos` call in the same
  CoreAgent run/model turn fails before mutating todo state, while later
  CoreAgent runs receive fresh run scopes. `CoreAgentDeepTodoTool` also adopts
  `CoreAgentRunLifecycleTool` so bare tool registration clears finished run
  scopes; plugin completion and failure clear the completed run scope as
  cleanup too. Direct calls outside CoreAgent remain unguarded unless the host
  supplies a turn scope.
- `CoreAgentDeepFilesystemBackend` protocol.
- `CoreAgentDeepStateFilesystem`, a thread-scoped in-memory virtual filesystem
  intended as the safe default backend shape.
- `CoreAgentDeepLocalFilesystem`, an opt-in host-local filesystem backend.
  It is not a sandbox.
- `CoreAgentDeepToolResultOffloader` for moving oversized non-built-in tool
  results into `/large_tool_results/<tool_call_id>` and returning a compact
  reference plus head/tail preview. Built-in filesystem/todo tools are excluded
  because they paginate, search, or return small confirmations. The default
  threshold follows stable Deep Agents' `20_000` token limit approximation
  (`80_000` characters at four characters per token).
- `CoreAgentDeepOffloadingTool` wrapper for applying the offloader to
  Foundation Models tools that return `String`, while preserving the wrapped
  tool's public name, description, schema, and instruction visibility.
- `CoreAgentDeepConversationHistoryCompactor` for checkpoint-backed
  conversation-history offload and lossy summary injection. It stores the full
  native `Transcript` in a JSON envelope registered as
  `CoreAgentCheckpointArtifact` metadata, inserts a plain-text
  `COREAGENT_DEEP_CONVERSATION_HISTORY_OFFLOADED_V1` summary marker with an
  opaque artifact ID instead of a raw filesystem path, retains only recent
  complete prompt-led turns, redacts summary excerpts, structurally redacts
  tool-call JSON arguments, omits hidden reasoning entries from prompt-visible
  summaries, and exposes
  `CoreAgentTranscriptRetention.deepConversationHistory(...)` for sessions that
  want compacted persisted checkpoints.
- Deep conversation-history retention now opts into active native-session
  rebuilds after a compacted checkpoint is durably saved. The next same-session
  model turn sees the compacted retained transcript instead of the full old
  native history. Rebuilds emit `transcriptActiveSessionCompacted` events.
- Active conversation-history rebuilds are deliberately gated on an actual
  checkpoint-store save. Manual checkpoint construction without a checkpoint
  store returns the compacted checkpoint object but does not mutate the active
  native session.
- Conversation-history artifact cleanup validates the compactor-owned artifact
  path shape before deletion, preserves previously committed deterministic
  artifacts during rollback, and deletes artifacts only after checkpoint removal
  succeeds.
- CoreAgent checkpoint retention now supports transactional side effects:
  custom retention can finalize artifacts before checkpoint save, roll them
  back when checkpoint persistence fails, and remove checkpoint artifacts during
  `reset(removingCheckpoint: true)`.
- Default-deny filesystem permissions with explicit allow/deny rules,
  first-match-wins evaluation, canonical virtual paths, root containment,
  symlink escape rejection, parent-directory escape rejection, and `~` host-path
  shorthand rejection. Each operation grant is explicit: `read`, `write`,
  `list`, `edit`, `glob`, `grep`, and `delete` do not imply each other.
- Audit-visible filesystem allow/deny events, including denied root-escape
  attempts.
- `CoreAgentDeepFilesystemToolSurface`, a Swift-native filesystem-only tool
  allowlist/excluded-tools surface. It hides omitted or excluded built-in
  filesystem tools without affecting custom host tools, requires `read_file`,
  and applies backend capability filtering before tools become model-visible.
- Model-facing filesystem tools:
  - `ls`
  - `read_file`
  - `write_file`
  - `edit_file`
  - `delete`
  - `glob`
  - `grep`
- `CoreAgentDeepDeleteFileTool` remains a source-compatible `delete_file`
  alias for older hosts, but `CoreAgentDeepFilesystemToolSurface.all` and
  `CoreAgentAgenticKit` default to the current Deep Agents `delete` name.
- `CoreAgentDeepTaskTool` with Deep-compatible model-facing name `task`.
  It dispatches to an explicitly registered subagent by `subagent_type`, passes
  only the requested task description to the child, and returns a single final
  handoff to the parent.
- `CoreAgentDeepSubagentBudget` and
  `CoreAgentDeepSubagentBudgetState` for recursive subagent depth and total
  delegation limits. Model-facing task tools default to the bounded
  `CoreAgentDeepSubagentBudget.modelFacingDefault`; hosts must opt into
  `.unlimited` explicitly. A root task call has budget depth `1`; nested task
  calls increment that depth and share the same actor-backed delegation ledger
  through task-local propagation.
- Top-level task calls made inside one CoreAgent parent run share delegation
  budget by parent run ID. Direct task-tool calls outside a CoreAgent run share
  a stable tool-instance budget scope until the host calls `resetBudgetScopes()`
  or opts into a new tool instance.
- Budget denials fail closed before child session creation or handler
  execution. Empty task descriptions are rejected before budget is consumed.
  Unknown non-empty subagent requests consume task-attempt budget before
  returning the unavailable-subagent message.
- `CoreAgentDeepSessionSubagent`, which creates a fresh isolated
  `CoreAgentSession` for each child run. Child runs use separate checkpoint keys
  under `coreagent-deep/subagents/<subagent>/<task-id>` by default.
- Child subagent tools are deny-by-default. A subagent that needs child tools
  must receive an explicit child `CoreAgentToolConfiguration`, so parent
  approval of `task` does not silently grant child tool authority.
- `CoreAgentDeepSubagentAuditStore` and
  `CoreAgentDeepSubagentAuditRecord`, including parent run/tool invocation IDs
  when the task tool is called through CoreAgent's governed tool path, child run
  ID, child receipt root hash, checkpoint key, status, redacted bounded error
  text, error type, redacted bounded task description, and budget
  depth/delegation fields. Completed, denied, and failed task attempts are
  audit-visible.
- `CoreAgentDeepSubagentsPlugin`, an ergonomic `CoreAgentSessionPlugin` that
  exposes the `task` tool without requiring app code to pass it manually in
  every session initializer.
- `CoreAgentDeepHITLPolicy`, a Deep-compatible human-in-the-loop policy over
  CoreAgent's native governed-tool path. It supports `interrupt_on`-style
  per-tool rules, `allowed_decisions`, optional conditional predicates, and
  typed `approve`, `edit`, `reject`, and `respond` decisions. Approved and
  edited calls proceed to normal `CoreAgentToolPolicy` authorization before
  execution. Rejected and responded calls synthesize tool output without
  executing the underlying tool.
- CoreAgent tool intervention audit events:
  `toolInterventionStarted`, `toolInterventionApproved`,
  `toolInterventionEdited`, `toolInterventionRejected`,
  `toolInterventionResponded`, `toolInterventionCancelled`, and
  `toolInterventionFailed`.
- Edited tool calls keep the native transcript's original model-requested tool
  call, but CoreAgent's receipt events carry the canonical execution evidence:
  original/executed argument digests, `arguments_source=intervention_edit`, and
  redacted requested/executed argument JSON on the intervention event. Existing
  `CoreAgentToolPolicy` authorization runs against the edited arguments before
  execution.
- Rejected and responded tool calls are marked on the native tool-output audit
  event with `output_source=intervention_reject` or
  `output_source=intervention_respond`, plus the CoreAgent tool invocation ID.
  They are not indistinguishable from real tool execution in run receipts.
- `CoreAgentDeepHITLBatchResume`, `CoreAgentDeepHITLBatchResolver`, and
  `CoreAgentGraphRuntimeContext.requestDeepHITLReview` provide graph-level
  batched HITL review. A graph node can interrupt once with an ordered
  `CoreAgentDeepHITLReviewBundle`, persist the interrupted node through
  `CoreAgentGraph` checkpoints, then resume with one ordered decision per
  action request. When no explicit interrupt ID is supplied, the helper derives
  a node-scoped default ID: `coreagent-deep-hitl/<node-id>`.
- Batched HITL resume supports `approve`, `edit`, `reject`, and `respond`.
  `approve` returns the original executable action. `edit` returns an
  executable action with both reviewed/requested identity and
  executable/edited identity, so graph executors and receipt writers can audit
  what the model requested separately from what the human approved. Same-tool
  edits require only the `edit` decision. Tool-name retargets require the
  same-index review config to list the target in
  `allowed_edited_action_names`; that allowlist participates in the action
  digest under `digestVersion=1`, and retargeted resolutions carry typed
  `CoreAgentDeepHITLEditedTargetAuthorization` evidence. The graph resolver
  does not own a tool registry; `CoreAgentDeepHITLExecutableActionExecutor`
  provides the executor-facing boundary that looks up the executable target
  manifest by `executableName`, parses requested/executable JSON, runs final
  `CoreAgentToolPolicy` authorization against the executable target request,
  and calls a host backend under `CoreAgentToolInvocation.current` with the
  executable tool name and manifest digest. `reject`/`respond` return synthetic
  tool-output resolutions without executable actions.
- `CoreAgentDeepHITLExecutableActionExecutor` fails closed on missing or
  duplicate executable manifests and malformed requested/executable arguments.
  Its result carries the graph tool-call ID, requested/executable names,
  action source (`approve` or `edit`), reviewed action identity, edited-target
  authorization evidence, canonical `CoreAgentArgumentAudit` digests, and
  redacted requested/executable JSON. The deterministic invocation ID is derived
  from the run ID, graph tool-call ID, executable name, executable manifest
  digest, and executable argument digest. The dispatcher is not a substitute for
  `CoreAgentSession` receipts; hosts that need receipt parity must emit their own
  audit/custom-event path around the backend.
- Graph HITL review action digests and executable argument audit digests are
  separate domains. `CoreAgentDeepHITLActionIdentity.actionDigest` binds the
  interrupted review payload and same-index review config for safe resume.
  `requestedArgumentsDigest` and `executableArgumentsDigest` are canonical
  `CoreAgentArgumentAudit` values for execution/audit correlation. Hosts should
  not compare or substitute those fields.
- Batched HITL fails closed when the resume decision count does not match the
  action count, when the resume targets the wrong interrupt ID, when a decision
  does not match the reviewed action identity, when a review config is missing
  or out of order, when allowed decisions are empty, when a decision is not
  allowed for that action, when a non-`edit` decision carries an edited action,
  when a resume payload cannot be decoded, or when an edit targets a tool name
  that the same-index review config did not explicitly allow.
- `CoreAgentDeepEventProjector` joins CoreAgent run events with typed Deep audit
  snapshots into a Swift-native projection for trace/UI/engine consumers. It
  projects run/model/plugin/HITL/tool/native-tool/checkpoint events from
  `CoreAgentRun.events`, filesystem audit events, tool-result offload records,
  subagent audit records, todo snapshots, graph HITL interrupts, and graph
  checkpoint evidence. The projector uses typed event attributes and audit
  structs; it does not parse model-facing sentinel strings, rejection prose,
  offload previews, or conversation-summary text as the durable contract.
  Graph HITL interrupt projection preserves ordered per-action evidence with
  tool-call IDs, action names, and allowed decisions, so multiple calls to the
  same tool in one batch do not collapse into a single tool-name entry.

## Intentional Divergences From Upstream Deep Agents

- Upstream Deep Agents allow unmatched filesystem paths. CoreAgentDeep defaults
  to deny for safety. This is an intentional hardening choice.
- Upstream Deep Agents permissions use broad `read` and `write` operation
  categories. CoreAgentDeep uses explicit per-tool operations because the Swift
  API exposes those operations directly and should not widen permissions
  implicitly.
- Current upstream Deep Agents expose the destructive filesystem tool as
  `delete`. CoreAgentDeep follows that model-facing name in its default
  filesystem surface and keeps `delete_file` only as a compatibility alias.
- Host-local filesystem access is opt-in only. The default shape should remain
  state/checkpoint backed, not direct host disk access.
- Subagents are registered explicitly. There is no implicit inheritance of the
  parent toolset, checkpoint key, transcript, or policy. Parent and child
  governance are separate by construction.
- Subagent names are restricted to parse-safe identifier characters for
  handoff headers and audit keys. The result header and audit record use the
  canonical registry key, not arbitrary subagent-returned text.
- Child checkpoint keys are included in successful task handoffs only when a
  checkpoint store exists and the child run did not report checkpoint failure.
  Failed audited child runs retain the attempted checkpoint key when a child
  checkpoint store was configured, so cleanup/readback has a durable handle.
- Stable upstream LangChain HITL permits an `edit` decision to change both tool
  name and arguments. CoreAgentDeep supports this at the graph-level batched
  HITL boundary only when the review config explicitly authorizes the edited
  target and the executable resolution carries reviewed-versus-executable
  evidence for downstream authorization and receipts. The graph resolver binds
  the reviewed action and allowed target names, but it intentionally does not
  claim to authorize a concrete executable manifest because that authority
  belongs to the host's tool registry and `CoreAgentToolPolicy`. CoreAgentDeep
  still exposes args-only edit at the governed Foundation Models `Tool`
  boundary because native sessions bind a call to a registered tool name before
  `Tool.call` executes. A per-call `CoreAgentDeepHITLPolicy` rule that includes
  edited target allowlists fails closed at runtime instead of silently ignoring
  the setting. The native batch adapter similarly rejects edited target
  allowlists before reviewer work, and it also fails closed if a retargeted
  edit resolution reaches the adapter instead of silently executing the
  original tool with target-tool arguments.
- Stable upstream LangChain HITL batches multiple matching tool calls into one
  interrupt payload. CoreAgentDeep now exposes the graph-level batch
  interrupt/resume primitive and a portable
  `CoreAgentDeepNativeToolBatchHITLAdapter` for hosts that can present an
  ordered set of `CoreAgentToolRequest`s before execution. The adapter reuses
  the graph batch resolver, so interrupt IDs, action digests, allowed
  decisions, and native args-only retarget rejection stay consistent across
  graph and native-tool surfaces.
- Current FoundationModels dynamic-profile lifecycle hooks are observational:
  they can record or throw, but they do not provide a public pre-execution
  batch hook that can edit, reject, or synthesize profile-owned tool output.
  CoreAgent therefore must not claim automatic whole-turn HITL batching for
  profile-owned tools. Dynamic-profile tool observation remains audit-only and
  best effort until Apple exposes a real interception API.
- Conversation-history active compaction is checkpoint-backed by design. The
  active native session is rebuilt only after checkpoint persistence succeeds,
  so a failed checkpoint save does not leave live model context ahead of durable
  readback.
- Active native-session rebuild happens after plugin completion succeeds. A
  completion failure with `.failRun` may leave a compacted checkpoint, matching
  existing checkpoint timing, but it must not rebase the live session or emit
  `transcriptActiveSessionCompacted` for the failed run.
- Conversation-history summaries deliberately do not include raw artifact
  filesystem paths. Raw transcript readback must go through host-owned
  checkpoint artifact metadata and policy. Do not grant model-facing
  `read_file` access to `/conversation_history/**` unless raw transcript
  readback is an intentional, governed product feature.
- Conversation-history artifact paths use opaque hash-derived scope components
  to avoid leaking raw tenant/user/thread identifiers and to avoid collisions
  from lossy path sanitization.
- Todo guard scope is a CoreAgent run ID, not a FoundationModels retry-attempt
  ID. Hosts that opt into `allowsRetryAfterToolInvocation` should expect the
  same one-`write_todos`-attempt-per-run rule to apply across retry attempts in
  that run.
- Custom `turnID` closures are host-managed scopes. CoreAgent lifecycle cleanup
  clears the CoreAgent run-ID scope; hosts that deliberately override the scope
  must call `resetTurnScope(_:)` or provide their own lifecycle boundary for
  custom IDs.

## Testing And Automation Gates

- Deterministic executable coverage uses Swift Testing and
  `RecordedLanguageModel`. These tests are the merge-blocking contract for
  runtime behavior.
- Requested VibeProxy cross-model/multimodal review is available through the
  local VibeProxy app rather than a repo CLI. `cli-proxy-api-plus` listens on
  `127.0.0.1:8318` and `127.0.0.1:8320` with OpenAI-compatible
  `/v1/chat/completions`, `/v1/completions`, and `/v1/models`; LiteLLM also
  runs at `127.0.0.1:4000` using generated VibeProxy routing. Current HITL
  batch adapter artifacts are saved under
  `.work/vibeproxy/2026-07-06-hitl-batch-adapter/` and include text review plus
  image-input smoke for `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. The discovered gateway did not expose an
  audio/video route.
- Focused HITL coverage is in `CoreAgentDeepHITLTests`, using Swift Testing and
  `RecordedLanguageModel` to prove approve/edit/reject/respond behavior,
  allowed-decision enforcement, conditional bypass, execution suppression, and
  intervention events.
- Focused todo coverage is in `CoreAgentDeepTodoTests`, using Swift Testing and
  `RecordedLanguageModel` to prove Deep-compatible status literals, typed state
  replacement, invalid status rejection before mutation, explicit custom
  turn-scope guard behavior, invalid scoped attempts consuming the current turn,
  direct no-scope calls remaining deliberately unguarded, lifecycle cleanup,
  CoreAgent run/model-turn plugin binding, and one write per later CoreAgent
  run.
- Graph-level batched HITL coverage is in `CoreAgentDeepHITLBatchTests`, using
  Swift Testing to prove single-interrupt review payloads, checkpointed resume,
  ordered decision application, interrupt-ID binding, action-identity binding,
  same-index review config validation, disallowed-decision rejection, edit-name
  escalation rejection, empty-decision-set rejection, and decision count
  validation. The same file also covers the native batch adapter: matching
  rules are reviewed once, nonmatching requests pass through as approvals,
  empty decision sets fail before reviewer dispatch, and reviewer decisions are
  bound to the reviewed action identity.
- Graph HITL executable-dispatch coverage is in
  `CoreAgentDeepHITLExecutionTests`, using Swift Testing to prove executable
  target manifest lookup, final `CoreAgentToolPolicy` authorization against the
  executable target instead of the reviewed tool, duplicate/missing manifest
  and malformed-argument fail-closed behavior, deterministic invocation context,
  run/tool-call/manifest/executable-argument-sensitive invocation IDs, canonical
  digest parity with CoreAgent argument audit, stable invocation IDs for
  semantically equivalent executable JSON, action-source passthrough, and redacted
  requested/executable argument evidence.
- Focused subagent coverage is in `CoreAgentDeepTaskTests`, using Swift
  Testing and `RecordedLanguageModel` to prove isolated child sessions,
  deny-by-default child tools, audit records, recursive depth denial, shared
  delegation budgets for nested and same-parent-run calls, plugin budget
  forwarding, direct-call budget sharing, run-completion budget cleanup,
  redacted audit descriptions, and unknown-subagent budget consumption.
- Focused conversation-history coverage is in
  `CoreAgentDeepConversationHistoryTests`, proving small-history no-op,
  full-transcript offload envelope recovery, redacted lossy summaries, compacted
  checkpoint retention, tool-turn boundary safety, reasoning omission from
  prompt-visible summaries, structural tool-call JSON redaction, opaque
  scope/artifact identifiers, model-facing read denial without explicit grants,
  checkpoint-save rollback, checkpoint artifact erasure on reset, file-backed
  checkpoint restore/respond compatibility, active same-session rebuild after
  successful checkpoint persistence, streaming active-session rebuilds, no-store
  manual checkpoint no-rebase behavior, plugin-completion failure ordering,
  rollback preservation for existing deterministic artifacts, invalid artifact
  path cleanup rejection, and checkpoint-removal failure ordering.
- Focused event-projection coverage is in `CoreAgentDeepEventProjectionTests`,
  proving typed projection of CoreAgent run/HITL/native-tool/checkpoint events,
  Deep filesystem/offload/subagent/todo snapshots, and graph interrupt/checkpoint
  evidence without scraping model-facing text.

- `CoreAgentDeepRubricMiddleware` for conditional LLM-as-a-judge grading loops.
  When a rubric is supplied, the middleware runs the CoreAgent session, grades the
  response through a `CoreAgentDeepRubricGrader`, injects a
  `COREAGENT_DEEP_RUBRIC_REVISION_V1` revision prompt on `needsRevision`, and stops
  on `satisfied`, `failed`, `graderError`, or `maxIterationsReached`.
- `CoreAgentDeepDynamicSubagentsPlugin` with model-facing `propose_subagent` and
  `approve_subagent` tools over `CoreAgentDeepSubagentDescriptorGenerator`,
  `CoreAgentDeepSubagentProposalStore`, and digest-bound
  `CoreAgentDeepSubagentApprovedRegistry` registration.
- `CoreAgentDeepRLMOrchestrator` for recursive decomposition/dispatch over the
  existing `task` tool with explicit delegation budgets and typed subtask results.

- `CoreAgentDeepFoundationModelsRubricGrader` for structured Foundation Models
  rubric grading over `CoreAgentSession.respond(generating:)`.
- `CoreAgentDeepFoundationModelsRLMDecomposer` for structured task decomposition
  over registered subagents.
- Rubric and subagent-proposal projection in `CoreAgentDeepEventProjector` using
  typed criterion counts and approval status instead of revision prose.
- `CoreAgentDeepOffloadingEncodableTool` and `CoreAgentDeepToolOffloading.wrapEncodable`
  for serializing non-`String` Foundation Models tool outputs to JSON before applying
  `CoreAgentDeepToolResultOffloader`.
- `CoreAgentDeepSubagentBudget.maximumTotalTokens` and cumulative child `CoreAgentUsage`
  accounting across delegations, with audit-visible `budgetTotalTokensUsed` fields.

- Opt-in `CoreAgentDeepDynamicSubagentsAutoApprovalPolicy` for digest-bound
  proposal auto-registration without a separate `approve_subagent` tool call.

## Not Implemented Yet

- Held-out Engine/Skills feedback gates wired into recursive orchestration and
  rubric grading loops (local orchestration exists; closed-loop optimization gates
  remain host-owned).
- Automatic native-session batching that captures multiple FoundationModels
  tool calls and routes them through the graph-level HITL batch primitive.
- A true FoundationModels-native whole-turn tool interception API that can
  preflight and retarget profile-owned tools before `Tool.call` executes.
