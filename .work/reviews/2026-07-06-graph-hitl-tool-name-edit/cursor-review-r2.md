## Verdict

**No P0 or P1 blocking findings** in this slice. The graph batch resolver implements the stated authorization contract: same-index allowlist gating, digest-bound replay protection, requested vs executable identity separation, fail-closed disallowed retargets, and native adapter rejection at the args-only `Tool.call` boundary. Tests are largely contract-driven and cover the critical paths.

Residual risks are mostly integrator/downstream enforcement and a few P2 hardening/ergonomics gaps.

---

## Contract compliance (verified)

| Requirement | Status | Evidence |
|---|---|---|
| Retarget only when same-index config lists target | Met | ```524:529:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` |
| Allowlist in action identity digest | Met | ```582:591:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` |
| Stale resume fails on policy change | Met | Test `editedTargetPolicyParticipatesInActionIdentity` |
| Requested vs executable identity | Met | ```135:184:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` |
| Same-tool arg edits without allowlist | Met | ```521:522:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` + test `sameToolEditsKeepReviewedIdentityWithoutRetargetAuthorization` |
| Disallowed retarget fails before executable actions | Met | ```524:529:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` (throws inside `map` before returning resolutions) |
| Native adapter fails closed on retarget | Met | ```364:368:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift``` + test `nativeBatchAdapterRejectsRetargetedEditsAtArgsOnlyToolBoundary` |
| Per-call native policy fails closed on allowlist config | Met | ```403:407:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift``` + `CoreAgentDeepHITLTests` |

Authorization chain is sound: positional binding → `toolCallID` match → `actionDigest` match → per-action `allowedDecisions` → retarget allowlist → typed `CoreAgentDeepHITLEditedTargetAuthorization` snapshot at resolve time (not resume-forgeable).

```471:494:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
  private static func validate(
    decision: CoreAgentDeepHITLBatchDecision,
    for boundAction: BoundAction
  ) throws {
    guard decision.action.toolCallID == boundAction.identity.toolCallID else {
      throw CoreAgentDeepHITLError.decisionActionMismatch(...)
    }
    guard decision.action.actionDigest == boundAction.identity.actionDigest else {
      throw CoreAgentDeepHITLError.decisionActionDigestMismatch(...)
    }
    ...
  }
```

---

## P0

**None.**

---

## P1

**None** for in-slice authorization, replay, or native-boundary execution paths.

Notes on items that look like P1 but are not:

- **`requestDeepHITLReview` re-interrupts on wrong/missing resume** (```622:626:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift```) is intentional graph routing; mismatch is still fail-closed at resolver when IDs/decisions don’t line up (test `resumeInterruptIDMustMatchPendingReview`).
- **Native batch adapter calls reviewer before rejecting retarget** is deliberate: the graph resolver authorizes retarget; the native adapter only blocks execution at the FM boundary. Execution cannot slip through (```364:368:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift```).
- **No in-slice graph executor** that dispatches on `executableName` is by design (documented in ```161:164:Documentation/CoreAgentDeep-Runtime.md```); that’s a follow-on integrator obligation, not a hole in this slice.

---

## P2

### 1. `duplicateActionRequest` is enforced but untested

```453:455:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
      guard seenToolCallIDs.insert(action.toolCallID).inserted else {
        throw CoreAgentDeepHITLError.duplicateActionRequest(toolCallID: action.toolCallID)
      }
```

**Fix:** Add a resolver test with two `actionRequests` sharing a `toolCallID`.

### 2. No graph E2E test for allowed retarget through `requestDeepHITLReview`

Resolver-level coverage exists (`allowedRetargetedEditsPreserveReviewedAndExecutableIdentities`), but there is no interrupt → resume → node-output test proving graph integration uses `executableName` and carries authorization.

**Fix:** Extend `makeBatchGraph` resume path with `retargetableReviewBundle()` and assert node output contains `append_file` plus authorization fields via `summary` or direct resolution inspection.

### 3. Malformed resume decode is silently treated as “no resume”

```622:623:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    guard let encodedResume = command?.resumeValue,
      let resume = try? encodedResume.decode(as: CoreAgentDeepHITLBatchResume.self),
```

Corrupt resume payloads re-interrupt instead of surfacing a typed decode error.

**Fix:** If `resumeValue` is present but decode fails, throw a dedicated `CoreAgentDeepHITLError` (or propagate decode error) before re-interrupting.

