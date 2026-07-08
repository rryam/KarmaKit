# Deep Agents, LangGraph, SkillOpt, and Embedded Engine Task Ledger

Created: 2026-07-05

## Scope

Evaluate draft PR #1 in `24601/coreagent`, research current Deep Agents, LangGraph, SkillOpt, and LangSmith direction, then design and implement the right Swift-native CoreAgent port without brittle provider-specific shortcuts.

## Task Ledger

| ID | Owner | Status | Task | Next verification evidence |
| --- | --- | --- | --- | --- |
| L1 | Codex | complete | Establish live repo, PR, memory, and branch context. | GitHub PR metadata, branch diff, local repo status, Honcho/local memory notes. |
| L2 | Codex + subagents | complete | Audit PR #1 for correctness, architecture fit, tests, and salvageable code. | PR triage captured in `Documentation/DeepAgents-Port-Research-and-Design.md`; PR head fails build/test before execution. |
| L3 | Codex + research agents | complete | Research latest Deep Agents, LangGraph, SkillOpt, LangSmith, and Apple OS 27 Foundation Models patterns from primary sources. | Source-indexed research report with version/date evidence and explicit uncertainty. |
| L4 | Codex | complete_for_slice_1 | Produce a Swift-native design for CoreAgent that maps external concepts onto Foundation Models/CoreAgent contracts. | `Documentation/DeepAgents-Port-Research-and-Design.md`; continued goal execution started Slice 1 from this design. |
| L5 | Codex | complete | Produce implementation plan with TDD slices, disjoint write sets, and verification commands. | `docs/superpowers/plans/2026-07-05-coreagent-deepagents-port.md`. |
| L6 | Codex + reviewers | complete_for_port_foundation | Implement approved slices on a feature branch, using PR #1 code only where it passes triage. | Slices L12–L43 are green, including rubric middleware, dynamic subagents, RLM orchestration, encodable tool offloading, token-aware subagent budgets, WASI/remote interpreter backend boundaries, and the optimization-run orchestrator. Full `swift test` passes 413 tests on `codex/coreagent-graph-runtime` including `CoreAgentAgenticKit` Slice 5 integration at `2705cdf`. Host-owned production gaps remain documented in `Documentation/DeepAgents-Port-Research-and-Design.md` (OS sandbox runners, production WASM/remote hosts, production SkillOpt scheduler, app-hosted Siri/Shortcuts proof). |
| L7 | Codex + reviewers | complete_for_slice_1 | Run adversarial code/design review and resolve valid findings. | Swift reviewer findings were resolved with regression tests; future slices still require fresh adversarial review. |
| L8 | Codex | complete | Update Honcho with durable conclusions learned during the task. | Honcho conclusion `6Fodk38Vm3Ga5h1NRkR_T` recorded with repo/task metadata. |
| L9 | Codex + sidecar researcher | complete_for_slice_2 | Implement Slice 2 `CoreAgentDeep` from current stable Deep Agents behavior. | Todo guard with CoreAgent run/model-turn plugin binding, filesystem tools, large-result offloader, string/encodable tool offloading wrappers, subagent task tool, recursive depth/delegation/token budgets, per-call Deep HITL policy, graph-level batched HITL including explicit-policy tool-name retargets, manifest-bound graph HITL executable dispatch, portable native batch HITL adapter, checkpoint-backed active conversation-history offload/summarization, rubric middleware, dynamic subagents, RLM orchestration, and typed Deep event projection are green. True dynamic-profile pre-execution batching remains unsupported by the current FoundationModels hook surface and is documented under `CoreAgentDeep-Runtime.md` "Not Implemented Yet". |
| L10 | Codex | complete_for_current_slice | Use VibeProxy for exercising CoreAgent against local model/API endpoints when a live model is needed. Use Cursor Composer 2.5 and `agy` Gemini 3.5 Flash for formal adversarial reviews. | User clarified on 2026-07-06 that VibeProxy is not a formal review tool. Historical VibeProxy outputs remain diagnostic/model-exercise artifacts only. Formal review artifacts for L28 are under `.work/reviews/2026-07-06-appintent-os-donation-bridge/`; `agy` Gemini 3.5 Flash re-review passed, while Cursor Composer 2.5 is blocked by missing Cursor auth in this shell. |
| L11 | Codex | complete_for_foundation | Add Apple-platform adapter design and later implementation slices for sandboxed code/computer-use executors, SwiftData checkpointing/snapshotting, SwiftUI store projections, and App Intents/donations. | `CoreAgentApplePlatform` now has SwiftData checkpoint snapshots/records with digest-bound sidecars, a live `ModelContext` checkpoint store, capability/consent action gating, App Intent exposure descriptors, typed App Intent donation records/invalidation, a live SwiftData Engine trace/issue store, live SwiftData graph checkpoint/store persistence, a deterministic in-process interpreter, a consent-gated helper-process interpreter backend boundary, and a main-actor `@Observable` run projection store with focused tests. `CoreAgentAppIntents` now has concrete run AppIntent wrappers, CoreAgent action-gate bridge, and OS `IntentDonationManager` donation/delete bridge. Direct OS sandbox/WASI/remote interpreter runners, raw computer-use executors, and app-hosted `AppIntentsTesting`/Siri/Shortcuts proof remain later slices. |
| L12 | Codex | complete_for_local_foundation | Implement Slice 3 `CoreAgentEngine` local trace ingestion foundation. | `CoreAgentEngine` product/target, finalized-run observer hook, Engine plugin, in-memory store, receipt readback, redaction, project/thread trace queries, issue status filters, and deterministic failed-run issue grouping are green in focused tests. |
| L13 | Codex | complete_for_local_foundation | Implement Slice 4 `CoreAgentSkills` and SkillOpt local foundation. | `CoreAgentSkills` product/target, versioned skill store, curation, typed bounded edit operations, policy-aware validation-gated optimizer, rejected-edit/meta-observation memory, `best_skill.md` export, and held-out harness optimizer are green in focused tests. |
| L14 | Codex + Swift sidecar reviewer + VibeProxy | complete_for_checkpoint_store | Add live SwiftData checkpoint-store adapter over `CoreAgentSwiftDataCheckpointSnapshot` without making SwiftData the canonical checkpoint schema. | Focused Apple tests cover save/load/remove, authority/policy barriers, latest-by-key replacement, hard-delete behavior, corrupted-row fail-closed behavior, duplicate same-scope cleanup, lossless checkpoint validation, portable `CoreAgentCheckpointStore` existential use, and CoreAgentSession restore. VibeProxy found unbounded SwiftData fetch and rollback-scope risks; both were fixed and final local verification passed. |
| L15 | Codex + Swift sidecar reviewer + VibeProxy | complete_for_engine_store | Add live SwiftData Engine trace/issue store for embedded LangSmith-style local persistence. | `CoreAgentSwiftDataEngineStore` is live over SwiftData `ModelContext`; focused Apple tests cover redacted receipt-verifiable trace ingest/readback, project/thread predicates, project+run identity, duplicate replacement/order, subsecond dates, protocol existential use, CoreAgentEnginePlugin integration, issue upsert/reopen/ignore/status filters, trace scope-key integrity, redaction-policy binding, issue provenance union, issue identity-collision fail-closed behavior, and tampered payload fail-closed behavior. VibeProxy final narrow recheck passed on GPT-5.5, Gemini 3.5, and Haiku; full-suite/build/hygiene verification passed. |
| L16 | Codex + Swift sidecar reviewer + VibeProxy | complete_for_graph_store | Add live SwiftData graph checkpoint and graph key/value stores for Apple-platform LangGraph-style persistence. | `CoreAgentSwiftDataGraphCheckpointer` and `CoreAgentSwiftDataGraphStore` are live over SwiftData `ModelContext`; focused Apple tests cover generic Codable checkpoint save/latest/history/ID lookup, parent lineage, thread/namespace isolation, reverse save order, pending writes, corrupt/forged sidecar fail-closed behavior, graph store put/read/remove/keys, duplicate replacement, heterogeneous value rows, portable protocol existential use, deterministic tie ordering, and extreme Date digest hardening. VibeProxy r4 recheck is clean on GPT-5.5; Gemini/Haiku remaining notes were adjudicated as deliberate fail-closed policy or acceptable residual risk. |
| L17 | Codex + sidecar reviewer + VibeProxy | complete_for_deterministic_interpreter | Add the first concrete Apple sandbox/code-interpreter backend without introducing shell or remote execution. | `CoreAgentAppleDeterministicCodeInterpreter` is live as a bounded in-process typed interpreter with action-gate capability checks, no ambient filesystem/network/shell authority, typed stdout/outputs, output-name containment, instruction/input/output/value/state/operand/variable budgets, cancellation, non-finite rejection, program/input audit digests, single-use consent receipt hardening, future-grant rejection, and weak signing-key rejection. Focused and later full-package verification passed; future work is OS sandbox/WASI/helper/remote backends, not this deterministic interpreter slice. |
| L18 | Codex + VibeProxy | complete_for_computer_use_foundation | Add the Apple computer-use execution foundation without granting raw UI automation by default. | `CoreAgentAppleComputerUseExecutor` is live with side-effect-free dry-run planning by contract, approved-plan digest registry, execution consent bound to action ID plus prior dry-run plan digest, no re-plan after consent, missing-capability/consent denial, cancellation handling before/during/after backend calls, bounded request/plan validation, non-removable baseline screenshot evidence, ASCII SHA-256 evidence digest validation, typed action-plan/evidence outputs, and audit metadata over authority boundary, policy version, action ID, mode, plan/evidence digests, and final status. Apple-platform tests pass at 73 tests after VibeProxy hardening. |
| L19 | Codex + VibeProxy | complete_for_donation_invalidation | Add App Intent donation identity and invalidation foundation without concrete App Intent bundles. | `CoreAgentAppIntentDonationRecord`, typed stable donation subjects, record-bound donation consent, and `InMemoryCoreAgentAppIntentDonationStore` are live. Focused Apple-platform tests prove stable non-sensitive donation IDs, rejection of prompt text/tool arguments/transient tool-call subjects, donation-record consent binding, Codable revalidation, and invalidation after erasure/scope changes. VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku; Apple-platform tests pass at 78 tests. |
| L20 | Codex + VibeProxy | complete_for_skillopt_sleep_loop | Add a local SkillOpt-Sleep / recursive optimization loop over typed skill proposals. | `CoreAgentSkillSleepOptimizer`, rollout evidence records, policy-aware bounded edit limits, split-leakage checks, protected slow-update regions, meta-observation memory, duplicate proposal preflight, score/edit preflight, and mutation-free dry-run validation are live. Focused Skills tests pass at 17 tests; VibeProxy final recheck passed on GPT-5.5, Gemini 3.5 full-file rerun, and Haiku. |
| L21 | Codex + VibeProxy | complete_for_app_intents_bridge | Add the first concrete CoreAgent App Intents bridge without bypassing CoreAgent action-gate policy. | `CoreAgentAppIntents` product/target, package marker, OS policy mapper, run-intent catalog, `CoreAgentAppIntentBridge`, runtime environment boundary, and concrete open/pause/continue run intents are live. Focused tests prove descriptor validation, no CoreAgent-mode/process-target conflation, concrete `perform()` routing through the bridge, CoreAgent consent and checkpoint ordering, mutating checkpoint enforcement, denial before host work, cancellation, stable catalog entries, and strict ASCII run-ID validation. VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku. App-hosted `AppIntentsTesting`, Siri/Shortcuts/Spotlight runtime proof, and OS donation-manager bridging remain later slices. |
| L22 | Codex + VibeProxy | complete_for_engine_skillopt_trace_replay | Bridge local Engine traces into SkillOpt rollout evidence and deterministic replay/dream rollout requests without raw payload leakage. | `CoreAgentSkillEngineTraceHarvester`, `CoreAgentSkillReplayGenerator`, replay policy/request types, safe issue/run references, local receipt/finalized-trace filtering, split-exclusion handling, deterministic request IDs, request caps, and privacy regressions are live. Focused Skills tests pass at 21 tests; Engine+Skills focused tests pass at 32 tests; VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku. Typed replay execution is covered by L25; typed model-proposal boundary is covered by L26; concrete FoundationModels proposal backend is covered by L27. |
| L23 | Codex + VibeProxy | complete_for_file_skill_store | Add durable file-backed SkillOpt skill storage and `best_skill.md` export without path traversal, lost updates, or corrupt-store overwrite. | `CoreAgentSkillStore`, `FileCoreAgentSkillStore`, file-backed skill history, optimizer memory resume, hashed skill/memory path components, exclusive version writes, fail-closed corrupted/misplaced rows, corrupt optimizer-memory mutation rejection, safe explicit export filenames, and file-backed optimizer/curator/sleep-loop use are live. Focused Skills tests pass at 27 tests; Engine+Skills focused tests pass at 38 tests; VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku. |
| L24 | Codex + sidecar reviewer + VibeProxy | complete_for_multiobjective_evaluator | Add typed multi-objective evaluator adapters for SkillOpt and harness optimization without collapsing objective evidence into brittle scalar-only fixtures. | `CoreAgentHarnessObjectiveID`, objective directions, weighted objective definitions, objective evaluations, objective-aware audit scores, deterministic eligible-first ranking, typed duplicate/no-eligible errors, minimize normalization, delimiter-safe duplicate detection, and `CoreAgentSkillMultiObjectiveValidationAdapter` are live. Focused Skills tests pass at 32 tests; Engine+Skills focused tests pass at 43 tests; VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku. |
| L25 | Codex + sidecar reviewer + VibeProxy | complete_for_replay_executor | Add typed replay/dream rollout execution from replay requests without raw payload leakage or split bypass. | `CoreAgentSkillReplayOutcome`, `CoreAgentSkillReplayBackend`, `CoreAgentSkillReplayExecutionPolicy`, `CoreAgentSkillReplayExecutor`, duplicate/identity/digest/score/split validation, sanitized verifier feedback, verifier-feedback digests, deterministic evidence IDs, and metadata allowlisting are live. Focused Skills tests pass at 34 tests; Engine+Skills focused tests pass at 45 tests; VibeProxy final recheck passed on GPT-5.5, Gemini 3.5, and Haiku. |
| L26 | Codex + VibeProxy | complete_for_model_proposal_boundary | Add a typed model-proposal backend boundary for SkillOpt without exposing raw evidence/provenance or trusting model candidates. | `CoreAgentSkillModelProposalRequest`, sanitized proposal evidence references, `CoreAgentSkillModelProposalBackend`, `CoreAgentSkillModelProposalCandidate`, and `CoreAgentSkillModelProposalGenerator` are live. The generator strips skill provenance, allowlists evidence metadata, validates digests/scores/duplicate evidence before backend calls, validates backend candidates before sleep-optimizer handoff, sanitizes validation notes, and returns sanitized proposal evidence. Focused Skills tests pass at 36 tests; Engine+Skills focused tests pass at 47 tests; VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku. |
| L27 | Codex + VibeProxy | complete_for_foundationmodels_proposer | Add a concrete FoundationModels-native SkillOpt proposal backend over the L26 typed boundary. | `CoreAgentSkillFoundationModelsProposalBackend` is live over `CoreAgentSession.respond(generating:)` with private `@Generable` structured response DTOs, direct request sanitization, provenance stripping, metadata allowlisting, lowercase digest validation, typed edit mapping, literal-only edit operations, and no store mutation. Focused backend tests pass at 3 tests; Skills tests pass at 39 tests; Engine+Skills pass at 50 focused tests; VibeProxy recheck passed on GPT-5.5, Gemini 3.5, and Haiku. |
| L28 | Codex + agy Gemini 3.5 Flash | complete_for_os_donation_bridge | Add OS `IntentDonationManager` donation/delete bridging without bypassing CoreAgent donation policy. | `CoreAgentRunAppIntentDonationBridge` now gates donation and invalidation through `CoreAgentAppleActionGate`; binds run intent kind/run ID to stable run-outcome donation subjects; records local donation metadata before OS donation and tombstones failed OS donations with `.systemDonationFailed`; returns receipts carrying the OS donation token with digest revalidation; uses an authorized backend request so direct concrete backend calls fail closed for invalid run IDs, non-donatable descriptors, mismatched records, unauthorized requests, and subject/run mismatches; and requires all provided invalidation filters to match before deleting OS donations. Focused ApplePlatform/AppIntents tests pass; full package tests/build/hygiene pass. Formal `agy` Gemini 3.5 Flash re-review passed; Cursor Composer 2.5 review is blocked by missing Cursor auth. |
| L29 | Codex + agy Gemini 3.5 Flash | complete_for_helper_interpreter_boundary | Add a consent-gated helper-process interpreter backend boundary without shipping raw shell or `Process` execution in CoreAgent. | `CoreAgentAppleHelperCodeInterpreter` now validates request IDs, symlink-aware canonical executable allowlists, default blocked shell executable names, workspace-contained working directories, explicit helper network access against sandbox network policy, bounded argv/env/stdin/stdout/stderr/typed outputs, backend exit status, cancellation, program/input digests, and request-bound consent through `.codeInterpreterInvocation`. Backends receive only `CoreAgentAppleAuthorizedHelperCodeInterpreterRequest` after validation and action-gate approval. Focused helper tests, ApplePlatform tests, full package tests, build, and hygiene checks pass. Formal `agy` Gemini 3.5 Flash re-review passed after fixing a symlink canonicalization P2; Cursor Composer 2.5 is blocked by missing Cursor auth and no 1Password account in this shell. |
| L30 | Codex + agy Gemini 3.5 Flash + Cursor Composer 2.5 | complete_for_deep_todo_run_scope | Wire `CoreAgentDeepTodoWriteGuard` to the CoreAgent run/model-turn boundary without parsing provider transcripts. | `CoreAgentDeepTodosPlugin` now exposes `write_todos`, derives the default guard scope from `CoreAgentToolInvocation.current.runID`, rejects a second todo write in the same CoreAgent model run before mutating state, reserves scoped attempts before status validation, preserves explicit host `turnID` overrides for custom scopes, keeps no-scope direct calls deliberately unguarded, and clears completed/failed run scopes through plugin and bare-tool lifecycle cleanup. Cursor Composer 2.5 found the invalid-attempt guard gap; it was fixed and re-reviewed with no blocking findings. `agy` Gemini 3.5 Flash re-review passed after one auth/timeout retry. Final verification passed: `swift test --skip-update --filter CoreAgentDeepTodoTests`, `swift test --skip-update --filter CoreAgentDeepTests`, `swift test --skip-update`, `swift build --skip-update`, `git diff --check`, and targeted trailing-whitespace scan. |
| L31 | Codex + Cursor Composer 2.5 + agy Gemini 3.5 Flash | complete_for_graph_hitl_tool_name_edit | Add graph-level HITL tool-name edit support with explicit edited-target policy and downstream authorization evidence. | `CoreAgentDeepHITLReviewConfig` now carries `allowed_edited_action_names`, the action digest binds that policy, graph retargeted edits return requested/executable identity plus typed resolver-owned `CoreAgentDeepHITLEditedTargetAuthorization`, and the native Foundation Models per-call/batch adapters fail closed on retargeted edits because their `Tool.call` boundary is args-only. Fresh verification passed: `swift test --skip-update --filter CoreAgentDeepHITLBatchTests`, `swift test --skip-update --filter CoreAgentDeepTests`, `swift test --skip-update`, `swift build --skip-update`, `git diff --check`, and targeted trailing-whitespace scan. Cursor Composer 2.5 final re-review reported no remaining P0/P1 blockers in `.work/reviews/2026-07-06-graph-hitl-tool-name-edit/cursor-review-r6.md`. `agy` Gemini 3.5 Flash earlier review reported no blocking findings in `agy-review-r3.md`; final r5/r6 retries were blocked by `authentication failed or timed out` and were not replaced with VibeProxy. |
| L34 | Codex | complete_for_rubric_middleware | Add CoreAgentDeep rubric grading middleware over CoreAgent sessions. | `CoreAgentDeepRubricMiddleware`, typed verdict/evaluation models, revision prompt injection, and focused rubric tests are green. |
| L35 | Codex | complete_for_dynamic_subagents | Wire model-driven subagent proposal and host approval before registry registration. | `CoreAgentDeepDynamicSubagentsPlugin`, `propose_subagent`, `approve_subagent`, proposal store, and focused dynamic-subagent tests are green. |
| L36 | Codex | complete_for_rlm_orchestrator | Add recursive language-model orchestration foundation over existing task delegation. | `CoreAgentDeepRLMOrchestrator`, typed decomposition/subtask results, budget fail-closed behavior, and focused RLM tests are green. |
| L38 | Codex | complete_for_rubric_projection | Project rubric evaluations and subagent proposals into CoreAgentDeep event timeline. | `CoreAgentDeepEventProjector` rubric/subagent-proposal sources, typed criterion counts, and focused projection tests are green. |
| L39 | Codex | complete_for_foundationmodels_rubric_grader | Add FoundationModels-native rubric grader backend. | `CoreAgentDeepFoundationModelsRubricGrader` with structured `@Generable` verdict mapping and focused rubric tests are green. |
| L40 | Codex | complete_for_foundationmodels_rlm_decomposer | Add FoundationModels-native RLM decomposition backend. | `CoreAgentDeepFoundationModelsRLMDecomposer` with subagent allowlist filtering and focused RLM tests are green. |
| L42 | Codex | complete_for_encodable_tool_offload | Add encodable tool offloading wrapper for non-String Foundation Models outputs. | `CoreAgentDeepOffloadingEncodableTool`, `CoreAgentDeepToolOffloading`, JSON serialization helper, and focused offload tests are green. |
| L43 | Codex | complete_for_token_aware_subagent_budget | Add cumulative token-aware subagent budgets and Engine harvest gating. | `CoreAgentDeepSubagentBudget.maximumTotalTokens`, child usage accounting, audit token fields, `CoreAgentUsage.totalTokenCount`, `CoreAgentSkillOptimizationRunHarvestConfig.maximumTotalTokens`, and focused task/offload tests are green. |
| L41 | Codex | complete_for_dynamic_subagent_auto_approval | Add opt-in digest-bound dynamic subagent auto-approval policy. | `CoreAgentDeepDynamicSubagentsAutoApprovalPolicy`, `CoreAgentDeepSubagentProposalRegistrar`, and focused auto-approval test are green. |
| L37 | Codex | complete_for_remote_interpreter_boundary | Add consent-gated remote code-interpreter backend boundary. | `CoreAgentAppleRemoteCodeInterpreter` with endpoint allowlists, network-policy gating, authorized backend dispatch, and focused Apple-platform tests are green. |
| L45 | Codex | complete_for_agentic_kit | Add optional CoreAgentAgenticKit integration product wiring Graph + Deep + Skills + Engine. | `CoreAgentAgenticKit` product/target, filesystem tool wiring, todos/subagents/engine plugin session factory, import smoke tests, and recorded end-to-end sample with todo/filesystem/subagent/trace ingestion are green in `CoreAgentAgenticKitTests`. Full `swift test` passes 413 tests. |
| L44 | Codex | complete_for_wasi_interpreter_boundary | Add consent-gated WASI/WebAssembly interpreter backend boundary. | `CoreAgentAppleWASICodeInterpreter` with module allowlists, workspace containment, request/input digests, authorized backend dispatch, and focused Apple-platform tests are green. |
| L33 | Codex | complete_for_optimization_run_orchestrator | Add typed SkillOpt optimization run orchestration over harvest/replay/proposal/sleep phases. | `CoreAgentSkillOptimizationRunExecutor` wires optional Engine harvest, replay generation/execution, model-proposal generation, and sleep optimization with deduped evidence, ordered phase records, and fail-closed validation for harvest-without-store and proposal-without-target cases. Full `swift test` passes after scripted-model bridge unblocks FoundationModels SDK/runtime mismatch in CoreAgentTests. |
| L46 | Codex + explorer sidecar | complete_for_meta_evolution_frontier_selector | Add MetaSkill-Evolve/RQGM-style RSI frontier selection before SkillOpt sleep mutation, and add arXiv 2607.05297 to RSI assessment inputs. | `CoreAgentSkillMetaEvolutionFrontierSelector`, optional optimization-run `frontierSelected` phase/report IDs, focused Swift Testing coverage, and documentation of the arXiv 2607.05297 mapping. |
| L47 | Codex + explorer sidecar | complete_for_meta_skill_branch_state | Add typed branch-local meta-skill state for arXiv 2607.05297 RSI inclusion assessment. | `CoreAgentSkillMetaSkillBranchSnapshot`, `CoreAgentSkillMetaSkillEvolutionRecord`, optimizer-memory persistence, `metaSkillStateRecorded` / `metaSkillEvolved` run phases, frontier-vs-sleep rejection buckets, corrupt/legacy file-store coverage, and focused Swift Testing coverage are green. Scheduler cadence, branch allocation, and recursion budgets remain host-owned. |
| L48 | Codex + explorer sidecar | complete_for_graph_node_cache | Add Swift-native LangGraph-style node cache policy/runtime. | `CoreAgentGraphCacheKey`, `CoreAgentGraphCachePolicy`, `CoreAgentGraphNodeCache`, `InMemoryCoreAgentGraphNodeCache`, `CoreAgentGraphStreamEvent.nodeCacheHit`, `CoreAgentStateGraph.addNode(_:cachePolicy:operation:)`, and `compile(..., cache:)` are live. Focused graph cache tests and `CoreAgentGraphTests` pass; cached updates still flow through reducer/checkpoint/stream semantics. Later L49 covers command/state-update parity; executable subgraphs and deferred nodes remain open parity gaps. |
| L49 | Codex + explorer sidecar | complete_for_graph_command_state_update | Add Swift-native LangGraph-style command node outputs and state surgery. | `CoreAgentGraphNodeOutput.command(update:goto:)`, declared command routes, `CoreAgentGraphStreamEvent.command`, command pending-write continuation metadata, `CoreAgentGraphStateUpdate`, `CoreAgentGraphTaskID`, `CoreAgentCompiledGraph.updateState`, and `bulkUpdateState` are live. Focused `graphCommand` tests and `CoreAgentGraphTests` pass. LangGraph `Send`, parent-graph command routing, executable subgraphs, and deferred nodes remain open parity gaps. |
| L50 | Codex + explorer sidecar | complete_for_deep_filesystem_tool_surface | Align CoreAgentDeep filesystem tools with current Deep Agents 0.7 model-facing surface. | `CoreAgentDeepFilesystemToolSurface`, allowlist/excluded-tools validation, `CoreAgentDeepFilesystemToolCapabilities`, canonical `CoreAgentDeepDeleteTool` (`delete`), compatibility-only `CoreAgentDeepDeleteFileTool` (`delete_file`), and AgenticKit surface configuration are live. Verification passed: `swift test --skip-update --filter CoreAgentDeepFilesystemTests`, `swift test --skip-update --filter 'CoreAgentAgenticKitTests|CoreAgentDeepOffloadTests'`, `swift test --skip-update --filter 'CoreAgentDeepTests|CoreAgentAgenticKitTests'`, `swift test --skip-update`, `swift build --skip-update`, scoped `swift-format lint --strict`, `git diff --check`, and touched-file size check. LangGraph `Send`, parent-graph command routing, executable subgraphs, and deferred nodes remain open parity gaps. |
| M0 | Droid worker 50b77dc8 | complete_for_baseline_land | Establish the committed regression floor for the already-authored L49/L50 and repo-readiness baseline before new feature work. | 2026-07-07 verification: `swift build --build-tests` passed; `swift test` passed with 442 Swift Testing tests and 0 failures in this worker environment; `.env` and `.env.local` remain git-ignored while `.env.example` is committed as the template; `git grep --untracked` found no high-confidence real key/token patterns; stacked PR targets `origin/main`, and PR #1 remains untouched. |
| L32 | Codex + explorer sidecar + Cursor Composer 2.5 + agy Gemini 3.5 Flash | complete_for_graph_hitl_executable_dispatch | Add manifest-bound graph HITL executable dispatch after the L31 resolver boundary. | `CoreAgentDeepHITLExecutableActionExecutor` now looks up the executable target manifest by `executableName`, rejects duplicate/missing manifests, parses requested and executable JSON before policy/backend work, authorizes the executable target `CoreAgentToolRequest` through `CoreAgentToolPolicy`, runs a host backend under `CoreAgentToolInvocation.current`, derives deterministic invocation IDs from run ID + graph tool-call ID + executable name + manifest digest + canonical executable argument digest, and returns action source, reviewed action identity, edited-target authorization, canonical requested/executable digests, and redacted JSON evidence. Cursor and Agy both found the raw-JSON digest mismatch; the executor now uses `CoreAgentArgumentAudit.digest`, `CoreAgentArgumentAudit` canonicalizes JSON object/array shape before hashing, source is exposed for host receipt mapping, and regressions cover malformed requested args, approve/edit source, digest parity, run/tool-call/manifest identity sensitivity, and semantically equivalent executable JSON stability. Cursor r3 and Agy r2 re-reviews reported no remaining P0/P1 blockers in `.work/reviews/2026-07-06-graph-hitl-executable-dispatch/`; Cursor P2 host-integration hardening notes around digest-domain distinction and canonical-equivalent executor coverage were addressed with docs/tests. Fresh verification passed: `swift test --skip-update --filter CoreAgentDeepHITLExecutionTests` (14 tests), `swift test --skip-update --filter argumentAuditDigestCanonicalizesJSONObjects`, `swift test --skip-update --filter CoreAgentDeepTests` (129 tests), `swift test --skip-update`, `swift build --skip-update`, `git diff --check`, and targeted trailing-whitespace scan. |
| L51 | Droid worker f9c50277 | complete_for_refactor_apple_platform | Split `CoreAgentApplePlatform` into cohesive same-target source files without test call-site edits. | `CoreAgentApplePlatform.swift` is now a 2-line umbrella and the largest new Apple-platform source is `CoreAgentSwiftDataEngineStore.swift` at 726 lines. Verification passed: `swift build --build-tests`, `swift test --filter CoreAgentApplePlatform` (87 tests), full `swift test`, scoped `swift-format lint --strict --recursive Sources/CoreAgentApplePlatform`, and `git diff --check`. `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh` no longer reports `Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift`; it still exits 1 on known M1 follow-up oversized files including `CoreAgentApplePlatformTests.swift`, `CoreAgentSkills.swift`, and other pending refactor targets. |
| L52 | Droid worker 54257164 | complete_for_refactor_skills | Split `CoreAgentSkills` into cohesive same-target source files without test call-site edits. | `CoreAgentSkills.swift` is now a 1-line umbrella and the largest new Skills source is `CoreAgentSkillOptimizer.swift` at 663 lines. Verification passed: `swift build --build-tests`, `swift test --filter CoreAgentSkillsTests` (55 tests), full `swift test` (442 Swift Testing tests, 0 failures), scoped `swift-format lint --strict` for split Skills files, public declaration/member line comparison matched 448 lines, and `git diff --check`. `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh` no longer reports any `Sources/CoreAgentSkills/*.swift`; it still exits 1 on known pending M1 follow-up oversized source and test files. |
| L53 | Droid worker 375f5527 | complete_for_refactor_test_files | Split every remaining oversized Swift source and test file across the same targets without deleting or merging test cases. | Before: 14 files over 800 lines, largest tests `CoreAgentApplePlatformTests.swift` 4392 and `CoreAgentSkillsTests.swift` 3312, largest sources `CoreAgentSession.swift` 1909 and `CoreAgentDeepTask.swift` 1202. After: all refactored files are <=800 lines, with largest split files `CoreAgentDeepTaskTests.swift` 774, `CoreAgentDeepConversationHistoryTests.swift` 764, `CoreAgentSkillsTests.swift` 722, `CoreAgentSession.swift` 602, and source splits `CoreAgentRunAppIntentDonation.swift` 574 / `SQLiteCoreAgentMemoryStore.swift` 512 / `CoreAgentDeepTaskTool.swift` 441. Verification passed: baseline `swift test` counted 442 tests; final `swift build --build-tests` passed; final `swift test` passed with 442 Swift Testing tests; `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh` passed; touched-file `swift-format lint --strict` passed; `git diff --check` passed. |
| L54 | Droid worker 5bf0f4b0 | complete_for_enforce_800_capstone | Make the real 800-line readiness gate enforceable and extract graph runtime context headroom for M2 Send. | `CoreAgentGraphRuntimeContext` moved from `CoreAgentStateGraph.swift` into `CoreAgentGraphRuntimeContext.swift` with optional `taskID`; `CoreAgentStateGraph.swift` dropped from 800 to 729 lines and the new context file is 74 lines. `.github/workflows/agent-readiness.yml` now sets `COREAGENT_MAX_FILE_LINES: 800`. Legacy full-repo swift-format violations were mechanically cleaned across the offending files. Verification passed: `swift build --build-tests`; `swift test` counted 442 Swift Testing tests; `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh`; `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`; `git diff --check`; diff scan found no added `@unchecked Sendable` or `@preconcurrency`. |
| L55 | Droid worker d75344d9 | complete_for_graph_send | Add Swift-native LangGraph `Send` semantics to `CoreAgentGraph`. | Red evidence: `swift test --skip-update --filter CoreAgentGraphSendTests` failed before implementation because `CoreAgentGraphSend`, `addSendEdges`, command `sends`, stream `.send`, checkpoint `nextTasks`, and `undeclaredSendTarget` were missing. Green evidence: `swift test --skip-update --filter CoreAgentGraphSendTests` passed 7 tests, and `swift test --skip-update --filter CoreAgentGraphTests` passed 60 graph tests after implementation. Final validation also ran full `swift test`, focused graph filters without `--skip-update`, `swift build --build-tests`, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`, `git diff --check`, and `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh`. |
| L56 | Droid worker 5d13e7d4 | complete_for_graph_subgraphs | Add first-class executable subgraphs to `CoreAgentGraph`. | Red evidence: `swift test --filter CoreAgentGraphSubgraphTests` failed before implementation because `addSubgraph`, nested subgraph checkpoint namespaces, and `CoreAgentGraphStreamEvent.subgraph` did not exist. Green evidence: `swift test --filter CoreAgentGraphSubgraphTests` passed 3 tests, and `swift test --filter CoreAgentGraphTests` passed 63 graph tests after implementation. Final validation also ran full `swift test`, `swift build --build-tests`, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`, `git diff --check`, and `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh`. |
| L57 | Droid worker 760f273d | complete_for_graph_parent_routing | Add parent-scoped command routing from executable subgraphs into the parent graph. | Red evidence: `swift test --filter CoreAgentGraphParentCommandTests` failed before implementation because `CoreAgentGraphEndpoint.parent` and `CoreAgentGraphRuntimeError.undeclaredParentCommandTarget` were missing. Green evidence: `swift test --filter CoreAgentGraphParentCommandTests` passed 3 tests, and `swift test --filter CoreAgentGraphTests` passed 66 graph tests after implementation. Final validation also ran full `swift test` (455 Swift Testing tests), `swift build --build-tests`, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`, `git diff --check`, and `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh`. |
| L58 | Droid worker 1c67876c | complete_for_graph_deferred_nodes | Add deferred node scheduling to `CoreAgentGraph`. | Red evidence: `swift test --filter CoreAgentGraphDeferTests` failed before implementation because `addNode(_:defer:...)` was missing. Green evidence: `swift test --filter CoreAgentGraphDeferTests` passed 3 tests, and `swift test --filter CoreAgentGraphTests` passed 69 graph tests after implementation. Final validation also ran full `swift test` (458 Swift Testing tests), `swift build --build-tests`, `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`, `git diff --check`, and `COREAGENT_MAX_FILE_LINES=800 scripts/check-large-files.sh`. |
| L59 | Droid worker 234d0da9 | complete_for_engine_closed_loop | Complete the embedded Engine/Skills closed-loop feedback gate without autonomous mutation. | Red evidence: `swift test --filter enginePluginProducesNoAutonomousMutation` and `swift test --filter rubricVerdictGatesEngineSkillsFeedbackLoop` failed before implementation because `CoreAgentSkillProposedFixArtifact`, `CoreAgentSkillHeldoutValidationProof`, `requiresHeldoutValidationProof`, and `CoreAgentAgenticKitFeedbackLoop` were missing. Green evidence: both named filters passed, and the combined acceptance filter for ENGINE-01 through ENGINE-05 passed 6 tests covering finalized run ingestion, typed issue clustering, fail-closed harvesting, no autonomous mutation, and rubric verdict to Engine issue to gated Skills proposal linkage. |

## Current Facts

- Local repo: `/Users/basitmustafa/Documents/GitHub/coreagent`
- Current branch at ledger creation: `main`
- Current working branch: `codex/coreagent-graph-runtime`
- Current base HEAD: `6fbd7ed`
- Target draft PR: `https://github.com/24601/coreagent/pull/1`
- Target PR head: `origin/cursor/deepagents-langgraph-port-1b12` at `c830678`
- Working tree at ledger creation: clean

