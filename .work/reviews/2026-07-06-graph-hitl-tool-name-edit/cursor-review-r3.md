## Verdict

**No P0 blocking findings** for the stated graph-level HITL tool-name edit contract. The resolver, digest binding, identity split, fail-closed errors, and native args-only rejection are implemented coherently and are well covered by typed tests.

There is **one P1 API-safety gap** and several **P1/P2 residual risks** around downstream execution, defense-in-depth coverage, and operational footguns.

---

## P1

### 1. Public `CoreAgentDeepHITLExecutableAction` init is not release-safe fail-closed

```161:174:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    if let editedTargetAuthorization {
      precondition(
        editedTargetAuthorization.reviewedActionName == effectiveRequestedName,
        "Edited-target authorization must match the requested action name."
      )
      precondition(
        editedTargetAuthorization.editedActionName == name,
        "Edited-target authorization must match the executable action name."
      )
    }
    precondition(
      effectiveRequestedName == name || editedTargetAuthorization != nil,
      "Retargeted executable actions require edited-target authorization."
    )
```

**Problem:** Retarget invariants are enforced with `precondition`, not thrown errors. In release builds, a downstream executor or test helper can construct a retargeted executable action without `editedTargetAuthorization` and bypass the contract outside `CoreAgentDeepHITLBatchResolver`.

**Fix:** Make construction resolver-only (`internal`/`package` init), or replace preconditions with a throwing factory such as `makeExecutableAction(...)` that returns `editedToolNameNotAllowed` / a new `missingEditedTargetAuthorization` error.

---

### 2. Retarget authorization stops at resolution; executable dispatch/auth is still out of band

```547:572:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
        guard boundAction.config.allowedEditedActionNames.contains(editedAction.name) else {
          throw CoreAgentDeepHITLError.editedToolNameNotAllowed(
            reviewed: action.name,
            edited: editedAction.name,
            allowedEditedActionNames: boundAction.config.allowedEditedActionNames
          )
        }
        editedTargetAuthorization = CoreAgentDeepHITLEditedTargetAuthorization(
          reviewedActionName: action.name,
          editedActionName: editedAction.name,
          allowedEditedActionNames: boundAction.config.allowedEditedActionNames,
          reviewedActionIdentity: boundAction.identity
        )
```

**Problem:** This slice correctly proves policy + identity, but does not enforce that a graph executor:
1. dispatches `executableName`, not `requestedName`
2. runs `CoreAgentToolPolicy` against the retargeted manifest/args
3. requires `editedTargetAuthorization` when `executableName != requestedName`

That is documented as intentional (`CoreAgentDeep-Runtime.md`), but it is still a real authorization gap until downstream wiring exists.

**Fix:** In the graph tool executor / receipt path (outside this slice), fail closed unless:
- `action.executableName == action.requestedName`, or
- `action.editedTargetAuthorization` is present and matches `requestedName`/`executableName`, and policy authorizes the target manifest.

**Test gap:** `graphResumeReturnsAllowedRetargetExecutableEvidence` only proves resolution fields, not executor behavior.

---

## P2

### 3. Native adapter post-resolution retarget guard appears unreachable and untested

```313:318:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
      guard rule.allowedEditedActionNames.isEmpty else {
        throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
          reviewed: request.manifest.name,
          edited: rule.allowedEditedActionNames.sorted().joined(separator: ",")
        )
      }
```

```374:378:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
        guard action.name == action.requestedName else {
          throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
            reviewed: action.requestedName,
            edited: action.name
          )
        }
```

**Problem:** Current flow makes `374-378` hard to reach:
- non-empty rule allowlist fails before reviewer
- empty allowlist means resolver rejects retarget first

So the second guard is defense-in-depth only, with no direct test.

**Fix:** Add a focused unit test that feeds a crafted `.execute` retarget resolution into `toolInterventionDecision` via a package-visible test hook, or extract that mapping into a testable package function.

---

### 4. Native/per-call HITL rejects any non-empty allowlist, even for same-tool-only edits

```409:414:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
    guard rule.allowedEditedActionNames.isEmpty else {
      throw CoreAgentDeepHITLError.editedToolNameUnsupportedForNativeAdapter(
        reviewed: request.manifest.name,
        edited: rule.allowedEditedActionNames.sorted().joined(separator: ",")
      )
    }
```

**Problem:** A host cannot share one `CoreAgentDeepHITLRule` between graph retarget-capable review and native governed-tool HITL. Any non-empty `allowed_edited_action_names` disables native interruption entirely, including args-only edits.

This matches the contract, but it is an operational footgun.

**Fix:** Document host rule splitting explicitly in runtime docs, or split config into graph-only vs native-only surfaces.

