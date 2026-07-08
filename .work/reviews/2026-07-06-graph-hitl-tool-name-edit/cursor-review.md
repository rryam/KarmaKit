## Verdict

**No P0 blocking findings.** The slice implements the stated contract in `CoreAgentDeepHITLBatchResolver` and fails closed at the native adapter boundary. Resolver authorization, digest binding, identity separation, and typed errors are coherent.

**No P1 security/authorization holes** in the in-scope paths reviewed. Residual risks are mostly test/audit-surface gaps and downstream enforcement left to hosts (by design).

---

## Contract compliance (summary)

| Requirement | Status | Evidence |
|---|---|---|
| Retarget only when same-index config lists target in `allowed_edited_action_names` | Met | ```507:512:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` |
| Allowlist participates in action digest (stale resume fails on policy change) | Met | ```565:573:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` + test at ```233:256:Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift``` |
| `CoreAgentDeepHITLExecutableAction` separates requested vs executable identity | Met | ```135:170:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` |
| Same-tool arg edits work without allowlist | Met | ```504:505:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift```; exercised in ```58:63:Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift``` |
| Disallowed retargets fail closed before executable actions | Met | ```507:512:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` + test ```171:194``` |
| Native adapter fails closed on retarget (no silent FM `Tool.call` retarget) | Met | ```349:355:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` + test ```543:577``` |
| Tests assert typed contracts, not prose | Mostly met | Tests throw/compare `CoreAgentDeepHITLError` and struct fields |

---

## P0

**None.**

---

## P1

**None in this slice’s authorization/replay paths.**

The previously flagged `requestDeepHITLReview` malformed-resume behavior is intentional graph routing (wrong/missing resume re-interrupts; resolver-level mismatch still fails closed). See ```603:613:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` and test ```114:149:Tests/CoreAgentDeepTests/CoreAgentDeepHITLBatchTests.swift```.

---

## P2

### 1. Dead error case: `editedToolNameMismatch` is never thrown

```46:46:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
  case editedToolNameMismatch(expected: String, actual: String)
```

Retarget policy now uses `editedToolNameNotAllowed` (```507:512:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift```). `editedToolNameMismatch` is orphaned API surface from the pre-retarget era.

**Fix:** Remove the case, or repurpose it for a distinct invariant (e.g. edited-action name must match decision’s reviewed action when you want stricter resume-shape validation). Add a test if kept.

---

### 2. Native adapter fail-open fallback on impossible synthetic branches

```358:366:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    case .syntheticToolOutput(let output):
      switch output.decision {
      case .reject:
        return .reject(Prompt(output.message))
      case .respond:
        return .respond(Prompt(output.message))
      case .approve, .edit:
        return .approve
      }
```

Resolver never emits synthetic `.approve`/`.edit` today, but this path silently approves if that ever changes.

**Fix:** `throw` a typed internal error (or `fatalError` in debug) for `.approve`/`.edit` synthetic cases.

---

### 3. `CoreAgentDeepHITLExecutableAction` public initializer can hide retargets if misconstructed

```162:163:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    self.requestedName = requestedName ?? name
    self.requestedArgsJSON = requestedArgsJSON ?? argsJSON
```

Manual construction with `name != requestedName` but omitted `requestedName` collapses reviewed identity.

**Fix:** Add a package-scoped factory used by the resolver; make the public initializer require `requestedName`/`requestedArgsJSON` when `editedTargetAuthorization != nil`, or add a `precondition`/`validate()` helper for downstream executors.

---

### 4. Test gaps for durable contracts

Missing focused coverage:

| Gap | Suggested test |
|---|---|
| `duplicateResumeDecision` | Two decisions with same `toolCallID` |
| `decisionActionDigestMismatch` on args tampering (not only policy change) | Same policy, altered `argsJSON` in bundle |
| Same-tool edit preserves `editedTargetAuthorization == nil` and `requestedArgsJSON != executableArgsJSON` | Explicit resolver assertion |
| Graph E2E retarget through `requestDeepHITLReview` | Interrupt → resume with allowed retarget → node output uses `executableName` + authorization |
| `CoreAgentDeepHITLReviewConfig` Codable round-trip for `allowed_edited_action_names` | Encode/decode stability |
| `reviewConfigActionMismatch` | Config `action_name` ≠ request name at same index |