## Evidence Log

- `swift build --skip-update` on `/tmp/coreagent-pr1-audit` failed before tests could run: first at `CoreAgentGraphStateGraph.swift:227`, then after temporary forensic fixes at duplicate `Codable` conformance and private-member access errors in `CoreAgentGraphStateGraph`.
- `swift test --skip-update` on `/tmp/coreagent-pr1-audit` failed at the same compile boundary before added tests executed.
- `swift test --skip-update` on repo `main` passed 63 Swift Testing tests after building.
- `swift build --skip-update` on repo `main` completed successfully.
- `gh pr view 1 --repo 24601/coreagent` shows the PR is draft, open, and has unresolved Gemini Code Assist review findings.
- `uv run deep-research/scripts/onboard.py --check` found no Gemini/Google API key configured; `op whoami` reported no 1Password account configured in this shell.
- PyPI current package metadata checked again on 2026-07-06: `deepagents 0.6.12`,
  `langgraph 1.2.8`, `langsmith 0.9.8`.
- `git ls-remote https://github.com/microsoft/SkillOpt.git` shows SkillOpt `v0.2.0` at HEAD.
- Three delegated reviews completed:
  - Repository/PR audit verdict: do not merge PR #1; rewrite almost all implementation and tests.
  - External research verdict: port Deep Agents/LangGraph/SkillOpt/LangSmith contracts, not Python API shapes.
  - Swift/iOS review verdict: PR #1 flattens native Foundation Models transcript/tool state and has dead middleware/engine paths.