### 4. `CoreAgentDeepHITLExecutableAction` public initializer is a downstream footgun

```157:179:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    let effectiveRequestedName =
      requestedName ?? editedTargetAuthorization?.reviewedActionName ?? name
    ...
    if let editedTargetAuthorization {
      precondition(...)
    }
```

Manual construction with `name != requestedName` and no `editedTargetAuthorization` collapses reviewed identity; `precondition` is not a durable release contract.

**Fix:** Require explicit `requestedName`/`requestedArgsJSON` when `name !=` reviewed name, or restrict retarget construction to an internal/package factory used only by the resolver.

### 5. Non-`edit` decisions do not reject stray `editedAction` in resume

`validate` does not require `editedAction == nil` for `.approve`/`.reject`/`.respond`. Execution is unaffected (approve always uses original action), but resume shape is looser than necessary.

**Fix:** Add shape validation: `editedAction` required iff `.edit`; forbidden otherwise.

### 6. Event projection slim actions omit `allowedEditedActionNames` (adjacent audit surface)

```819:824:Sources/CoreAgentDeep/CoreAgentDeepEventProjection.swift
      CoreAgentDeepGraphInterruptActionProjectedEvent(
        toolCallID: action.toolCallID,
        actionName: action.name,
        allowedDecisions: config.allowedDecisions
      )
```

Not an auth bypass (full `reviewBundle` remains in interrupt evidence), but UIs reading only projected actions won’t see retarget policy.

**Fix:** Follow-up slice: add `allowedEditedActionNames` to `CoreAgentDeepGraphInterruptActionProjectedEvent`.

### 7. Native batch vs per-call policy asymmetry on allowlist configuration

- Per-call `CoreAgentDeepHITLPolicy`: non-empty `allowedEditedActionNames` fails **before** reviewer (```403:407:Sources/CoreAgentDeep/CoreAgentDeepHITL.swift```).
- Native batch adapter: allowlist flows into review bundle, reviewer runs, retarget fails at execution boundary.

Fail-closed for execution, but side-effecting reviewers can run for unsupported native retarget.

**Fix:** Optional early guard in `CoreAgentDeepNativeToolBatchHITLAdapter.decide` mirroring per-call policy when any interrupted rule has non-empty allowlist—or document that native hosts must not configure allowlists unless using graph execution.

---

## What looks correct (high signal)

**Digest binding includes policy** (`digestVersion: 1`, allowlist, decisions, description):

```582:591:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
    let payload = DigestPayload(
      digestVersion: 1,
      ...
      allowedEditedActionNames: config.allowedEditedActionNames.sorted(),
      configDescription: config.description
    )
```

**Codable backward compatibility** for missing `allowed_edited_action_names` → empty set → retargets fail closed (test `reviewConfigCodablePreservesEditedTargetAllowlists`).

**Synthetic approve/edit at native boundary** already fails closed (not silent approve):

```378:382:Sources/CoreAgentDeep/CoreAgentDeepHITLBatch.swift
      case .approve, .edit:
        throw CoreAgentDeepHITLError.invalidSyntheticBatchDecision(...)
```

**Swift 6 / concurrency:** Resolver is stateless; public types are `Sendable`; batch reviewer is `Sendable`; no shared mutable resolver state on the retarget path.

**Test adequacy:** Strong on typed errors, digest replay, same-tool vs retarget identity, native boundary rejection, config/bundle invariants, and node-scoped interrupt IDs. Gaps are `duplicateActionRequest` and graph E2E retarget.

---

## Residual risks (acceptable for this slice; document for integrators)

1. **Downstream executor must dispatch on `executableName`** and attach `editedTargetAuthorization` to receipts; this slice does not enforce that.
2. **Allowlist is policy-only** — no tool-registry/manifest validation at HITL boundary.
3. **Retarget args are not schema-validated** against the target tool at resolve time.
4. **L31 formal adversarial review / full-package verification** still pending per task ledger.

---

## Recommended follow-ups before merge

1. Add tests for `duplicateActionRequest` and graph E2E allowed retarget.
2. Consider typed failure for malformed resume decode in `requestDeepHITLReview`.
3. Tighten `CoreAgentDeepHITLExecutableAction` construction API for retarget cases.
4. Run formal Cursor/`agy` review on the net diff (ledger L31).
