Review the narrow CoreAgentDeep graph-level HITL tool-name edit slice.

Repo path: /Users/basitmustafa/Documents/GitHub/coreagent

Do not search the home directory. Use only the repo path above and these files:
- /Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Tests/CoreAgentDeepTests/CoreAgentDeepHITLTests.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Documentation/CoreAgentDeep-Runtime.md
- /Users/basitmustafa/Documents/GitHub/coreagent/Documentation/DeepAgents-Port-Task-Ledger.md

Desired contract:
- Graph-level batched HITL edit decisions may retarget a reviewed tool call to a different executable tool name only when the same-index `CoreAgentDeepHITLReviewConfig` explicitly lists that target in `allowed_edited_action_names`.
- That allowed target policy must participate in the reviewed action identity digest.
- `CoreAgentDeepHITLExecutableAction` must expose reviewed/requested identity separately from executable/edited identity.
- Same-tool argument edits remain valid without a retarget allowlist.
- Disallowed retargets fail closed with typed errors before producing executable actions.
- Native Foundation Models governed-tool HITL and `CoreAgentDeepNativeToolBatchHITLAdapter` must not silently execute retargeted graph resolutions through an args-only `Tool.call` boundary.
- Tests should assert durable typed contracts, not incidental prose.

Please review only this slice for correctness, authorization gaps, replay/idempotency issues, Codable/API compatibility risks, Swift 6/concurrency issues, and test adequacy. Report P0/P1/P2 findings first with file/line references and concrete fixes. If there are no blocking findings, say so plainly and list residual risks.