- Research and design brief created at `Documentation/DeepAgents-Port-Research-and-Design.md`.
- TDD implementation plan created at `docs/superpowers/plans/2026-07-05-coreagent-deepagents-port.md`.
- Adversarial document review found under-specified store/time-travel, parallel reducer determinism, conditional routing, dynamic-profile sensitive-tool, filesystem permission, Engine redaction, subagent audit, and SkillOpt leakage/replay requirements. The design and plan were patched to make those explicit before seeking implementation approval.
- Branch `codex/coreagent-graph-runtime` created from `main` at `6fbd7ed`.
- Added `CoreAgentGraph` product/target and `CoreAgentGraphTests`.
- TDD red/green evidence:
  - `CoreAgentGraphSmokeTests` first failed because package product `CoreAgentGraph` did not exist, then passed after adding the target and `CoreAgentGraphNodeID`.
  - `CoreAgentGraphCompileTests` first failed on missing `CoreAgentStateGraph`/compile errors, then passed after adding compile validation.
  - `CoreAgentGraphExecutionTests` first failed on missing `invoke`/conditional runtime API, then passed after adding deterministic execution.
  - `CoreAgentGraphStreamingTests` first failed on missing `CoreAgentGraphStreamEvent`/`stream`, then passed after adding typed stream events.
  - `CoreAgentGraphCheckpointTests` first failed on missing checkpoint/checkpointer APIs, then passed after adding in-memory checkpointing.
