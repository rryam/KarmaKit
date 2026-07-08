Re-review only the final CoreAgentDeep graph-level HITL tool-name edit slice after the last P1 fix.

Repo path: /Users/basitmustafa/Documents/GitHub/coreagent

Focus files:
- /Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Tests/CoreAgentDeepTests/CoreAgentDeepHITLTests.swift
- /Users/basitmustafa/Documents/GitHub/coreagent/Documentation/CoreAgentDeep-Runtime.md

Previous Cursor P1 was that `CoreAgentDeepHITLExecutableAction` had a public initializer with `precondition`-enforced retarget invariants. It is now `fileprivate`, so only this resolver file can construct it.

Please report only remaining P0/P1 blockers for this slice, especially anything still allowing invalid retarget execution, stale resume replay, malformed resume acceptance, or native args-only retarget leakage. If none remain, say that clearly.
