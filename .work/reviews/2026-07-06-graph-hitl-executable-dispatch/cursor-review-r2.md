## Verdict: **CONDITIONAL GO**

The L32 slice delivers the stated boundary: manifest lookup by `executableName`, fail-closed duplicate/missing manifest handling, executable-target policy authorization, `CoreAgentToolInvocation.current` bound to the executable manifest, deterministic invocation IDs, and redacted audit evidence. Docs correctly state this is **not** automatic `CoreAgentSession` receipt emission.

One **P1 contract bug** and several **test/documentation gaps** should be fixed before hosts treat `CoreAgentDeepHITLExecutedAction` digests as receipt-correlatable with the rest of CoreAgent.

---

## CRITICAL

None in this slice.

---

## IMPORTANT

### 1. Argument digests diverge from the CoreAgent audit contract (P1)

The executor hashes **raw JSON strings**; the rest of CoreAgent hashes **`GeneratedContent.jsonString`** via `CoreAgentArgumentAudit.digest`.

```121:122:Sources/CoreAgentDeep/CoreAgentDeepHITLExecution.swift
    let requestedArgumentsDigest = Self.jsonDigest(action.requestedArgsJSON)
    let executableArgumentsDigest = Self.jsonDigest(action.executableArgsJSON)
```

Governed native tools do this instead:

```362:362:Sources/CoreAgent/CoreAgentPolicy.swift
    let requestedArgumentsDigest = CoreAgentArgumentAudit.digest(arguments)
```

**Why it matters:** Hosts wiring graph HITL execution into run receipts will compare `executableArgumentsDigest` / `requestedArgumentsDigest` against session/tool events. Whitespace, key order, or `GeneratedContent` normalization can make semantically identical args produce different digests. The deterministic `invocationID` is also derived from the raw-string digest, so it can disagree with any downstream digest computed from `result.request.arguments`.

**Fix:** After parsing, compute both digests with `CoreAgentArgumentAudit.digest(requestedArguments)` / `.digest(arguments)`, and feed the **executable** canonical digest into `invocationID(...)`. Add a test that proves `result.executableArgumentsDigest == CoreAgentArgumentAudit.digest(result.request.arguments)`.

---

### 2. `invalidRequestedArguments` is implemented but untested (P2)

```109:114:Sources/CoreAgentDeep/CoreAgentDeepHITLExecution.swift
    let requestedArguments: GeneratedContent
    do {
      requestedArguments = try GeneratedContent(json: action.requestedArgsJSON)
    } catch {
      throw CoreAgentDeepHITLError.invalidRequestedArguments(toolName: action.requestedName)
```

Malformed executable args are tested; malformed **requested** args are not. That path is reachable if a persisted graph checkpoint carries a corrupt `action_requests[].args_json` while the edited executable args remain valid.

**Fix:** Add a test with `requestedArgsJSON: "not-json"` (valid executable args) asserting `invalidRequestedArguments` and that policy/backend are never called.

---

### 3. `CoreAgentDeepHITLExecutedAction` omits `source` (P2)

`CoreAgentDeepHITLExecutableAction` carries `source: .approve | .edit`, but the executed result does not:

```144:157:Sources/CoreAgentDeep/CoreAgentDeepHITLExecution.swift
    return CoreAgentDeepHITLExecutedAction(
      output: output,
      request: request,
      manifest: manifest,
      graphToolCallID: action.toolCallID,
      requestedName: action.requestedName,
      executableName: action.executableName,
      ...
      reviewedActionIdentity: action.reviewedActionIdentity,
      editedTargetAuthorization: action.editedTargetAuthorization
    )
```

Docs say hosts must emit their own audit path. Without `source`, a host that persists only `ExecutedAction` cannot distinguish approved vs edited execution or set `arguments_source`-style receipt fields consistently with native HITL.

**Fix:** Forward `action.source` (or an explicit `argumentsSource` string) on `CoreAgentDeepHITLExecutedAction` and test preservation on retargeted edits.

---

## MINOR

### 4. Invocation-identity test coverage is partial

Tests prove stability and change-on-executable-args, but not change when **run ID**, **graph `toolCallID`**, or **manifest digest** changes. Docs claim all four inputs; only one is exercised.

### 5. Retarget authorization evidence is not asserted in execution tests

`retargetedAction()` produces `editedTargetAuthorization`, but no execution test checks `result.editedTargetAuthorization` / `result.reviewedActionIdentity`. Regression risk for the L31→L32 handoff.

### 6. Approve-path execution is untested here

All execution tests go through retargeted `.edit`. A same-tool `.approve` smoke test would confirm the executor works when `requestedName == executableName` and `editedTargetAuthorization == nil`.

### 7. No cancellation/timeout wrapper

Unlike `CoreAgentGovernedTool`, the executor does not call `Task.checkCancellation()` or honor execution timeouts. Acceptable for this slice if documented as host/backend responsibility; worth noting for long-running graph backends.

### 8. `CoreAgentDeepHITLPredicateCache` (out of L32 scope)

`CoreAgentDeepHITL.swift` was in the file list but the L32 addition is mainly error cases. Any predicate-cache growth on abandoned interrupts is pre-existing, not introduced by executable dispatch.

---

## What looks correct

| Requirement | Evidence |
|---|---|
| Executable manifest, not reviewed tool | Manifest lookup by `action.executableName`; policy test denies `append_file` when only `write_file` is allowed |
| Invocation context bound to executable target | Test asserts `CoreAgentToolInvocation.current?.toolName` and `manifestDigest` |
| Duplicate manifests fail closed | Construction test |
| Missing manifest / bad executable JSON fail before backend | Tests with `RecordingPolicy` / `RecordingGraphActionBackend` |
| Deterministic invocation ID | Same inputs → same ID; different executable args → different ID |
| Redacted evidence, no raw secrets | Test with `api_key` / `password` |
| Action construction guarded | `CoreAgentDeepHITLExecutableAction` init is `fileprivate` in `CoreAgentDeepHITLBatch.swift` |
| Docs: no automatic session receipts | ```175:177:Documentation/CoreAgentDeep-Runtime.md``` |

Execution order is sound: manifest → JSON parse → digest → request build → `policy.authorize` → `withCurrent` → backend.

---

## FIXES REQUIRED

1. **P1:** Align digests (and invocation-ID input) with `CoreAgentArgumentAudit.digest` on parsed `GeneratedContent`.
2. **P2:** Test `invalidRequestedArguments` fail-closed before policy/backend.
3. **P2:** Surface `source` (or equivalent) on `CoreAgentDeepHITLExecutedAction` for host receipt mapping.
4. **P2:** Add tests for identity inputs (run ID, tool call ID, manifest digest) and authorization-evidence passthrough.

---

## RESIDUAL RISK

- **Host integration:** Receipt parity, timeouts, and schema validation remain host responsibilities; the slice correctly does not claim otherwise.
- **Backend trust:** The backend receives the full `CoreAgentDeepHITLExecutableAction`, including raw `requestedArgsJSON`; a logging backend could leak pre-redaction secrets. Mitigation is trusted host code.
- **TaskLocal propagation:** Same limitation as governed tools—child tasks spawned by the backend may not inherit `CoreAgentToolInvocation.current`.

---

**Bottom line:** Ship the boundary as designed after fixing digest canonicalization (P1). Without that, audit correlation with `CoreAgentSession` / `CoreAgentGovernedTool` events is not a durable contract. The rest are test and receipt-field gaps, not architectural blockers.