- `swift test --skip-update --filter CoreAgentGraph` passed 21 graph tests.
- Swift reviewer found six valid issues in the initial `CoreAgentGraph` diff:
  invalid closed range on recursion-limit resume, scoped checkpoint corruption
  for duplicate public IDs, silent parallel-update data loss with the default
  reducer, selectorless conditionals compiling before failing at runtime,
  non-monotonic resumed stream steps, and an incomplete remaining-work ledger.
- Added regression coverage and implementation for each reviewer finding:
  typed recursion-limit resume error, scoped checkpoint history, explicit
  reducer/channel requirement for parallel fanout, compile-time selector
  validation, restored stream step numbers, and updated durable ledger status.
- Added `CoreAgentGraphStore` protocol and in-memory actor with namespace/key
  isolation, stable key listing, and scoped deletes.
- Added Codable resume commands, typed interrupts, proof-visible interrupt
  stream events, checkpointed resume points, deterministic interrupt ordering,
  and stable interrupt IDs for idempotency markers.
- Added pending-write recovery for failed parallel super-steps; successful
  earlier node writes are checkpointed, applied once on resume, and not replayed.
- Added `CoreAgentGraphChannel` reducer helpers for explicit overwrite, append,
  graph-channel initialization, and native Foundation Models
  `[Transcript.Entry]` history append.
- Added runtime context metadata and custom stream events; added task failure
  stream events before thrown node errors.
- Added `Documentation/CoreAgentGraph-Runtime.md` to state implemented graph
  behavior and explicitly exclude Deep/Skill/Engine product APIs from Slice 1.
- `swift test --skip-update --filter CoreAgentGraph` passed 41 graph tests.
- `swift test --skip-update` passed all current tests: 45 CoreAgent tests,
  16 CoreAgentMemory tests, 2 memory integration tests, and 41 graph tests.
- `swift build --skip-update` completed successfully.
- `git diff --check` completed successfully.
- Honcho conclusion `6Fodk38Vm3Ga5h1NRkR_T` recorded Slice 1 scope,
  verification, PR #1 rejection, and remaining Deep/Skill/Engine slices.
- Sidecar source-drift audit confirmed Slice 2 should target stable
  `deepagents==0.6.12` (2026-06-25, commit `7e700652`), `langgraph 1.2.7`
  (2026-06-30, commit `5931a5f`), and `langchain==1.3.11` todo/HITL source
  (2026-06-22, commit `83e8249`) rather than Deep Agents `0.7.0a*`
  prerelease tags.
- Added `CoreAgentDeep` product/target and `CoreAgentDeepTests`.
- Added typed todo state, `CoreAgentDeepTodoStore`, and model-facing
  `write_todos` tool with exact status literals `pending`, `in_progress`, and
  `completed`; invalid raw model status strings are rejected before mutating
  typed state.
- Added scoped `CoreAgentDeepTodoWriteGuard` so `write_todos` can reject a
  second write in the same supplied turn scope.
- Added `CoreAgentDeepTodosPlugin` so a CoreAgent session can expose
  `write_todos` and bind the guard to the current CoreAgent run/model-turn
  scope through `CoreAgentToolInvocation.current.runID`, without parsing
  provider transcript payloads.
- Added `CoreAgentDeepToolResultOffloader` for oversized non-built-in tool
  results. It writes full content to deterministic governed filesystem paths
  under `/large_tool_results/<tool_call_id>`, returns a compact recovery message
  with head/tail preview, skips built-in filesystem/todo tools, and sanitizes
  tool-call IDs before path use. The default threshold follows stable Deep
  Agents' `20_000` token limit approximation (`80_000` characters), and tests
  assert durable recovery semantics instead of exact preview copy.
- Added `CoreAgentDeepOffloadingTool` wrapper for Foundation Models tools that
  return `String`, preserving wrapped tool identity/schema while applying
  `CoreAgentDeepToolResultOffloader`.
- Added `CoreAgentDeepFilesystemBackend`, safe state-backed
  `CoreAgentDeepStateFilesystem`, opt-in host-local `CoreAgentDeepLocalFilesystem`,
  default-deny first-match filesystem permissions, canonical containment,
  symlink/parent/`~` escape rejection, and audit-visible allow/deny events.
- Added model-facing filesystem tools: `read_file`, `write_file`, `ls`, and
  the original CoreAgent-specific `delete_file` alias. L50 later aligned the
  default model-facing destructive tool name to current Deep Agents `delete`.
- Added `edit_file`, `glob`, and `grep` with exact replacement semantics,
  permission-filtered file discovery/search, literal grep matching, and
  `files_with_matches`/`content`/`count` output modes.
- Resolved security review findings by requiring explicit operation grants
  instead of implicit `read`/`write` aliases and by recording root-escape
  attempts as denied audit events.
- Added `Documentation/CoreAgentDeep-Runtime.md` to state implemented behavior,
  intentional upstream divergences, and remaining Slice 2 contracts.
- `swift test --skip-update --filter CoreAgentDeep` passed 25 Deep tests.
- `swift test --skip-update` passed the full package suite after Slice 2:
  45 CoreAgent tests, 16 CoreAgentMemory tests, 2 memory integration tests,
  41 CoreAgentGraph tests, and 25 CoreAgentDeep tests.
- `swift build --skip-update` completed successfully after Slice 2.
- `git diff --check` completed successfully; direct trailing-whitespace check
  over untracked new files completed successfully.
- Security sidecar found valid issues in implicit operation aliases and missing
  escape audit events. Both were fixed with regression tests. The sidecar doc
  finding was stale against the local docs after the `edit_file`/`glob`/`grep`
  update, but docs were also revised to state explicit per-tool permissions.
- Added `CoreAgentToolInvocation.current` task-local context so governed tools
  can read CoreAgent's existing parent run ID, tool invocation ID, tool name,
  and manifest digest without parsing provider transcripts.
- Added `CoreAgentDeepTaskTool` with model-facing name `task`, typed
  `description`/`subagent_type` arguments, explicit subagent registry,
  unavailable-subagent messaging, final-only parent handoff, and audit records.
- Added `CoreAgentDeepSessionSubagent`, which creates a fresh child
  `CoreAgentSession` per task call and uses isolated child checkpoint keys by
  default.
- Added `CoreAgentDeepSubagentsPlugin` to expose the `task` tool through the
  existing `CoreAgentSessionPlugin` surface.
- `swift test --skip-update --filter CoreAgentDeepTask` passed 6 task/subagent
  tests covering manifest shape, isolated child session, parent checkpoint
  exclusion of child intermediate transcript content, concurrent child
  checkpoint isolation, plugin exposure, failed-run audit, and unknown-subagent
  behavior.
- Swift/security review found valid issues in the first subagent task
  implementation: forgeable parent invocation context, child tool allow-all
  defaults, failed audit records dropping attempted checkpoint keys, raw error
  text in audit records, denied task attempts missing audit records,
  nonexistent checkpoint keys in successful handoffs, and noncanonical
  subagent names in result metadata.
- Fixed those findings by making CoreAgent tool invocation task-local storage
  package-set/read-only-public, making `CoreAgentDeepSessionSubagent` child
  tools deny-by-default, retaining failed child checkpoint keys when a store is
  configured, redacting and bounding audit error descriptions, adding denied
  audit status, only advertising successful checkpoint keys when durable, and
  using parse-safe canonical registry keys in result headers/audit records.
- `swift test --skip-update --filter CoreAgentDeepTask` passed 14 task/subagent
  tests after review fixes, including failed checkpoint-persistence audit
  behavior.
- `swift test --skip-update --filter CoreAgentDeep` passed 39 Deep tests after
  review fixes.
- Security re-review reported the prior task-slice findings resolved:
  forgeable invocation context, child allow-all defaults, failed audit
  checkpoint loss, raw error audit leakage, and denied task audit gaps.
- Swift/iOS re-review reported the prior checkpoint-key and canonical-subagent
  metadata findings resolved, including the failed checkpoint-persistence edge
  case.
- `swift test --skip-update` passed the full package suite after the latest
  task-slice fixes.
- `swift build --skip-update` completed successfully after the latest
  task-slice fixes.
- `git diff --check` and the direct trailing-whitespace scan over untracked
  files completed successfully after the latest task-slice fixes.
