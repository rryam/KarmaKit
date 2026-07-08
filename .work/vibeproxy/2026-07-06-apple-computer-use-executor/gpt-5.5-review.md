{
  "findings": [
    {
      "severity": "high",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 560,
      "title": "Execution consent is bound only to actionID, not to the reviewed dry-run plan",
      "description": "The execute path gates `.computerUse(actionID:)`, then calls `backend.plan(request)` after consent and executes that fresh plan. The consent fingerprint for computer use is `fingerprint([\"computer-use\", actionID])`, so a receipt does not bind the user’s consent to the exact typed plan, plan digest, evidence requirements, request ID, or any user-reviewed dry-run output. A backend or policy drift between dry-run and execute can cause a different plan to be executed under the same consent.",
      "concrete_fix": "Make execution consume an approved immutable plan, or bind consent to a plan digest. For example: produce a dry-run `planDigest`; require execute requests to include `approvedPlan` and `approvedPlanDigest`; compute the consent requirement from `[\"computer-use\", actionID, approvedPlanDigest]`; reject execution if the supplied plan digest differs; do not re-plan during execution unless the newly produced plan digest exactly matches the approved digest."
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 667,
      "title": "Evidence requirements are controlled by the same backend that performs execution",
      "description": "`evidenceFailure(plan:evidence:)` only checks the `requiredEvidence` list returned by `backend.plan`. A compromised or buggy backend can return an empty `requiredEvidence` array or omit important evidence kinds, causing execution to be accepted with little or no evidence. This weakens the claimed consent-gated execution audit trail.",
      "concrete_fix": "Derive minimum required evidence from trusted policy rather than from the backend alone. Enforce a baseline such as screenshot or user-visible-state evidence for every execute request, reject empty evidence requirements unless explicitly allowed by policy, validate uniqueness of required kinds, and include the required evidence policy in the consent fingerprint or approved plan digest."
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 144,
      "title": "Consent receipt replay protection is process-local and non-durable",
      "description": "`CoreAgentAppleConsumedConsentReceipts` stores consumed receipt keys only in memory inside a single `CoreAgentAppleActionGate` instance. The same valid receipt can be replayed after process restart, in another process, or through another gate instance with the same signing key and sandbox configuration. The code exposes `reusedConsentReceipt`, implying single-use semantics that are not actually enforceable across realistic executor lifetimes.",
      "concrete_fix": "Inject a durable, atomic consent receipt store keyed by issuer, receipt ID, authority boundary, policy version, capability, and request fingerprint. Persist consumed nonces until receipt expiry, use compare-and-insert semantics to prevent races across processes, and document whether receipts are single-use or multi-use. If multi-use receipts are intended, remove or rename the current replay logic to avoid a false security guarantee."
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 451,
      "title": "Computer-use requests and plans lack structural validation",
      "description": "`CoreAgentAppleComputerUseRequest`, `CoreAgentAppleComputerUsePlan`, and `CoreAgentAppleComputerUsePlanStep` accept empty or unbounded identifiers, empty plans, duplicate step IDs, duplicate evidence kinds, and arbitrary large strings. These fields are used in fingerprints, audit records, plan digests, and backend dispatch. Malformed or oversized values can produce ambiguous audits, denial-of-service memory pressure, or consent prompts for meaningless actions such as an empty `actionID`.",
      "concrete_fix": "Add explicit validators before gating and before returning plans. Require non-empty bounded `request.id`, `actionID`, step IDs, and summaries; define allowed character sets or canonical normalization; reject empty execute plans; reject duplicate step IDs and duplicate required evidence kinds; cap array sizes and string lengths; return typed validation failures before calling the backend."
    },
    {
      "severity": "medium",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 486,
      "title": "Dry-run purity is not enforced by the backend abstraction",
      "description": "The dry-run path avoids `backend.execute`, but `backend.plan` is an arbitrary async closure and may still inspect live UI state, invoke platform automation, mutate state, or perform network/file effects. The test asserts no execute call occurred, but the type system does not prevent side effects during planning. This is important because dry-run requires no consent.",
      "concrete_fix": "Split the planning interface from execution-capable backends more strongly. Make the dry-run planner a pure planner over typed inputs or snapshots, not a closure with access to execution machinery. If live state inspection is required, model it as explicit evidence/snapshot capture with its own capability and consent policy. At minimum document that `plan` must be side-effect-free and add test fakes that fail if side-effect APIs are reachable from planning."
    },
    {
      "severity": "low",
      "file": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift",
      "line": 628,
      "title": "Cancellation during backend execution can still report executed success",
      "description": "The executor checks cancellation before planning and before execution, but not immediately after `await backend.execute`. If the task is cancelled while the backend is executing and the backend returns evidence anyway, the executor may validate evidence and report `.executed`. This can produce misleading audit status for a cancelled user operation.",
      "concrete_fix": "Check `Task.isCancelled` immediately after `backend.execute` returns and before evidence validation. Return `.failed(.cancelled)` while preserving any collected evidence in the audit if useful. Also consider requiring cooperative cancellation behavior in `CoreAgentAppleComputerUseBackend.execute` documentation."
    }
  ],
  "residual_risks": [
    "This foundation only gates typed planning and execution. It does not sandbox, mediate, or verify raw Accessibility, screen capture, input injection, file, or network effects performed by an actual backend implementation.",
    "Evidence digests prove only that the backend returned strings with valid SHA-256 formatting. They do not prove that screenshots or accessibility trees were captured honestly, freshly, from the intended authority boundary, or before/after the claimed action.",
    "The HMAC-based consent receipts rely on symmetric key secrecy and correct key distribution. Any component with the signing key can both issue and verify receipts.",
    "Consent fingerprints are length-prefixed strings rather than opaque cryptographic hashes. They are signed, but they may leak action identifiers and may be awkward to use safely in external consent UIs or logs.",
    "Audit records are returned to the caller but are not durably stored, signed, chained, or made tamper-evident by this code."
  ],
  "testing_gaps": [
    "Add a test proving execute consent is rejected when the approved dry-run plan digest differs from the execution plan digest after the recommended fix.",
    "Add tests for replaying the same receipt across two `CoreAgentAppleActionGate` instances and, if durable storage is added, across process/store boundaries.",
    "Add tests for empty and malformed `request.id`, empty `actionID`, oversized strings, empty plans, duplicate step IDs, and duplicate required evidence kinds.",
    "Add tests that execute fails when policy-mandated baseline evidence is missing even if the backend plan declares no required evidence.",
    "Add tests for stale evidence timestamps, future evidence timestamps, and evidence captured outside the execution interval if freshness checks are added.",
    "Add cancellation tests where cancellation happens while `backend.plan` is suspended and while `backend.execute` is suspended.",
    "Add consent validation tests for wrong issuer, wrong signing key, tampered receipt fields, missing expiry, future `grantedAt`, expired receipt, policy version mismatch, authority boundary mismatch, capability mismatch, and request fingerprint mismatch.",
    "Add tests confirming dry-run planning cannot reach execution-only side-effect hooks once the planner/executor separation is strengthened."
  ]
}