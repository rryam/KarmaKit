Review the narrow CoreAgentDeep graph-level HITL tool-name edit slice in this workspace.

Scope files:
- Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
- Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
- Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift
- Documentation/CoreAgentDeep-Runtime.md
- Documentation/DeepAgents-Port-Task-Ledger.md

Desired contract:
- Graph-level batched HITL edit decisions may retarget a reviewed tool call to a different executable tool name only when the same-index `CoreAgentDeepHITLReviewConfig` explicitly lists that target in `allowed_edited_action_names`.
- That allowed target policy must participate in the reviewed action identity digest so stale resume decisions cannot be replayed across policy changes.
- `CoreAgentDeepHITLExecutableAction` must expose reviewed/requested identity separately from executable/edited identity so downstream graph executors and receipt writers can authorize and audit the final executable target without losing the original model request.
- Same-tool argument edits remain valid without a retarget allowlist.
- Disallowed retargets fail closed with typed errors before producing executable actions.
- `CoreAgentDeepNativeToolBatchHITLAdapter` must not silently execute retargeted graph resolutions through Foundation Models' args-only `Tool.call` boundary; it should fail closed if a reviewer retargets there.
- Tests should assert durable typed contracts, not incidental prose or provider-specific payload shapes.

Please review for correctness, authorization gaps, replay/idempotency issues, Codable/API compatibility risks, Swift 6/concurrency issues, and test adequacy. Focus only on this slice. Report P0/P1/P2 findings first with file/line references and concrete fixes. If there are no blocking findings, say so plainly and list any residual risks.