- Local VibeProxy discovery corrected the earlier CLI-only blocker:
  `cli-proxy-api-plus` listens on `127.0.0.1:8318` and `127.0.0.1:8320`;
  LiteLLM runs at `127.0.0.1:4000`; direct working model IDs include
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`.
- Xcode 27 SDK interface checks confirm platform adapter primitives exist:
  SwiftData exposes `ModelContainer`, `ModelContext`, `DataStoreSnapshot`, and
  `DefaultSnapshot`; App Intents exposes OS 27 `allowedExecutionTargets`,
  `donate()`, `IntentDonationManager`, and `RelevantIntentManager`.
- Added Apple platform adapter plan covering capability-scoped sandbox/code
  interpreters/computer use, SwiftData checkpoint/snapshot stores, SwiftUI
  `@Observable` projection stores, and App Intent/donation entry points.
- Expanded the Apple platform adapter plan into a concrete implementation
  order: SwiftData persistence first, then bounded sandbox/code interpreters,
  then separate computer-use automation, SwiftUI projections, and App
  Intents/donations. The plan now explicitly rejects SwiftData as the canonical
  checkpoint schema, generic "tools enabled" automation switches, SwiftUI view
  state as run truth, and App Intent bypasses around HITL/authorization/audit.
- Tightened the platform plan so interpreter support is tiered
  (deterministic in-process, WASI/WebAssembly, then opt-in helper/remote
  execution), computer use is consent-gated separately from code execution,
  SwiftData stores policy metadata rather than inferring authority from row
  shape, SwiftUI projections avoid closure-valued custom environment dispatch,
  and long-running App Intents checkpoint before expensive work and observe
  cancellation.
- HITL sidecar currentness check confirmed stable surfaces:
  `deepagents==0.6.12` at commit `7e700652`, `langchain==1.3.11` at commit
  `83e82492`, and `langgraph==1.2.7` at commit `5931a5f0`. Upstream HITL
  uses `interrupt_on`, `allowed_decisions`, batched `action_requests` and
  `review_configs`, and decision types `approve`, `edit`, `reject`, and
  `respond`.
- Added additive `CoreAgentToolInterventionPolicy` and
  `CoreAgentToolInterventionDecision` before the existing authorization and
  execution path. Existing `CoreAgentToolPolicy` remains source-compatible.
- Added CoreAgent intervention events for approve/edit/reject/respond/cancel/
  failure outcomes so HITL decisions are receipt-visible.
- Added `CoreAgentDeepHITLPolicy`, `CoreAgentDeepHITLRule`,
  `CoreAgentDeepHITLReviewer`, review bundle types, and typed decision/error
  models. Current Swift policy supports args-only edit at the governed native
  `Tool.call` boundary; tool-name edits remain graph/deep-runtime work and
  require explicit edited-target authorization/audit proof.
- TDD evidence for HITL:
  `swift test --skip-update --filter CoreAgentDeepHITL` first failed because
  HITL public types and the intervention hook were missing, then passed 6 HITL
  tests after implementation and wrapper-aware error assertion adjustment.
- Security/Swift review found valid HITL audit issues: synthetic reject/respond
  outputs were indistinguishable from real native tool output, edited arguments
  were hash-only in the audit trail, predicate rules were evaluated twice, and
  precheck failures could be mislabeled as intervention failures.
- Added regressions and fixes for those findings: native tool-output events now
  carry `output_source` and CoreAgent invocation IDs for synthetic HITL output;
  edited calls carry redacted requested/executed argument JSON and digests, and
  authorization/denial events carry the edited argument source; HITL predicates
  are evaluated once per governed call; precheck failures do not emit false
  intervention outcome events.
- `swift test --skip-update --filter CoreAgentDeepHITL` passed 10 HITL tests
  after the review fixes.
- Added `CoreAgentDeepEventProjector` and typed projection payloads for
  CoreAgent run/model/plugin/HITL/tool/native-tool/checkpoint events,
  filesystem audit events, tool-result offloads, subagent audit records, todo
  snapshots, graph HITL interrupt bundles, and graph checkpoint evidence.
  Projection uses typed event attributes/audit structs and intentionally avoids
  parsing model-facing sentinel strings, offload previews, rejection prose, or
  conversation-summary text.
- `swift test --skip-update --filter CoreAgentDeepEventProjection` first failed
  on missing projection API/types after the test file was moved into the real
  `CoreAgentDeepTests` target, then passed 3 projection tests after
  implementation.
- Swift/iOS review found a valid event-projection bug: graph HITL interrupt
  projection keyed allowed decisions by action name, collapsing two calls to the
  same tool in one batch. Fixed by projecting ordered per-action records with
  tool-call IDs, action names, and allowed decisions plus a derived
  `allowedDecisionsByToolCallID` lookup.
- Swift/iOS re-review found the first lookup fix stored redundant Codable
  state that could diverge from ordered actions after decode. Fixed by making
  the lookup computed and adding encode/decode coverage proving the lookup is
  not serialized and is derived from actions after decode.
- Re-review confirmed both event-projection findings resolved with no new
  Critical/P1/P2 issues in the fix.
- TDD evidence for graph-level batched HITL:
  `swift test --skip-update --filter CoreAgentDeepHITLBatch` first failed on
  missing `CoreAgentDeepHITLBatchResume`,
  `CoreAgentDeepHITLBatchResolver`, `CoreAgentDeepHITLBatchResolution`,
  `CoreAgentDeepHITLError.decisionCountMismatch`, and
  `CoreAgentGraphRuntimeContext.requestDeepHITLReview`.
- Added `CoreAgentDeepHITLBatchResume`, ordered
  `CoreAgentDeepHITLBatchResolver`, executable/synthetic resolution types, and
  `CoreAgentGraphRuntimeContext.requestDeepHITLReview`. The helper interrupts
  once with a `CoreAgentDeepHITLReviewBundle` or resolves one ordered resume
  decision per action request.
- `swift test --skip-update --filter CoreAgentDeepHITLBatch` passed 4 batched
  HITL tests after implementation.
- `swift test --skip-update --filter CoreAgentDeepHITL` passed 14 HITL tests
  across per-call governed-tool policy and graph-level batched HITL.
- Security and Swift reviewers found valid batch HITL issues: positional resume
  decisions were not bound to reviewed action identity, resume commands were
  not scoped to interrupt ID, edit decisions could change to arbitrary tool
  names, and duplicate action names could inherit the wrong review config.
- Added regressions and fixes for those findings: batch resume now carries an
  interrupt ID; every decision carries the reviewed tool-call ID plus an action
  digest over the action request and same-index review config; review config
  count/order is enforced; duplicate action IDs and duplicate resume decisions
  are rejected; and edit decisions may change arguments only, not the reviewed
  tool name.
- Swift re-review found a valid remaining issue: the default batch-HITL
  interrupt ID could collide across independent graph nodes. Added
  `CoreAgentGraphRuntimeContext.nodeID`, scoped node operations to their active
  node ID, and made `requestDeepHITLReview` derive default IDs as
  `coreagent-deep-hitl/<node-id>`.
- `swift test --skip-update --filter CoreAgentDeepHITLBatch` passed 10 batched
  HITL tests after review fixes.
- `swift test --skip-update --filter default` passed the node-scoped default
  review-ID regression after the graph context fix.
- `swift test --skip-update --filter CoreAgentGraph` passed 41 graph tests
  after adding node IDs to runtime context.
- `swift test --skip-update --filter CoreAgentDeepHITL` passed 20 HITL tests
  after review fixes.
- Added `CoreAgentDeepNativeToolBatchHITLAdapter`,
  `CoreAgentDeepHITLBatchReviewer`, and
  `CoreAgentDeepHITLBatchReviewRequest` for hosts that can present ordered
  native `CoreAgentToolRequest` batches before execution. The adapter reviews
  only matching interrupt rules once, passes nonmatching tools through as
  approvals, maps approve/edit/reject/respond back to
  `CoreAgentToolInterventionDecision`, and reuses
  `CoreAgentDeepHITLBatchResolver` for interrupt ID, action digest, ordering,
  allowed-decision, and args-only edit validation.
- TDD evidence for the native batch adapter:
  `swift test --skip-update --filter CoreAgentDeepHITLBatch` first failed on
  missing `CoreAgentDeepHITLBatchReviewer`,
  `CoreAgentDeepHITLBatchReviewRequest`, and
  `CoreAgentDeepNativeToolBatchHITLAdapter`, then passed 14 batch tests after
  implementation.
- Xcode 27 SDK interface review and sidecar review confirmed
  FoundationModels dynamic-profile `onToolCall`/`onToolOutput` hooks are
  observational throwing callbacks, not pre-execution edit/reject/respond hooks.
  CoreAgent must not claim automatic whole-turn HITL batching for profile-owned
  tools until Apple exposes a real interception API.
- VibeProxy model-panel artifacts for the HITL batch adapter slice are saved in
  `.work/vibeproxy/2026-07-06-hitl-batch-adapter/`. `gpt-5.5` passed without
  blockers. `gemini-3.5-flash-low` found a valid direct-predicate HITL bypass;
  that was fixed by adding `CoreAgentDeepHITLPredicateCache` and
  `directDecisionHonorsConditionalPredicate`. Haiku's remaining blocker claims
  were adjudicated against live code, existing graph tests, and the batch
  resolver contract in `adjudication.md`.
- VibeProxy image-input smoke used a locally validated 32x32 RGB PNG and passed
  on `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. No audio/video route was exposed by the
  discovered OpenAI-compatible VibeProxy endpoints.
- Post-fix verification passed:
  - `swift test --skip-update --filter CoreAgentDeepHITL` passed 25 HITL tests.
  - `swift test --skip-update --filter CoreAgentDeep` passed 97 Deep tests.
  - `swift test --skip-update` passed the full package suite.
  - `swift build --skip-update` completed successfully.
  - `git diff --check` completed successfully.
  - Direct trailing-whitespace scan over changed text files found no matches.
- Added `CoreAgentEngine` product/target and `CoreAgentEngineTests`.
- TDD red/green evidence for Engine:
  `swift test --skip-update --filter CoreAgentEngineTests` first failed on
  missing `InMemoryCoreAgentEngineStore` and `CoreAgentEngineIssueScanner`,
  then passed 5 tests after adding the store, redaction policy, trace records,
  receipt storage, project/thread queries, issue status filters, and typed
  failed-run issue grouping.
- Added `CoreAgentRunObserver` to CoreAgent so plugins/tools can receive the
  finalized `CoreAgentRun` object after all run events are recorded. Added
  `CoreAgentEnginePlugin` and a session integration test proving the plugin
  ingests the same finalized run returned from `CoreAgentSession.respond`.
- `swift test --skip-update --filter CoreAgentEngineTests` passed 6 Engine
  tests after the finalized-run observer/plugin integration.
- Engine post-integration verification passed:
  - `swift test --skip-update --filter CoreAgentTests` passed 45 CoreAgent
    tests after the run observer hook.
  - `swift test --skip-update` passed the full package suite.
  - `swift build --skip-update` completed successfully.
  - `git diff --check` completed successfully.
  - Direct trailing-whitespace scan over changed text files found no matches.
- Latest-source check on 2026-07-06 confirmed SkillOpt's public contract as
  text-space skill optimization over frozen agents using bounded skill-document
  edits, validation-gated updates, rejected-edit feedback, and deployable
  `best_skill.md` artifacts.
- Added `CoreAgentSkills` product/target and `CoreAgentSkillsTests`.
- TDD red/green evidence for Skills:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentSkill`, `InMemoryCoreAgentSkillStore`,
  `CoreAgentSkillOptimizer`, `CoreAgentSkillCurator`, and harness optimizer
  symbols, then passed 5 tests after adding the local SkillOpt foundation.
- Skills post-integration verification passed:
  - `swift test --skip-update` passed the full package suite.
  - `swift build --skip-update` completed successfully.
  - `git diff --check` completed successfully.
  - Direct trailing-whitespace scan over changed text files found no matches.
- VibeProxy Engine/Skills panel artifacts are saved in
  `.work/vibeproxy/2026-07-06-engine-skills-foundation/`. GPT-5.5, Gemini 3.5
  Flash, and Haiku all returned BLOCK before fixes. Valid findings were fixed
  with regressions: Engine finalized-run validation, receipt-verified readback,
  ingestion failure reporting, issue reopening, delimiter-safe fingerprints,
  bounded redaction regexes, skill version-collision rejection,
  whitespace-only replacement rejection, and duplicate harness-candidate
  rejection. False findings and rationale are recorded in `adjudication.md`.
- Post-VibeProxy Engine/Skills verification passed:
  - `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`
    passed 17 focused tests.
  - `swift test --skip-update` passed the full package suite.
  - `swift build --skip-update` completed successfully.
  - `git diff --check` completed successfully.
  - Direct trailing-whitespace scan over changed text files found no matches.
- `swift test --skip-update --filter CoreAgentDeep` passed 58 Deep tests before
  the node-scoped default-ID regression was added.
- `swift test --skip-update` passed the full package suite after the graph
  context and batch HITL fixes; the final Deep target count in that run was 59
  tests.
- `swift build --skip-update` completed successfully after the graph context
  and batch HITL fixes.
- `git diff --check` and the direct trailing-whitespace scan over untracked
  files completed successfully after the graph context and batch HITL fixes.
- TDD evidence for recursive subagent depth/delegation budgets:
  `swift test --skip-update --filter CoreAgentDeepTask` first failed on missing
  explicit async closure returns, then on the session-governed
  `LanguageModelSession.ToolCallError` wrapper assertion, then passed 20
  task/subagent tests after asserting the wrapped
  `CoreAgentDeepSubagentBudgetError`.
- Added `CoreAgentDeepSubagentBudget`, budget state/error models, an
  actor-backed delegation ledger, task-local nested budget propagation, parent
  run keyed top-level delegation sharing, plugin budget forwarding, and
  audit-visible budget fields for completed, failed, and denied task attempts.
- `swift test --skip-update --filter CoreAgentDeep` passed 65 Deep tests after
  the recursive budget slice and Apple platform plan update.
- `swift test --skip-update` passed the full package suite after the recursive
  budget slice and Apple platform plan update.
- `swift build --skip-update` completed successfully after the recursive budget
  slice and Apple platform plan update.
- `git diff --check` and the direct trailing-whitespace scan over untracked
  files completed successfully after the recursive budget slice and Apple
  platform plan update.
- Security and Swift/iOS reviewers found valid recursive-budget hardening
  issues: model-facing task tools defaulted to unlimited recursion, task audits
  stored raw delegated descriptions, direct calls received a fresh budget
  ledger per call, unknown subagent attempts did not consume budget, budget
  trackers had no cleanup lifecycle, and App Intents acceptance criteria did
  not require OS 27 supported-mode/allowed-execution-target restrictions.
- Added regressions and fixes for those findings: bounded
  `CoreAgentDeepSubagentBudget.modelFacingDefault`, redacted bounded audit
  descriptions, stable direct-call budget scopes, unknown non-empty subagent
  requests consuming task-attempt budget, CoreAgent run-lifecycle cleanup for
  task budget scopes, plugin completion/failure cleanup, SwiftData authority
  metadata/read-barrier acceptance criteria, and App Intents supported-mode/
  allowed-execution-target/foreground restriction acceptance criteria.
- `swift test --skip-update --filter CoreAgentDeepTask` passed 24
  task/subagent tests after the hardening fixes.
- `swift test --skip-update --filter CoreAgentDeep` passed 69 Deep tests after
  the hardening fixes.
- `swift test --skip-update` passed the full package suite after the hardening
  fixes.
- `swift build --skip-update` completed successfully after the hardening fixes.
- `git diff --check` and the direct trailing-whitespace scan over untracked
  files completed successfully after the hardening fixes.
- Security re-review reported no remaining findings for default budgets, audit
  description redaction, direct-call budget scope, unknown-subagent budget
  consumption, tracker cleanup, App Intents target/mode criteria, or SwiftData
  authority/read-barrier criteria.
- Swift/iOS re-review reported no remaining tracker-retention findings. Added
  one more regression for plugin-owned task-tool cleanup after the re-review
  noted it as a test gap.
- `swift test --skip-update --filter CoreAgentDeepTask` passed 25
  task/subagent tests after the plugin cleanup regression.
- `swift test --skip-update --filter CoreAgentDeep` passed 70 Deep tests after
  the plugin cleanup regression.
- `swift test --skip-update` passed the full package suite after the plugin
  cleanup regression.
- `swift build --skip-update` completed successfully after the plugin cleanup
  regression.
- `git diff --check` and the direct trailing-whitespace scan over untracked
  files completed successfully after the plugin cleanup regression.
- Added `CoreAgentDeepConversationHistoryCompactor`, JSON snapshot envelope,
  redacted lossy summary marker, and
  `CoreAgentTranscriptRetention.deepConversationHistory(...)` for checkpoint-time
  conversation-history offload.
- `swift test --skip-update --filter CoreAgentDeepConversationHistory` first
  failed on missing conversation-history API, then passed 6 tests covering
  small-history no-op, full native transcript offload/recovery, compacted
  checkpoint retention, tool-turn boundary safety, file-backed checkpoint
  compatibility, and explicit checkpoint-only behavior for active sessions.
- Swift/security review found valid conversation-history hardening issues:
  prompt-visible summaries leaked structured tool-call JSON secrets, replayed
  hidden reasoning entries as prompt text, exposed raw transcript filesystem
  paths to the model, could leave orphaned raw artifacts on checkpoint save
  failure, did not erase offload artifacts on checkpoint reset, and used lossy
  scope sanitization that could leak or collide.
- Added regressions and fixes for those findings: public structural argument
  redaction reuse, reasoning omission from lossy summaries, opaque artifact IDs
  in model-visible summaries, hash-derived scope path components, checkpoint
  artifact metadata, transactional retention finalize/rollback hooks,
  artifact erasure during `reset(removingCheckpoint: true)`, explicit denial of
  model-facing `read_file` without a read grant, and file-backed
  restore/respond coverage.
- `swift test --skip-update --filter CoreAgentDeepConversationHistory` passed
  13 conversation-history tests after the hardening fixes.
- Delegated security re-review of the hardening fixes reported no findings,
  residual risks, or testing gaps for the conversation-history offload slice.
- Added active-session conversation-history compaction by letting retention
  preparations opt into a live transcript rebuild after successful checkpoint
  persistence. `CoreAgentDeepConversationHistoryCompactor` marks compacted
  transcripts active-session eligible, while ordinary retention remains
  persistence-only by default.
- Active compaction emits `transcriptActiveSessionCompacted` receipt events and
  is checkpoint-backed: checkpoint save failure rolls back artifacts and does
  not rebase the live native session ahead of durable readback.
- `swift test --skip-update --filter CoreAgentDeepConversationHistory` first
  failed because the third same-session request still used the full native
  transcript, then passed 14 tests covering regular and streaming active-session
  rebuilds after checkpoint persistence.
- Security/Swift review found valid active-compaction hardening issues:
  no-store manual `checkpoint()` could install active compaction without durable
  checkpoint persistence, active compaction installed before plugin completion
  could leave failed runs live-rebased, rollback could delete a previously
  committed deterministic artifact, reset deleted artifacts before checkpoint
  removal succeeded, and artifact cleanup trusted persisted paths by kind only.
- Added regressions and fixes for those findings: active rebase now requires
  `savedToCheckpointStore`, install/event recording happens after plugin
  completion succeeds, rollback preserves preexisting final artifacts,
  `reset(removingCheckpoint:)` removes checkpoint metadata before artifacts,
  artifact cleanup validates the conversation-history path/digest/id shape, and
  no-store/manual-checkpoint, plugin-failure, existing-artifact, invalid-path,
  and removal-failure cases are covered.
- `swift test --skip-update --filter CoreAgentDeepConversationHistory` first
  failed on the hardening regressions, then passed 19 conversation-history tests.
- `swift test --skip-update --filter CoreAgentDeep` passed 89 Deep tests after
  the active-compaction hardening fixes.
- `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and the touched-file trailing-whitespace scan passed after the
  active-compaction hardening fixes.