Current coverage is strong on the happy retarget path (```196:231```), policy-in-digest replay (```233:256```), and native boundary rejection (```543:577```).

---

### 5. Digest payload is internal and unversioned

```585:594:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  private struct DigestPayload: Encodable {
    let actionName: String
    ...
```

Digest uses camelCase `JSONEncoder` keys with no schema version. Fine internally while resolver owns both sides; brittle if external reviewers must recompute digests.

**Fix:** Document digest schema in runtime docs, or add `digestVersion: 1` to `DigestPayload` before external consumers depend on it.

---

### 6. `CoreAgentDeepHITLRule.allowedEditedActionNames` is inert on single-tool `CoreAgentDeepHITLPolicy`

```412:421:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
    switch decision {
    case .approve:
      return .approve
    case .edit(let arguments):
      return .edit(arguments: arguments)
```

Per-call HITL remains args-only (documented in ```204:213:Documentation/CoreAgentDeep-Runtime.md```). Hosts setting allowlists on `interruptOn` rules for the non-batch policy may assume retarget works.

**Fix:** Optional runtime warning/assert when `allowedEditedActionNames` is non-empty on a rule used only by `CoreAgentDeepHITLPolicy`.

---

### 7. Event projection slim actions omit `allowedEditedActionNames` (out of scope file, audit ergonomics)

`CoreAgentDeepGraphInterruptActionProjectedEvent` projects only `allowedDecisions` (```350:365:Sources/CoreAgentDeep/CoreAgentDeepEventProjection.swift```). Full `reviewBundle` is still embedded in interrupt evidence, so this is not an authorization bypass—just a UI/trace ergonomics gap for retarget-capable reviews.

**Fix:** Add `allowedEditedActionNames` to projected per-action events when extending projection in a follow-up slice.

---

## What looks correct (high-signal)

**Authorization chain in resolver**

```454:477:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  private static func validate(...) throws {
    guard decision.action.toolCallID == boundAction.identity.toolCallID ...
    guard decision.action.actionDigest == boundAction.identity.actionDigest ...
    guard boundAction.config.allowedDecisions.contains(decision.type) ...
  }
```

Positional binding + digest + per-action allowed decisions is sound.

**Retarget evidence is typed and snapshot at resolve time**

```514:531:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
        editedTargetAuthorization = CoreAgentDeepHITLEditedTargetAuthorization(
          reviewedActionName: action.name,
          editedActionName: editedAction.name,
          allowedEditedActionNames: boundAction.config.allowedEditedActionNames,
          reviewedActionIdentity: boundAction.identity
        )
```

**Codable backward compatibility**

```154:156:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift
    self.allowedEditedActionNames = Set(
      try container.decodeIfPresent([String].self, forKey: .allowedEditedActionNames) ?? []
    )
```

Old bundles decode with empty allowlist → retargets fail closed. Good.

**Swift 6 / concurrency:** Resolver is stateless; batch types are `Sendable`; adapter/reviewer closures are `@Sendable`. No shared mutable resolver state. `CoreAgentDeepHITLPredicateCache` actor is outside this slice’s retarget path.

---

## Residual risks (acceptable for this slice, document for integrators)

1. **No in-slice executor gate** — `CoreAgentDeepHITLExecutableAction` exposes audit fields; graph nodes must dispatch on `executableName` and attach `editedTargetAuthorization` to receipts. The slice does not enforce that.
2. **Allowlist is policy-only, not registry-validated** — `allowed_edited_action_names` is not checked against a tool manifest registry; misconfiguration is a host concern.
3. **Retarget args are not schema-validated** against the target tool at HITL boundary.
4. **Formal adversarial review still pending** per ```43:43:Documentation/DeepAgents-Port-Task-Ledger.md``` (L31).

---

## Recommended next steps (if you ship this slice)

1. Add the P2 tests above (especially `duplicateResumeDecision` and same-tool identity separation).
2. Remove or rewire `editedToolNameMismatch`.
3. Harden native adapter synthetic `.approve`/`.edit` branch to fail closed.
4. Run formal Cursor/`agy` review on the net diff before PR merge (per ledger L31).
