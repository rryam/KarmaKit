# VibeProxy Adjudication: HITL Batch Adapter

Date: 2026-07-06
Scope: `CoreAgentDeep` portable native tool batch HITL adapter and direct HITL predicate fix.

## Inputs

- Text review prompt: `.work/vibeproxy/2026-07-06-hitl-batch-adapter/prompt.md`
- Text review responses:
  - `gpt-5.5.md`
  - `gemini-3.5-flash-low.md`
  - `claude-haiku-4-5-20251001.md`
- Multimodal smoke responses:
  - `multimodal-gpt-5.5.json`
  - `multimodal-gemini-3.5-flash-low.json`
  - `multimodal-claude-haiku-4-5-20251001.json`

## Reviewer Outcomes

- `gpt-5.5`: PASS. No blocking findings.
- `gemini-3.5-flash-low`: BLOCK before adjudication. Two compile findings were stale/false against the live tree; one predicate-bypass finding was valid.
- `claude-haiku-4-5-20251001`: BLOCK before adjudication. Findings were either contradicted by current graph tests/design contracts or non-blocking style concerns; the single-tool predicate gap overlapped with Gemini's valid finding and was fixed.

## Valid Finding Fixed

Gemini correctly found that `CoreAgentDeepHITLPolicy.decide(_:)` could be called directly and bypass a conditional `CoreAgentDeepHITLRule` predicate. The fix adds a predicate precheck cache:

- Normal CoreAgent flow still evaluates the predicate once in `shouldIntervene(_:)`.
- Direct `decide(_:)` calls now evaluate the predicate and approve without consulting the reviewer when it returns `false`.
- Regression: `directDecisionHonorsConditionalPredicate`.
- Non-regression: `predicateIsEvaluatedOnce`.

## Findings Rejected

- Gemini compile finding for `.respond(Prompt(message))`: rejected. Live code uses `Prompt(output.message)`.
- Gemini guard-exit finding for `requestDeepHITLReview`: rejected. `interrupt` is a throwing control-flow API and local compile verification accepts the guard.
- Haiku wrong-interrupt-ID finding: rejected for `requestDeepHITLReview`. At graph runtime level, a resume command for another interrupt ID re-interrupts the current pending node so multi-interrupt routing can continue. Resolver-level wrong-ID calls still fail closed through `CoreAgentDeepHITLBatchResolver.resolve`.
- Haiku mutable-array concurrency finding: rejected. The local array is not shared across concurrency domains and is mutated only after `await reviewer.decide(...)` returns.
- Haiku digest-config finding: rejected. The digest intentionally binds action identity to the same-index review config so a resume cannot reuse a prior action identity under a different allowed-decision policy.
- Haiku single-tool digest-binding finding: rejected as stated. The single-tool reviewer API returns only a decision for the supplied `CoreAgentToolRequest`; it cannot retarget to another tool name. Edit validation remains args-only through `GeneratedContent` on the original request path.

## Multimodal Smoke

The first PNG fixture was too small/pathological and was rejected by GPT and Haiku. The final verified fixture is `multimodal-rgb.png`, a locally validated 32x32 RGB PNG. All three model families accepted the text-plus-image request over `http://127.0.0.1:8320/v1/chat/completions`:

| Model | HTTP | Result |
| --- | --- | --- |
| `gpt-5.5` | 200 | `modality-ok: the image is a solid red square.` |
| `gemini-3.5-flash-low` | 200 | `modality-ok: I can see the solid red square image.` |
| `claude-haiku-4-5-20251001` | 200 | `modality-ok: I can see the 32x32 RGB PNG image showing a red square.` |

No audio/video endpoint was exposed by the discovered VibeProxy OpenAI-compatible gateway. Treat the current evidence as text plus image-input coverage for this slice, not proof of unsupported modalities.

## Required Follow-Up Before PR Readiness

- Rerun focused Swift tests after the predicate fix.
- Rerun full package tests/build/diff checks.
- Run fresh adversarial review on the full branch diff before opening a PR, because this VibeProxy panel only reviewed the HITL batch adapter slice.