- Focused security and Swift/API re-review of the active-compaction hardening
  fixes reported no remaining findings, residual risks, or testing gaps.
- Added `CoreAgentApplePlatform` product/target and
  `CoreAgentApplePlatformTests`.
- TDD red/green evidence for Apple platform adapters:
  `swift test --skip-update --filter CoreAgentApplePlatformTests` first failed
  because `CoreAgentSwiftDataCheckpointSnapshot`,
  `CoreAgentSwiftDataCheckpointRecord`, `CoreAgentAppleActionGate`,
  `CoreAgentAppIntentDescriptor`, and `CoreAgentRunProjectionStore` were
  missing, then passed 6 focused tests after implementation.
- Added SwiftData checkpoint snapshot and record wrappers that persist canonical
  CoreAgent checkpoint bytes plus indexed authority/policy/readback metadata.
  Readback enforces authority-boundary and policy-version checks before digest
  verification and checkpoint decode.
- Added capability-scoped Apple action gating that keeps deterministic code
  interpreter authority separate from computer-use consent and remote execution
  network policy.
- Added App Intent exposure descriptors that reject mutating/destructive
  intents unless they require authorization, require HITL for sensitive
  operations, and allow foreground execution.
- Delegated Swift/iOS review found two valid Apple gate issues: generic consent
  receipts were reusable across consent-required actions, and App Intent
  execution was detached from descriptor/current-mode/current-target policy.
  Added typed consent requirements/receipts, length-prefixed request
  fingerprints, authority/policy/capability/expiry checks, descriptor-aware App
  Intent execution requests, and regressions for reused/empty/expired receipts,
  unsupported modes, and background mutating intents.
- VibeProxy Apple-platform review found valid P2 hardening gaps: checkpoint
  bytes used lossy ISO-8601 date coding, App Intent consent fingerprints did
  not include descriptor exposure semantics, Apple-platform tests imported
  targets not declared as direct test dependencies, and checkpoint persistence
  plus App Intent donation capabilities were vocabulary-only. Fixed with
  lossless Date coding, descriptor exposure fingerprints/revisions, direct
  `CoreAgent`/`CoreAgentEngine` test dependencies, gateable
  `swiftDataCheckpointPersistence` and `appIntentDonation` requests, and
  focused regressions.
- Hardened consent receipts further after VibeProxy/Haiku identified public
  receipt construction as an authority gap. Consent-required actions now require
  receipts issued by a trusted issuer and verified with HMAC-SHA256 over the
  authority boundary, policy version, capability, request fingerprint, grant
  time, and non-nil expiry.
- Tightened App Intent exposure after VibeProxy/Haiku flagged structural
  descriptor validation as insufficient. Descriptors now require explicit
  host-provided agent exposure before validation, and that exposure participates
  in the consent request fingerprint.
- Follow-up VibeProxy review found two valid Apple contract gaps: checkpoint
  authority/policy sidecar metadata was not included in the digest, and App
  Intent donation was descriptor-detached. Added envelope digests that bind the
  checkpoint key, authority boundary, policy version, format, compatibility
  revision, save time, and canonical checkpoint bytes; changed donation
  requests to carry descriptors and deny `doNotDonate`; added regressions for
  metadata replay, remote-network denial, disabled donation, descriptor-bound
  donation consent, and projection deduplication.
- Final VibeProxy Apple-platform review found valid hardening issues in
  checkpoint identity/`savedAt` parity, incremental projection merging,
  constant-time consent signature verification, issued-receipt expiry,
  nil-verifier proof, and App Intent donation/execution replay. Added
  checkpoint-ID digest binding, decoded `savedAt` parity checks, stable
  nanosecond timestamp tokens, CryptoKit authentication-code verification,
  mandatory expiry for issued receipts, request-type-separated App Intent
  fingerprints, incremental projection merging, and focused regressions.
- Added an in-memory SwiftData `ModelContext` round-trip test for
  `CoreAgentSwiftDataCheckpointRecord` so Date/index persistence is checked
  against SwiftData rather than only in-memory structs.
- Added a main-actor `@Observable` `CoreAgentRunProjectionStore` over
  `CoreAgentEngineTrace` that exposes narrow run-list fields, event counts, and
  status without placing raw event messages, attributes, receipts, transcripts,
  or trace blobs in SwiftUI view state.
- Added `Documentation/CoreAgentApplePlatform-Runtime.md` documenting the
  implemented Apple foundation slice and explicit non-goals.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 17
  Apple-platform focused tests after delegated-review and VibeProxy hardening.
- Final verification after the Apple-platform foundation fixes:
  `swift test --skip-update --filter CoreAgentApplePlatformTests`,
  `swift test --skip-update`, `swift build --skip-update`,
  `git diff --check`, and the tracked-modified/untracked text trailing-space
  scan all passed.
- Started live SwiftData checkpoint-store adapter slice (L14). TDD red cycle:
  `swift test --skip-update --filter CoreAgentApplePlatformTests` first failed
  because `CoreAgentSwiftDataCheckpointStore` did not exist, then passed 21
  Apple-platform tests after adding a main-actor `ModelContext` store.
- Delegated Swift/iOS sidecar review found valid live-store requirements:
  explicit ModelContext actor isolation, composite authority/policy scope
  filtering, deterministic duplicate same-scope cleanup, hard-delete vs
  tombstone clarity, lossless checkpoint validation parity with
  `FileCheckpointStore`, and caller-owned action-gate documentation.
- Added `CoreAgentCheckpointPersistenceValidation` in portable CoreAgent and
  reused it from both `FileCheckpointStore` and
  `CoreAgentSwiftDataCheckpointStore` so SwiftData rejects typed metadata and
  custom transcript segments before inserting rows by default.
- Added deterministic SwiftData checkpoint `scopeKey`, scoped hard delete,
  duplicate-row collapse, portable `CoreAgentCheckpointStore` existential
  coverage, and a `CoreAgentSession` restore regression over the SwiftData
  store.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 26
  Apple-platform focused tests after the live SwiftData checkpoint-store
  implementation and sidecar hardening.
- VibeProxy live-store review through local `127.0.0.1:8320` returned HTTP 200
  for `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. GPT/Gemini found a valid unbounded SwiftData
  table-fetch issue in `scopedRecords(for:)`; Gemini also found a valid
  rollback risk for caller-supplied shared `ModelContext`s. Fixed by using a
  SwiftData predicate for the composite scope and by making automatic rollback
  apply only to the `ModelContainer` initializer's isolated context. Haiku's
  main-actor and checkpoint-ID digest findings were stale/false against the
  current code; scope-key versioning and defensive-filter documentation were
  still tightened.
- Final verification after the live SwiftData checkpoint-store slice:
  `swift test --skip-update --filter CoreAgentApplePlatformTests`,
  `swift test --skip-update`, `swift build --skip-update`,
  `git diff --check`, and the tracked-modified/untracked text trailing-space
  scan all passed.
- Started live SwiftData Engine trace/issue-store adapter slice (L15). TDD red
  cycle: `swift test --skip-update --filter CoreAgentApplePlatformTests` first
  failed because `CoreAgentSwiftDataEngineStore`,
  `CoreAgentSwiftDataEngineTraceRecord`, and
  `CoreAgentSwiftDataEngineIssueRecord` did not exist.
- Delegated Swift/iOS sidecar review found valid live Engine-store
  requirements: shared redaction API reuse, actor isolation for `ModelContext`,
  receipt/readback corruption tests, sidecar metadata binding, nil-thread query
  semantics, project+run trace identity, issue lifecycle edge cases, duplicate
  trace replacement, corrupt issue records, subsecond date round trip, and
  `CoreAgentEnginePlugin` integration.
- Added `CoreAgentSwiftDataEngineTraceRecord`,
  `CoreAgentSwiftDataEngineIssueRecord`, and main-actor
  `CoreAgentSwiftDataEngineStore`. The store ingests finalized runs as redacted
  receipt-verifiable traces, fails closed on stale receipts, unredacted rows,
  invalid JSON, digest mismatches, and indexed sidecar replay, scopes traces by
  project plus run ID, and mirrors the in-memory Engine issue lifecycle
  semantics.
- VibeProxy Engine-store review through local `127.0.0.1:8320` returned HTTP
  200 for `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. The model panel found valid defects in public
  decoded record access, duplicate trace/issue row collapse, corrupt issue
  shadowing, unbounded `nextTraceSequence()` fetch, redaction-policy binding,
  trace scope-key integrity, issue contributing-run provenance, and issue
  identity-collision handling. Those were fixed with regression tests.
- Final narrow VibeProxy recheck of trace scope-key integrity, issue
  provenance union, and issue identity collision behavior passed on all three
  models.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 46
  Apple-platform focused tests after the live SwiftData Engine trace/issue
  store implementation, sidecar hardening, and VibeProxy fixes.
- Final verification after the live SwiftData Engine trace/issue-store slice:
  `swift test --skip-update`, `swift build --skip-update`,
  `git diff --check`, and the tracked-modified/untracked text
  trailing-whitespace scan all passed.
- Started live SwiftData graph checkpoint/store adapter slice (L16). TDD red
  cycle: `swift test --skip-update --filter CoreAgentApplePlatformTests` first
  failed because `CoreAgentSwiftDataGraphCheckpointer`,
  `CoreAgentSwiftDataGraphCheckpointRecord`, `CoreAgentSwiftDataGraphStore`,
  and `CoreAgentSwiftDataGraphStoreRecord` did not exist.
- Added `CoreAgentSwiftDataGraphCheckpointRecord`,
  `CoreAgentSwiftDataGraphStoreRecord`, main-actor
  `CoreAgentSwiftDataGraphCheckpointer`, and main-actor
  `CoreAgentSwiftDataGraphStore`. The graph checkpointer persists generic
  `Codable & Sendable` graph checkpoints with parent lineage, namespaces,
  pending writes, reverse save order, checkpoint-ID lookup, deterministic tied
  save-sequence ordering, scope-key/digest sidecar binding, and fail-closed
  forged/corrupt-row behavior. The graph store persists generic
  `Codable & Sendable` values by namespace/key, supports typed readback,
  sorted unique keys, duplicate replacement, heterogeneous valid payload rows,
  structural integrity validation before mutation, and fail-closed forged or
  corrupt matching rows.
- Delegated Swift/iOS sidecar review found a valid fail-closed gap: corrupt
  matching graph rows were being skipped with `compactMap`, allowing stale
  fallback. Fixed by making record decode/validation throw typed
  `CoreAgentSwiftDataGraphPersistenceError` values and validating fetched
  candidates instead of silently filtering them.