---

### 5. `editedToolNameUnsupportedForNativeAdapter.edited` is overloaded semantically

At rule-config rejection, `edited` carries the joined allowlist, not an actual edited tool name (`CoreAgentDeepHITL.swift:410-413`, `CoreAgentDeepHITLBatch.swift:315-316`). Tests assert this shape (`CoreAgentDeepHITLTests.swift:161-165`), but the field name is misleading for logging/telemetry.

**Fix:** Add a dedicated case like `editedTargetPolicyUnsupportedOnNativeAdapter(allowlist:)` or rename payload field in a future API revision.

---

### 6. No schema/manifest validation for retargeted executable args

Resolver accepts arbitrary `editedAction.name` / `editedAction.argsJSON` if allowlisted. Wrong-schema args for the target tool will only fail later, if at all.

**Fix:** Downstream executor should validate target manifest/schema before authorization/execution.

---

### 7. Case-sensitive exact-name allowlist only

`allowedEditedActionNames.contains(editedAction.name)` is exact string match. No normalization test for case/alias collisions.

**Fix:** Document exact-match semantics; add test if product wants canonical tool-name normalization.

---

## Contract checklist

| Contract requirement | Status | Evidence |
|---|---|---|
| Retarget only when same-index config allowlists target | Met | `CoreAgentDeepHITLBatch.swift:544-552` |
| Allowlist participates in reviewed identity digest | Met | `CoreAgentDeepHITLBatch.swift:605-614`; test `editedTargetPolicyParticipatesInActionIdentity` |
| Reviewed vs executable identity split | Met | `CoreAgentDeepHITLExecutableAction` fields + tests `sameToolEdits...`, `allowedRetargetedEdits...` |
| Same-tool arg edits need no allowlist | Met | `CoreAgentDeepHITLBatch.swift:544-545` |
| Disallowed retarget fails closed before executable action | Met | `editedToolNameNotAllowed`; test `retargetedEditDecisionsRequireExplicitEditedTargetPolicy` |
| Native governed HITL does not silently retarget | Met | `CoreAgentDeepHITLPolicy` + native adapter rule guard + args-only mapping |
| Tests assert typed contracts, not prose | Mostly met | Strong resolver/error coverage; graph summary strings are secondary |

---

## What looks correct

**Digest binding is solid.** Identity includes action request, same-index config, allowed decisions, allowlist, and description under `digestVersion=1`:

```605:614:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    let payload = DigestPayload(
      digestVersion: 1,
      actionName: action.name,
      argsJSON: action.argsJSON,
      description: action.description,
      toolCallID: action.toolCallID,
      configActionName: config.actionName,
      allowedDecisions: config.allowedDecisions.map(\.rawValue).sorted(),
      allowedEditedActionNames: config.allowedEditedActionNames.sorted(),
      configDescription: config.description
    )
```

**Replay/idempotency controls are good for this slice:**
- interrupt ID mismatch re-interrupts instead of applying stale decisions
- malformed resume throws `invalidBatchResumeValue`
- digest / toolCallID / count / duplicate-decision checks fail closed
- positional binding prevents cross-action decision swapping

**Codable compatibility is handled well:**
- `allowed_edited_action_names` decodes as `[]` when absent
- legacy JSON test in `reviewConfigCodablePreservesEditedTargetAllowlists`

**Swift 6 / concurrency:** Public batch/HITL types are `Sendable`; reviewer protocols are `Sendable`; predicate cache is an actor. No obvious data-race issues in this slice.

---

## Test adequacy

**Strong coverage**
- allowlist required / forbidden retarget
- digest sensitivity to allowlist changes
- same-tool edit without authorization object
- native adapter fail-closed before reviewer when allowlist present
- per-call native policy fail-closed on allowlist
- typed `CoreAgentDeepHITLError` assertions
- legacy Codable compatibility

**Gaps**
- no direct test of native adapter post-resolution retarget rejection (`374-378`)
- no downstream executor test proving retargeted `executableName` is what policy authorizes/executes
- no test for empty/invalid edited target names
- no test for shared-rule operational conflict beyond native rejection

---

## Residual risks

1. **Trust boundary is the graph node’s bundle reconstruction**, not the interrupt payload alone. That is acceptable if the human/UI binds decisions to issued identities/digests, which the resolver enforces.
2. **Graph resolver intentionally does not prove target tool existence or arg schema validity.**
3. **Release-build `precondition` on `CoreAgentDeepHITLExecutableAction` is the main in-slice correctness hole.**
4. **Formal adversarial review / full-package verification for L31 are still pending per the task ledger.**

If you want, I can turn the P1 items into a minimal follow-up test/fix plan without editing code.