- VibeProxy graph persistence review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around reverse save
  ordering, stale fallback on corrupt rows, forged scope-key predicates, latest
  O(1) behavior, heterogeneous graph store payloads, mutation validation,
  rollback defaults, tied save-sequence ordering, `CoreAgentGraphStoreRecord`
  `Codable` conformance, and extreme Date digest overflow. Final r4 GPT-5.5
  recheck returned no findings; Gemini and Haiku remaining notes challenged the
  deliberate fail-closed policy or marked observations intentional/acceptable.
- `swift test --skip-update --filter CoreAgentApplePlatformTests.swiftDataGraph`
  passed 11 graph-focused Apple tests after the live SwiftData graph
  checkpoint/store implementation and VibeProxy fixes.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 57
  Apple-platform focused tests after the live SwiftData graph checkpoint/store
  implementation and review fixes.
- Started deterministic Apple code-interpreter slice (L17). TDD red cycle:
  `swift test --skip-update --filter CoreAgentApplePlatformTests.deterministicCodeInterpreter`
  first failed because `CoreAgentAppleDeterministicCodeInterpreter`,
  `CoreAgentAppleDeterministicCodeRequest`, and typed program/value APIs did
  not exist.
- Added `CoreAgentAppleDeterministicCodeInterpreter`,
  `CoreAgentAppleDeterministicCodeRequest`,
  `CoreAgentAppleDeterministicProgram`, typed deterministic instructions,
  typed values/operands, execution limits, typed result/failure/status, and
  audit metadata over authority boundary, policy version, workspace root,
  network policy, interpreter tier, request ID, timestamps, program digest,
  input digest, and status.
- The deterministic interpreter executes only an in-process typed instruction
  language. It has no filesystem, network, shell, subprocess, JavaScriptCore,
  WASI, random, clock, or host-object authority. It supports addition,
  concatenation, stdout emission, and named outputs under explicit resource
  budgets.
- VibeProxy L17 review through local `127.0.0.1:8320` used `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`. Valid findings
  around non-finite values, cancellation, consent receipt replay, future grant
  times, weak signing keys, unsafe identifiers, duplicate output names, and
  intermediate-state growth were fixed with regression tests. App Intent
  descriptor-bypass claims were adjudicated false against the preflight denial
  path; manifest-signing and append-only audit sinks remain future hardening,
  not L17 implementation scope.
- Delegated Swift/iOS review found valid deterministic interpreter gaps around
  unbounded intermediate state and non-finite values. Added preflight and
  per-assignment validation for input bytes, value bytes, state bytes, operand
  count, variable count, identifier length, cancellation, non-finite
  inputs/literals/results, output-name containment, and duplicate outputs.
- `swift test --skip-update --filter CoreAgentApplePlatformTests.deterministicCodeInterpreter`
  plus action-gate signing-key/receipt tests passed 9 focused tests after L17
  hardening.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 66
  Apple-platform focused tests after L17.
- Final verification after L17 passed: `swift test --skip-update`,
  `swift build --skip-update`, `git diff --check`, and the
  tracked-modified/untracked text trailing-whitespace scan.
- Started Apple computer-use executor foundation slice (L18). TDD red cycle:
  `swift test --skip-update --filter CoreAgentApplePlatformTests.computerUse`
  first failed because `CoreAgentAppleComputerUseExecutor`,
  `CoreAgentAppleComputerUseRequest`, `CoreAgentAppleComputerUsePlan`,
  `CoreAgentAppleComputerUseEvidence`, and the computer-use backend/result
  types did not exist.
- Added `CoreAgentAppleComputerUseExecutor`, `CoreAgentAppleComputerUseBackend`,
  typed dry-run/execution requests, plans, plan steps, evidence kinds/evidence,
  result/status/failure/audit types, and `.computerUsePlan` /
  `.computerUseExecution(actionID:approvedPlanDigest:)` action-gate request
  cases.
- L18 dry-run planning is capability-gated and does not require consent.
  Execution requires an approved plan plus digest produced by a prior dry-run in
  the same executor, binds consent to action ID plus plan digest, does not
  re-plan after consent, and validates evidence before returning `.executed`.
- VibeProxy L18 review through local `127.0.0.1:8320` used `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`. Valid findings
  around action-only consent, backend-controlled evidence requirements,
  request/plan structural validation, Unicode SHA-256 digest validation,
  cancellation after `backend.execute`, dry-run provenance, empty baseline
  evidence configuration, planning cancellation, and unbounded approved-plan
  cache were fixed with focused regressions.
- Final VibeProxy r3 recheck passed targeted L18 checks on all three models:
  prior dry-run plan digest required, consent fingerprint binds action ID plus
  plan digest, baseline screenshot evidence cannot be removed, backend
  cancellation maps to `.failed(.cancelled)`, and ASCII SHA-256 validation is
  strict. Durable cross-process approval/receipt stores and trusted evidence
  capture attestation remain future hardening.
- `swift test --skip-update --filter CoreAgentApplePlatformTests.computerUse`
  passed 7 focused computer-use tests after L18 hardening.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 73
  Apple-platform focused tests after L18.
- Final verification after L18 passed: `swift test --skip-update`,
  `swift build --skip-update`, `git diff --check`, and the
  tracked-modified/untracked text trailing-whitespace scan.
- Started App Intent donation invalidation foundation slice (L19). TDD red
  cycle: `swift test --skip-update --filter 'App Intent donation records use stable non-sensitive identity'`
  failed because `CoreAgentAppIntentDonationRecord`,
  `CoreAgentAppIntentDonationSubject`, `InMemoryCoreAgentAppIntentDonationStore`,
  and record-bound donation action-gate APIs did not exist.
- Added typed App Intent donation subjects and records. Donation IDs are
  digest-derived from validated descriptor exposure, stable subject identity,
  authority boundary, and policy version; they do not contain raw descriptor or
  subject identifiers.
- Donation subjects explicitly reject prompt text, tool arguments, and
  transient tool calls so App Intent/Siri/Spotlight donation identity cannot be
  raw prompt/tool payload state.
- Added `CoreAgentAppleExecutionRequest.appIntentDonationRecord(record:)` so
  action-gate consent is bound to the specific workflow/entity/run outcome
  being donated, not only the descriptor.
- Added `InMemoryCoreAgentAppIntentDonationStore` with invalidation records for
  erasure and access-scope changes. This is the local metadata foundation for
  later OS `IntentDonationManager` / `RelevantIntentManager` bridging, not a
  concrete App Intents bundle.
- Initial VibeProxy L19 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
  Valid findings were fixed around synthesized Codable bypass for donation
  records, stale reactivation after invalidation, plaintext record-bound
  consent fingerprints, and descriptor-identifier tampering.
- Added custom `CoreAgentAppIntentDonationRecord` Codable validation so decoded
  records revalidate the typed subject and recompute the donation identifier.
  The donation identifier now binds descriptor identifier, descriptor exposure,
  subject kind/stable ID/scope, authority boundary, and policy version.
- Added invalidation tombstones for donation IDs and scope IDs so erased or
  scope-invalidated records cannot be re-recorded into the in-memory active
  donation set.
- Final VibeProxy recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 78
  Apple-platform focused tests after L19 hardening.
- Final verification after L19 passed: `swift test --skip-update`,
  `swift build --skip-update`, `git diff --check`, and the trailing-whitespace
  scan over modified/untracked text files.
- Started SkillOpt-Sleep local optimizer slice (L20). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentSkillSleepOptimizer`, rollout evidence, sleep request,
  policy, decision, and meta-observation symbols.
- Added `CoreAgentSkillSleepOptimizer` with bounded local sleep-run semantics:
  duplicate proposal preflight, skill-existence and score/suite preflight,
  rollout evidence IDs in audit entries, max accepted proposal budgets,
  heldout/training split-leakage rejection, protected slow-update regions,
  rejected-edit memory, and meta-observation memory.
- Initial VibeProxy L20 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around unbounded
  single-edit drift, public optimizer policy bypass, repeated protected-region
  scanning, append into unterminated protected regions, partial sleep-run
  mutation after invalid validation metadata, partial sleep-run mutation after
  invalid edit application, and empty protected-region marker parser risk.
- `swift test --skip-update --filter CoreAgentSkillsTests` passed 17
  SkillOpt-focused tests after L20 hardening.
- Final VibeProxy L20 recheck passed on `gpt-5.5`,
  `claude-haiku-4-5-20251001`, and a full-file rerun of
  `gemini-3.5-flash-low`.
- Final verification after L20 passed: `swift test --skip-update --filter
  CoreAgentSkillsTests`, `swift test --skip-update`, `swift build
  --skip-update`, `git diff --check`, and the trailing-whitespace scan over
  modified/untracked text files.
- Started concrete App Intents bridge slice (L21). TDD red cycle:
  `swift test --skip-update --filter CoreAgentAppIntentsTests` first failed
  because product `CoreAgentAppIntents` required by package target
  `CoreAgentAppIntentsTests` did not exist.
- Added `CoreAgentAppIntents` product/target with an `AppIntentsPackage`
  marker, concrete `CoreAgentOpenRunIntent`, `CoreAgentPauseRunIntent`, and
  `CoreAgentContinueRunIntent`, a runtime environment boundary, OS policy
  mapping from CoreAgent descriptors to Apple `IntentModes` /
  `IntentExecutionTargets`, and a `CoreAgentAppIntentBridge` that evaluates
  `CoreAgentAppleActionGate` before checkpointing or host work.
- Added focused Swift Testing coverage for stable validated catalog entries,
  CoreAgent caller-mode vs Apple process-target separation, unsupported-mode
  denial before host execution, consent/checkpoint/operation ordering,
  cancellation before side effects, and run-ID validation before runtime
  delegation.
- Initial VibeProxy L21 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around concrete
  AppIntent `perform()` bypassing the bridge, mutating bridge requests with nil
  checkpoint keys, missing cancellation checks immediately before host work,
  thrown `CancellationError` being reported as generic failure, unsafe external
  run IDs, and catalog OS-policy drift from concrete AppIntent metadata.
- Added `CoreAgentRunAppIntentRuntimeEnvironment` so concrete AppIntent
  wrappers call host work only as a post-bridge operation. The bridge now
  enforces checkpoints for mutating/destructive descriptors, checks
  cancellation immediately before operation, maps `CancellationError` to
  `.cancelled`, and validates run IDs as strict ASCII external identifiers.
- Final VibeProxy L21 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- Final verification after L21 passed:
  `swift test --skip-update --filter CoreAgentAppIntentsTests`,
  `swift test --skip-update --filter CoreAgentApplePlatformTests`,
  `swift test --skip-update`, and `swift build --skip-update`.
- Started Engine-to-SkillOpt trace harvest/replay slice (L22). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentSkillEngineTraceHarvester`,
  `CoreAgentSkillReplayGenerator`, and replay generation policy/request
  symbols, plus the explicit `CoreAgentEngine` test dependency.
- Added `CoreAgentSkillEngineTraceHarvester` to convert verified finalized
  Engine traces into `CoreAgentSkillRolloutEvidence` using deterministic
  SHA-256 digests, safe run/issue references, issue status linkage, typed
  outcome scoring, and no raw event messages, issue titles, issue
  fingerprints, failure attributes, prompt text, or tool arguments in evidence
  metadata or verifier feedback.
- Added `CoreAgentSkillReplayGenerator`, `CoreAgentSkillReplayMode`,
  `CoreAgentSkillReplayRequest`, and
  `CoreAgentSkillReplayGenerationPolicy` for deterministic replay/dream rollout
  request generation. The generator validates held-out suite IDs and request
  caps, preserves input-order determinism, caps output, excludes configured
  training/source suites, and treats missing source-suite metadata as unknown
  when a split-exclusion policy is active.
- Initial VibeProxy L22 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around raw
  `error_type`/`tool` failure attribute copying, raw issue-title feedback
  leakage, and trusting custom `CoreAgentEngineStore` conformers to return only
  receipt-verified finalized traces.
- Added regression coverage for sensitive values in failure attributes and
  issue fingerprints, generic issue-linked feedback, absence of copied
  error/tool/fingerprint metadata, filtering of tampered receipt/run-event
  mismatches, filtering of non-finalized traces, deterministic replay request
  IDs, verifier-feedback exclusion from replay requests, request caps, invalid
  replay policy validation, and unknown-suite split exclusion.
- Final VibeProxy L22 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- Final verification after L22 passed:
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, and `swift build --skip-update`.
- Started file-backed SkillOpt store slice (L23). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `FileCoreAgentSkillStore`, generic skill-store protocol use, and
  durable export/resume APIs.
- Added `CoreAgentSkillStore` so the curator, direct optimizer, and sleep
  optimizer can run against either in-memory or file-backed storage without
  changing optimization semantics.
- Added `FileCoreAgentSkillStore` with a `skills/` directory for versioned
  skill JSON rows and an `optimizer-memory/` directory for rejected-edit and
  meta-observation memory. Skill IDs are hashed before becoming path
  components, so user/model-provided IDs are never used as raw filesystem
  names.
- File-backed saves use POSIX exclusive-create writes for `version-N.json` and
  map existing rows to `versionCollision`, so a resumed or concurrent writer
  cannot silently overwrite a prior skill version.
- File-backed reads fail closed for corrupted skill rows, misplaced rows,
  filename/version mismatches, and skill rows whose decoded ID does not map
  back to the containing hashed directory. Corrupted optimizer-memory files
  reject future memory mutations instead of being overwritten with empty memory.
- Added file-backed `best_skill.md` export plus explicit safe filename support.
  Export filenames must be plain file names; absolute paths, parent paths, and
  nested path separators are rejected.
- Initial VibeProxy L23 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around corrupted
  optimizer memory being reset, valid rows being accepted from the wrong skill
  directory, filename/version mismatches, explicit export filename safety, and
  duplicate-version overwrite risks. A Haiku path-traversal claim against skill
  IDs was adjudicated false after full-source review because IDs are hashed,
  but extra tests now prove that containment contract.
- Added regression coverage for path-shaped skill IDs, optimizer memory resume,
  rejected proposals through the file-backed optimizer, duplicate-version
  collision after reopen and row corruption, corrupt row fail-closed behavior,
  misplaced rows, filename/version mismatches, corrupt optimizer-memory
  mutation rejection, and explicit export filename validation.
- Final VibeProxy L23 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- Final verification after L23 passed:
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and a targeted trailing-whitespace scan over the touched Skills/package/docs
  files.
- Started typed multi-objective evaluator adapter slice (L24). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentHarnessObjectiveID`, objective definitions/evaluations,
  objective-aware `selectBest`, duplicate/no-eligible errors, and
  `CoreAgentSkillMultiObjectiveValidationAdapter`.
- Added typed objective IDs, maximize/minimize direction, positive finite
  weighted objectives, optional required normalized mean gates, objective
  evaluations, per-objective audit scores, and multi-objective harness
  selection that ranks eligible candidates before ineligible candidates, then
  weighted score descending, then candidate ID ascending.
- Added fail-closed validation for duplicate candidate IDs, duplicate objective
  IDs, duplicate candidate/suite/objective evaluation triples, unknown
  candidate/objective references, missing objective rows, empty objective IDs,
  empty held-out suites, invalid weights, invalid required means, invalid
  scores, and no eligible candidate.
- Added `CoreAgentSkillMultiObjectiveValidationAdapter` so a single candidate's
  typed objective evaluations can produce the existing scalar
  `CoreAgentSkillValidationResult` used by SkillOpt proposals while preserving
  held-out suite and notes. The adapter rejects mismatched evaluation suite
  labels so scalar validation cannot be mislabeled.
- Sidecar Swift review found valid API-contract gaps around typed objective
  identifiers, duplicate objective-evaluation rejection, no-eligible typed
  failure, and exact floating-point assertions. Those were fixed before
  VibeProxy.
- Initial VibeProxy L24 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid blockers were fixed around minimize
  required-score gates using raw means and delimiter-joined duplicate keys
  colliding when IDs contained `:`.
- Added regression coverage for normalized minimize gating, delimiter-safe
  duplicate detection, and adapter held-out suite mismatch rejection.
- Final VibeProxy L24 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- Final verification after L24 passed:
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and a targeted trailing-whitespace scan over the touched Skills/package/docs
  files.
- Started typed replay/dream execution slice (L25). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentSkillReplayBackend`, `CoreAgentSkillReplayOutcome`, and
  `CoreAgentSkillReplayExecutor` symbols.
- Added `CoreAgentSkillReplayOutcome`, `CoreAgentSkillReplayBackend`,
  `CoreAgentSkillReplayExecutionPolicy`, and `CoreAgentSkillReplayExecutor`.
  The executor preflights complete request batches before backend calls,
  rejects duplicate request IDs, empty identity fields, invalid held-out suite
  IDs, invalid lowercase `sha256:` digests, invalid scores, backend/request ID
  mismatches, same-source/held-out suite execution, and excluded source suites.
- Replay execution now converts backend outcomes into deterministic
  `CoreAgentSkillRolloutEvidence` with sanitized verifier feedback,
  verifier-feedback digests, allowed replay/reference metadata only, canonical
  trimmed source-suite metadata, and no copied raw prompt/prose payloads.
- Sidecar Swift review found valid gaps around non-hex digest acceptance,
  request-time split bypass, and raw backend verifier-feedback leakage. Those
  blockers were fixed with regression coverage before VibeProxy.
- Initial VibeProxy L25 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around empty
  `source_suite_id` using the wrong error path and whitespace-padded
  `source_suite_id` bypassing held-out/excluded-suite checks.
- Final VibeProxy L25 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- Focused verification after L25 passed:
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and a targeted trailing-whitespace scan over the touched Skills/package/docs
  files.
- Started typed model-proposal boundary slice (L26). TDD red cycle:
  `swift test --skip-update --filter CoreAgentSkillsTests` first failed on
  missing `CoreAgentSkillModelProposalCandidate`,
  `CoreAgentSkillModelProposalBackend`, `CoreAgentSkillModelProposalRequest`,
  and `CoreAgentSkillModelProposalGenerator` symbols.
- Added `CoreAgentSkillModelProposalRequest`, sanitized
  `CoreAgentSkillModelProposalEvidenceReference`,
  `CoreAgentSkillModelProposalBackend`,
  `CoreAgentSkillModelProposalCandidate`, and
  `CoreAgentSkillModelProposalGenerator`. The generator creates a sanitized
  backend request, strips skill provenance notes, removes raw rollout verifier
  feedback, allowlists evidence metadata, validates evidence digests/scores and
  duplicate evidence IDs before backend calls, and converts validated backend
  candidates into existing `CoreAgentSkillSleepOptimizationProposal` values.
- Backend candidates are treated as untrusted: unsafe/duplicate proposal IDs,
  skill/baseline mismatch, empty edits, edit-count overflow, invalid validation
  scores or held-out suites, training-suite validation leakage, inapplicable
  edits, unknown evidence IDs, empty evidence IDs, and duplicate candidate
  evidence IDs fail closed before sleep-optimizer handoff.
- Validation notes from the backend are not copied verbatim; returned proposals
  use deterministic sanitized validation notes. Returned proposal evidence is
  rebuilt from sanitized evidence references with generic verifier feedback.
- Initial VibeProxy L26 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`; all three passed. GPT/Haiku testing gaps led to
  added regression coverage for invalid policy before backend calls, backend
  maxProposals overflow, unsafe/path-shaped IDs, empty held-out suites, empty
  candidate evidence IDs, and duplicate candidate evidence IDs.
- VibeProxy L26 recheck passed on `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`; Gemini's P3 held-out-suite note was already
  enforced by `validateSkillOptimizationScores` and is now covered explicitly.
- Focused verification after L26 passed:
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and a targeted trailing-whitespace scan over the touched Skills/package/docs
  files.
- Started concrete FoundationModels proposal backend slice (L27). TDD red
  cycle: `swift test --skip-update --filter
  CoreAgentSkillsTests/foundationModelsProposalBackend` first failed on missing
  `CoreAgentSkillFoundationModelsProposalBackend`.
- Added `CoreAgentSkillFoundationModelsProposalBackend` over
  `CoreAgentSession.respond(generating:)` with private FoundationModels
  `@Generable` proposal envelope/draft/edit DTOs. The backend sanitizes direct
  model-proposal requests before prompt construction, strips skill provenance,
  validates policy/maxProposals/baseline/evidence identity/digests/scores,
  allowlists evidence metadata, and maps only typed `replace`/`append` edit
  drafts into `CoreAgentSkillEdit` values. Existing
  `CoreAgentSkillModelProposalGenerator` remains the final trust boundary for
  candidate validation and sleep-optimizer handoff.
- Initial VibeProxy L27 review through direct local VibeProxy
  `127.0.0.1:8318` used `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. GPT found a valid literal-operation blocker:
  whitespace-padded `" replace"` was accepted because the backend trimmed model
  operations before matching. That blocker was fixed with a red/green
  regression by requiring exact operation literals.
- VibeProxy L27 recheck passed on `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Gemini's initial `source_suite_id` and uppercase
  digest notes were false/stale against the full helper snippet:
  `source_suite_id` is allowed, and `isSHA256Digest` accepts only digits and
  lowercase `a...f`.
- Final verification after L27 passed:
  `swift test --skip-update --filter
  CoreAgentSkillsTests/foundationModelsProposalBackendRequiresLiteralEditOperationNames`,
  `swift test --skip-update --filter
  CoreAgentSkillsTests/foundationModelsProposalBackend`,
  `swift test --skip-update --filter CoreAgentSkillsTests`,
  `swift test --skip-update --filter 'CoreAgentEngineTests|CoreAgentSkillsTests'`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and a targeted trailing-whitespace scan over the touched Skills/package/docs
  files.


- Added `CoreAgentDeepRubricMiddleware` with typed rubric verdicts, revision prompt
  injection, and focused rubric middleware tests.
- Added `CoreAgentDeepDynamicSubagentsPlugin` with `propose_subagent` and
  `approve_subagent` tools over digest-bound approved registry registration.
- Added `CoreAgentDeepRLMOrchestrator` for budgeted recursive task decomposition.
- Added `CoreAgentAppleRemoteCodeInterpreter` consent-gated backend boundary with
  focused Apple-platform tests.
- `swift test --skip-update` passed the full package suite after L34-L37.

## Slice 1 Remaining Work

- No known open Slice 1 runtime blockers after current verification.
- Do not treat the overall user goal as complete: Deep Agents behavior,
  full LangSmith-style Engine behavior,
  app-hosted App Intents proof, direct OS sandbox/WASI/remote interpreter
  runners, raw computer-use automation backends, production model-backed dream
  simulation/scheduling, and remaining production backends remain later slices.
- Before opening or merging a PR, run fresh adversarial review on the full
  branch diff and resolve valid findings.

## Slice 2 Remaining Work

- No known open todo-guard runtime blockers after L30; continue treating the
  full Deep Agents port as incomplete until the remaining bullets below are
  implemented and reviewed.
- Extend automatic offload wrapping beyond `String`-returning Foundation Models
  tools if future Deep runtime needs structured or multimodal tool outputs.
- Wire true automatic dynamic-profile/native-session pre-execution batching
  only if FoundationModels exposes a public interception API. Current work
  provides graph-level batch HITL and a portable native request-batch adapter
  for host-supplied `CoreAgentToolRequest` batches; profile-owned tools remain
  audit-only/best-effort.
- No known graph-level HITL tool-name edit or executable-dispatch blockers after
  L32. Native Foundation Models governed-tool HITL remains args-only because
  `Tool.call` does not expose a safe registered-tool retarget hook. Standalone
  graph executable dispatch authorizes and executes through a host backend, but
  it does not automatically emit `CoreAgentSession` run receipts; hosts that need
  receipt parity must wire an explicit audit/custom-event path around the backend.
- Use VibeProxy only when a future slice needs a live local model/API endpoint
  to exercise CoreAgent behavior. Use Cursor Composer 2.5 and `agy` Gemini 3.5
  Flash for formal adversarial code review. If Cursor auth is unavailable,
  record the exact blocker instead of substituting VibeProxy as a review gate.
- Extend `CoreAgentApplePlatform` beyond the live checkpoint, Engine
  trace/issue, graph persistence stores, deterministic in-process interpreter,
  consent-gated helper-process interpreter backend boundary, computer-use
  foundation, typed App Intent donation invalidation metadata, and concrete
  CoreAgent App Intents donation bridge to direct OS sandbox/WASI/remote
  interpreter runners, raw computer-use automation backends with trusted
  evidence capture, and app-hosted `AppIntentsTesting` plus
  Siri/Shortcuts/Spotlight runtime proof. Do not bake SwiftData/SwiftUI/App
  Intents into the portable core targets.
- Extend `CoreAgentSkills` beyond the local SkillOpt-Sleep policy loop and
  Engine trace harvest/replay request foundation and durable file-backed skill
  storage/export plus typed multi-objective evaluator adapters and typed
  replay/dream executor plus typed model-proposal backend boundary and concrete
  FoundationModels proposal backend to production model-backed dream
  simulation, and cross-run scheduler/orchestration workflows.
- Run adversarial Swift/security review before treating Slice 2 as PR-ready.

- L42 encodable tool offload and L43 token-aware subagent budgets landed with full `swift test` green.
- Completion audit on 2026-07-07 against the queued "everything" question:
  - Rubric middleware: `CoreAgentDeepRubricMiddleware`, `CoreAgentDeepFoundationModelsRubricGrader`, 6 focused rubric tests green.
  - Dynamic subagents: `CoreAgentDeepDynamicSubagentsPlugin`, `propose_subagent`/`approve_subagent`, opt-in `CoreAgentDeepDynamicSubagentsAutoApprovalPolicy`; 2 focused tests in `CoreAgentDeepTaskTests`.
  - RLM orchestration: `CoreAgentDeepRLMOrchestrator`, `CoreAgentDeepFoundationModelsRLMDecomposer`; 3 focused RLM tests green.
  - Interpreters: deterministic in-process, helper-process, WASI, and remote backend boundaries in `CoreAgentApplePlatform` with focused Apple-platform tests.
  - Full package verification: `swift test --skip-update` passed 411 tests; `swift build --skip-update` passed on branch `codex/coreagent-graph-runtime` at `2705cdf`.
  - Explicitly not in CoreAgent library scope (documented, host-owned): OS sandbox runners, production WASM/remote execution hosts, closed-loop Engine/Skills gates inside rubric/RLM loops, production SkillOpt scheduler/daemon, FoundationModels dynamic-profile whole-turn tool interception.
