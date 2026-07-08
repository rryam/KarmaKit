# CoreAgentApplePlatform Runtime

Date: 2026-07-06
Status: Apple adapter contract foundation with live persistence stores, deterministic interpreter, consent-gated helper interpreter backend boundary, computer-use executor foundation, App Intent donation invalidation, concrete App Intents bridge, and OS donation-manager bridge

`CoreAgentApplePlatform` is the optional Apple-only adapter target for platform
integration points that should not leak into the portable CoreAgent products.
This slice defines tested contracts for SwiftData checkpoint wrapping, platform
capability gating, App Intent exposure policy, SwiftUI/Observation run
projections, live `ModelContext` checkpoint stores, live SwiftData Engine
trace/issue persistence, live SwiftData graph checkpoint/store persistence, and
a bounded deterministic in-process code interpreter, and a typed computer-use
planning/execution foundation. It also defines typed App Intent donation
records and invalidation metadata for stable workflow/entity/run outcomes.
The sibling `CoreAgentAppIntents` target adds the first concrete Apple
`AppIntent` wrappers for run open/pause/continue plus OS donation-manager
bridging, mapped back through CoreAgent's descriptor/action-gate policy. This
is still not an OS sandbox, raw Accessibility/UI automation backend,
app-hosted `AppIntentsTesting` target, or Siri/Shortcuts/Spotlight runtime
proof.

## Implemented

- `CoreAgentSwiftDataCheckpointSnapshot`
  - Encodes a canonical `CoreAgentCheckpoint` as CoreAgent-owned JSON bytes.
    Dates use lossless `Date` coding rather than the default ISO-8601 strategy
    so sub-second checkpoint timestamps round trip exactly.
  - Stores indexed metadata beside those bytes: checkpoint ID, checkpoint key,
    authority boundary, policy version, checkpoint format, compatibility
    revision, save time, store time, and SHA-256 digest.
  - Binds the checkpoint ID/key, authority boundary, policy version, format,
    compatibility revision, save time, and canonical checkpoint bytes into the
    digest so SwiftData sidecar metadata cannot be replayed across logical
    checkpoints or authority boundaries without detection.
  - Enforces authority-boundary and policy-version read barriers before digest
    verification and checkpoint decode.
  - Verifies decoded checkpoint format, compatibility, and save time metadata
    against the indexed record metadata.

- `CoreAgentSwiftDataCheckpointRecord`
  - SwiftData `@Model` wrapper around the snapshot fields.
  - Keeps the encoded checkpoint bytes as the canonical payload. SwiftData row
    fields are indexes/readback metadata, not the checkpoint schema.
  - Stores a deterministic scope key over checkpoint key, authority boundary,
    and policy version so live store operations can filter and collapse rows by
    the same authority boundary that decode enforces.

- `CoreAgentSwiftDataCheckpointStore`
  - Main-actor `CoreAgentCheckpointStore` implementation over a supplied
    SwiftData `ModelContext`.
  - Saves, loads, replaces, and hard-deletes checkpoints by scoped key:
    checkpoint key, authority boundary, and policy version.
  - Uses a SwiftData predicate for the composite scope rather than fetching the
    whole checkpoint table and filtering in memory.
  - Uses `CoreAgentSwiftDataCheckpointSnapshot` for all persisted bytes and
    verifies the same authority/policy/digest metadata on readback.
  - Reuses the same lossless checkpoint validation as `FileCheckpointStore` by
    default, rejecting typed metadata and custom transcript segments before any
    SwiftData row is inserted unless an app explicitly opts into Foundation
    Models type erasure.
  - Collapses duplicate same-scope rows deterministically during replacement
    and chooses the newest scoped row by checkpoint save time, store time, then
    checkpoint ID when reading preexisting duplicates.
  - Does not own `CoreAgentAppleActionGate` evaluation. Hosts should gate
    `.swiftDataCheckpointPersistence(checkpointKey:)` before injecting or using
    this store; the store itself enforces persistence integrity and read
    barriers.
  - Offers a `ModelContainer` initializer that creates an isolated
    `ModelContext` and rolls it back on failed mutations. When a host supplies a
  shared `ModelContext`, rollback is caller-owned so unrelated pending app
  changes are not discarded by the checkpoint store.

- `CoreAgentSwiftDataEngineTraceRecord`
  - SwiftData `@Model` wrapper for redacted `CoreAgentEngineTrace` payloads.
  - Stores project ID, optional thread ID, run ID, run timing, ingestion time,
    sequence, redaction policy identifier, canonical encoded trace bytes, and
    an integrity digest.
  - Binds the scope key, indexed sidecar metadata, redaction policy identifier,
    and encoded trace bytes into the digest, then verifies decoded
    trace project/thread/run/timing metadata and receipt validity before
    readback.

- `CoreAgentSwiftDataEngineIssueRecord`
  - SwiftData `@Model` wrapper for `CoreAgentEngineIssue` payloads.
  - Stores issue ID, project ID, fingerprint, status raw value, first/last seen
    times, encoded issue bytes, and an integrity digest.
  - Fails closed when encoded issue metadata disagrees with indexed fields or
    status raw values drift from the typed issue status.

- `CoreAgentSwiftDataEngineStore`
  - Main-actor `CoreAgentEngineStore` implementation over a supplied SwiftData
    `ModelContext`.
  - Ingests only finalized runs, reuses the shared Engine redaction policy, and
    stores receipt-verifiable redacted traces.
  - Keys traces by project ID plus run ID so projects can safely reuse run
    identifiers without leakage or overwrite.
  - Supports project/thread trace queries with stable sequence ordering,
    deterministic duplicate replacement/read-side collapse, and portable
    protocol existential use.
  - Persists issue lifecycle state with the same scanner/upsert semantics as
    the in-memory store: explicit status updates are authoritative, resolved
    issues reopen only when new contributing runs appear, and ignored issues
    are not reset by later scans.
  - Preserves issue contributing-run provenance across partial upserts and
    duplicate valid rows, and rejects or fails closed on same-ID
    project/fingerprint collisions.
  - Rejects valid-looking trace rows whose receipt is stale, whose sidecar
    metadata has been replayed, whose redaction policy identifier does not
    match the active store, or whose run still contains content the configured
    redaction policy would redact.

- `CoreAgentSwiftDataGraphCheckpointRecord`
  - SwiftData `@Model` wrapper for `CoreAgentGraphCheckpoint<State>` payloads.
  - Stores thread ID, checkpoint namespace, checkpoint ID, parent checkpoint ID,
    graph step, checkpoint/store times, save sequence, encoded checkpoint bytes,
    deterministic scope key, and integrity digest.
  - Binds scope key, sidecar metadata, save sequence, timestamps, and encoded
    checkpoint bytes into the digest.
  - Fails closed on forged scope keys, digest mismatch, undecodable payloads, or
    decoded checkpoint metadata that disagrees with indexed sidecars.

- `CoreAgentSwiftDataGraphCheckpointer`
  - Main-actor `CoreAgentGraphCheckpointer` implementation over a supplied
    SwiftData `ModelContext`.
  - Saves generic `Codable & Sendable` graph checkpoints, preserving parent
    lineage, pending writes, thread IDs, checkpoint namespaces, and checkpoint
    IDs.
  - Preserves LangGraph-style reverse save order with a stored save sequence,
    with deterministic tied-sequence ordering by store time, create time, then
    checkpoint ID.
  - Uses logical sidecar fallback predicates intentionally so forged scope-key
    rows are fetched and rejected rather than skipped.
  - `history` and checkpoint-ID lookup validate all fetched candidates;
    `latest` validates the newest candidate only for O(1) resume while full
    history still fails closed on older corrupt rows.
  - Defaults rollback-on-failure to true for graph mutations; callers can
    explicitly opt out when they own the surrounding `ModelContext` transaction.

- `CoreAgentSwiftDataGraphStoreRecord`
  - SwiftData `@Model` wrapper for `CoreAgentGraphStoreRecord<Value>` payloads.
  - Stores namespace, key, update time, encoded value bytes, deterministic scope
    key, and integrity digest.
  - Validates store scope and digest without requiring typed payload decode, so
    key listing and mutation can handle valid heterogeneous payload rows.

- `CoreAgentSwiftDataGraphStore`
  - Main-actor `CoreAgentGraphStore` implementation over a supplied SwiftData
    `ModelContext`.
  - Supports generic `Codable & Sendable` value persistence by namespace/key:
    put, typed value/record readback, removal, and sorted unique key listing.
  - Replaces duplicate namespace/key rows on put and validates existing row
    integrity before mutation so corrupt rows are not silently overwritten.
  - Fails closed on corrupt or forged matching rows for typed reads, key
    listing, put, and remove.
  - Works through the portable `CoreAgentGraphStore` protocol existential and
    keeps graph store data separate from per-thread graph checkpoints.

- `CoreAgentAppleSandboxProfile` and `CoreAgentAppleActionGate`
  - Capability-scoped policy vocabulary for deterministic/WASI/helper/remote
    code interpreters, computer use, App Intent execution/donation, and
    SwiftData checkpoint persistence.
  - Keeps code interpreter authority separate from computer-use consent.
  - Requires scoped consent receipts for computer-use/App Intent actions and
    higher-risk helper/remote interpreter tiers. A receipt must match the
    sandbox authority boundary, policy version, required capability, request
    fingerprint, non-nil expiry, non-future grant time, trusted issuer, HMAC
    signature, and single-use receipt ID. Issued receipts require expiry,
    signing keys must contain at least 256 bits of material, and verification
    uses CryptoKit authentication-code validation rather than string equality.
  - Rejects remote interpreter requests unless the sandbox network policy
    explicitly allows network execution.
  - Supports request-bound code interpreter invocation consent through
    `.codeInterpreterInvocation(tier:programDigest:inputDigest:)`, so helper
    or remote consent can be tied to a concrete executable/program/input
    fingerprint instead of a broad tier grant.
  - Separates side-effect-free computer-use planning from consent-gated
    computer-use execution. Execution consent fingerprints bind the action ID
    and approved plan digest.
  - Enforces SwiftData checkpoint persistence and App Intent donation as
    separate gateable capabilities instead of passive vocabulary.
  - Donation requests carry the App Intent descriptor and are denied when the
    descriptor's donation policy is `doNotDonate`.

- `CoreAgentAppIntentDescriptor`
  - App Intent exposure policy descriptor for stable workflow/entity actions.
  - Requires the host to mark a descriptor as agent-exposed before it can pass
    validation for agent execution.
  - Rejects mutating/destructive intents unless authorization and HITL are
    required and foreground execution is allowed.
  - Captures supported modes, execution targets, and donation policy as typed
    metadata that concrete App Intent wrappers can map to OS APIs.
  - App Intent execution requests pass the descriptor plus the current mode and
    execution target through `CoreAgentAppleActionGate`; descriptor validation
    alone is not treated as execution authority.
  - Consent request fingerprints include a descriptor exposure fingerprint over
    identifier, title, mutability, explicit agent exposure, exposure revision,
    supported modes, allowed targets, donation policy, and authorization/HITL
    requirements, so old receipts cannot be replayed after security-relevant
    descriptor changes. Execution and donation fingerprints use separate
    request-type discriminants.

- `CoreAgentAppIntents` target
  - Provides an `AppIntentsPackage` marker and concrete
    `CoreAgentOpenRunIntent`, `CoreAgentPauseRunIntent`, and
    `CoreAgentContinueRunIntent` wrappers.
  - Publishes stable CoreAgent descriptors for each intent and a catalog that
    validates those descriptors before exposing them to hosts.
  - Maps CoreAgent mutability into Apple `IntentModes` without treating
    CoreAgent caller modes (`app`, `siri`, `shortcuts`, `spotlight`) as Apple
    process execution targets. Current wrappers use
    `IntentExecutionTargets.main` deliberately.
  - Routes concrete `perform()` calls through `CoreAgentRunAppIntentRuntime`
    and a host-installed `CoreAgentRunAppIntentRuntimeEnvironment`. The host
    supplies mode, target, consent, checkpoint-key, and operation closures, but
    the runtime constructs the `CoreAgentAppIntentBridgeRequest` and calls host
    work only as the bridge operation.
  - `CoreAgentAppIntentBridge` evaluates `CoreAgentAppleActionGate` before
    checkpointing or host work, requires checkpoints for mutating/destructive
    descriptors, records checkpoint keys in the result, observes cancellation
    before side effects and immediately before host work, maps thrown
    `CancellationError` to cancelled status, and does not run host work after
    denial.
  - Runtime run IDs are strict external identifiers: non-empty, already
    trimmed, at most 128 UTF-8 bytes, ASCII alphanumeric first character, and
    only ASCII alphanumeric, hyphen, period, or underscore thereafter.
  - This target proves CoreAgent-owned policy and wrapper contracts in SwiftPM.
    It does not prove app bundle discovery, Siri invocation, Shortcuts UI,
    Spotlight donation surfacing, signing/team configuration, or app-hosted
    `AppIntentsTesting`.

- `CoreAgentAppIntentDonationSubject` and `CoreAgentAppIntentDonationRecord`
  - Bind donation identity to a validated descriptor, authority boundary,
    policy version, and a typed stable subject.
  - Allowed subjects are stable workflow outcomes, entities, run outcomes,
    trace issues, and memory records.
  - Prompt text, tool arguments, and transient tool calls are rejected as
    donation subjects so Siri/Spotlight/App Intent donations cannot leak raw
    prompt or tool payload identifiers.
  - Donation identifiers are digest-derived and do not contain raw descriptor
    identifiers or subject stable identifiers.
  - Decoding revalidates subject kind/scope/stable identity and recomputes the
    donation identifier, so persisted or IPC-provided records cannot bypass the
    throwing initializer by smuggling prompt text, tool arguments, or forged
    identifiers.
  - `CoreAgentAppleExecutionRequest.appIntentDonationRecord` binds consent to
    the specific donation record so consent for one outcome cannot authorize a
    different outcome under the same descriptor.

- `InMemoryCoreAgentAppIntentDonationStore`
  - Stores active donation records by digest-derived donation ID.
  - Produces invalidation records when a specific donation is erased or when an
    access scope changes.
  - Requires at least one invalidation filter. When both donation ID and scope
    ID are supplied, both must match the active record before invalidation.
  - Tombstones invalidated donation IDs and scope IDs so stale records cannot
    be reactivated after erasure or access-scope changes.
  - This is the local metadata foundation used by the concrete
    `IntentDonationManager` bridge; it is not a substitute for app-hosted Siri
    or Spotlight discovery proof.

- `CoreAgentRunAppIntentDonationBridge` in `CoreAgentAppIntents`
  - Bridges typed CoreAgent donation records to
    `IntentDonationManager.shared.donate(intent:)` and
    `deleteDonations(matching:)`.
  - Validates strict ASCII run IDs, descriptor donation policy, and stable
    run-outcome subject binding before consent, local store, or OS backend
    work.
  - Evaluates `CoreAgentAppleActionGate` for both donation and invalidation so
    OS donation/deletion cannot bypass CoreAgent capability or consent policy.
  - Sends the concrete backend an authorized request carrying the validated
    donation record and bridge-created authorization proof; direct concrete
    backend calls fail closed for invalid run IDs, disabled donation policy,
    descriptor mismatch, unauthorized requests, and subject/run mismatches.
  - Returns a receipt carrying the OS donation token and revalidates the token
    digest on decode so persisted receipt state cannot smuggle a mismatched
    deletion token.
  - Requires all provided invalidation filters to match before deleting OS
    donations and records failed OS donations as `.systemDonationFailed`.

- `CoreAgentAppleDeterministicCodeInterpreter`
  - Executes a deliberately small typed instruction language in-process under
    `CoreAgentAppleActionGate` using the `.deterministicCodeInterpreter`
    capability.
  - Has no filesystem, network, shell, subprocess, JavaScriptCore, WASI,
    random, clock, or host-object authority in its instruction set. The
    `workspaceRoot` and network policy are audit/profile metadata for this
    tier, not enforcement by themselves.
  - Supports typed values, inputs, variables, addition, concatenation, stdout
    emission, and named outputs.
  - Enforces instruction count, input bytes, output bytes, value bytes, operand
    count, variable count, identifier length, output-name containment,
    duplicate-output rejection, intermediate state bytes, and cooperative
    Swift task cancellation before storing new state.
  - Rejects non-finite numeric inputs/literals/results, unsafe identifiers,
    path-shaped output names, and undefined operands with typed failure status.
  - Returns audit metadata for request ID, interpreter tier, authority boundary,
    policy version, workspace root, network policy, timestamps, program digest,
    input digest, and final status.

- `CoreAgentAppleHelperCodeInterpreter`
  - Provides a consent-gated helper-process interpreter backend boundary without
    launching `Process`, shell, JavaScriptCore, WASI, or remote execution from
    CoreAgent itself.
  - Validates non-empty bounded request IDs, canonical executable allowlists,
    default blocked shell executable names, workspace-contained working
    directories, explicit helper network access against sandbox network policy,
    bounded argv/env/stdin/stdout/stderr/typed outputs, backend exit status,
    non-finite typed outputs, output-name containment, and cancellation.
  - Evaluates `CoreAgentAppleActionGate` using request-bound
    `.codeInterpreterInvocation` fingerprints; generic helper-tier consent
    cannot authorize a concrete helper run.
  - Sends backends only a `CoreAgentAppleAuthorizedHelperCodeInterpreterRequest`
    after validation and action-gate approval, carrying canonical executable and
    working-directory URLs, authority boundary, policy version, workspace root,
    network policy, program digest, and input digest.
  - Treats the backend as a host authority boundary. Concrete apps still need an
    OS-level sandboxed runner, helper-tool signing, entitlement/container
    policy, filesystem/network enforcement, and output attestation around this
    adapter before running untrusted code.

- `CoreAgentAppleComputerUseExecutor`
  - Provides the first typed computer-use execution foundation without granting
    raw UI automation by default.
  - Dry-run planning is capability-gated through
    `.computerUsePlan(actionID:)`, requires no consent, calls only the backend's
    planning closure, validates plan structure, and records the produced
    actionID/planDigest in a bounded in-memory approval registry.
  - Execution requires an approved plan plus digest from a prior dry-run in the
    same executor, validates that the plan still hashes to that digest, then
    evaluates `.computerUseExecution(actionID:approvedPlanDigest:)` so the
    signed consent receipt is bound to both the action and reviewed plan.
  - Does not re-plan after consent. The backend receives the immutable approved
    plan for execution.
  - Enforces non-empty bounded request IDs/action IDs, non-empty bounded plan
    steps, unique step IDs, bounded and unique evidence requirements, a
    non-removable baseline screenshot digest requirement, ASCII SHA-256-shaped
    evidence digests, missing-evidence failure, and cancellation before,
    during, and after backend execution.
  - Returns audit metadata for request ID, action ID, mode, authority boundary,
    policy version, workspace root, network policy, timestamps, plan digest,
    evidence digest, and final status.
  - Treats screenshot/accessibility evidence as digest references supplied by a
    backend. It validates syntax and required presence, not capture honesty or
    OS-level attestation; concrete capture backends must supply that proof.

- `CoreAgentRunProjectionStore`
  - Main-actor `@Observable` projection store for SwiftUI apps.
  - Produces narrow `CoreAgentRunProjection` values from `CoreAgentEngineTrace`.
  - Deduplicates projections by run ID when a trace batch contains repeated
    runs.
  - Merges incremental trace batches into existing projections instead of
    replacing previously observed runs.
  - Exposes run ID, project/thread IDs, timing, status, last event kind, and
    event counts.
  - Deliberately omits raw event messages, attributes, receipts, transcripts,
    and trace blobs from view state to avoid accidental exposure of secrets,
    private user content, receipts, and large trace payloads through SwiftUI
    observation.

## Explicit Non-Goals For This Slice

- No direct OS-level sandbox runner, JavaScriptCore runner, WASI runner, remote
  runner, shell execution, `Process` launch, or raw Accessibility/UI automation
  backend yet. The deterministic interpreter is a bounded in-process tier; the
  helper interpreter and computer-use executor are policy/audit foundations over
  host-supplied backends, not direct OS execution or UI control.
- No app-hosted `AppIntentsTesting` or Siri/Shortcuts/Spotlight runtime proof
  yet. The concrete SwiftPM `AppIntent` wrappers and OS donation-manager bridge
  now exist in `CoreAgentAppIntents`; host applications still need to prove OS
  discovery, invocation, signing/team behavior, donation surfacing, and
  cancellation/runtime integration.
- No SwiftUI views. This target provides the observable projection model that
  app UI can consume.

These should build on the tested contracts here rather than inventing separate
authority, checkpoint, projection, or App Intent exposure shapes.

## Verification

- `swift test --skip-update --filter CoreAgentApplePlatformTests` first failed
  on missing Apple adapter API, then passed 17 focused tests after
  implementation and hardening.
- A delegated Swift/iOS review found two valid authority gaps: generic consent
  receipts and descriptor-detached App Intent execution. Both were fixed with
  regressions.
- VibeProxy review found valid hardening gaps around lossless checkpoint date
  coding, descriptor-bound App Intent consent, direct test-target dependencies,
  and gateable checkpoint/donation capabilities. Those were fixed with focused
  regressions.
- Follow-up VibeProxy review found two more valid contract gaps: checkpoint
  sidecar metadata was not digest-bound, and App Intent donation was
  descriptor-detached. Those were fixed with envelope digests and
  descriptor-bound donation requests.
- Final VibeProxy review found valid hardening gaps in checkpoint identity and
  `savedAt` parity, incremental projection merging, constant-time consent
  signature verification, issued-receipt expiry, and App Intent
  donation/execution replay. Those were fixed with focused regressions,
  including an in-memory SwiftData `ModelContext` persistence round trip.
- A delegated Swift/iOS review of the live checkpoint-store slice found valid
  requirements around actor isolation, composite scope filtering, duplicate
  scoped rows, lossless checkpoint validation, and hard-delete documentation.
  The store is `@MainActor`, works through the portable
  `CoreAgentCheckpointStore` existential, uses a deterministic scope key,
  reuses CoreAgent checkpoint validation, and has a CoreAgentSession restore
  regression.
- A delegated Swift/iOS review of the live Engine-store slice found valid
  requirements around shared redaction, actor isolation, receipt/readback
  corruption, sidecar metadata binding, project/run identity, issue lifecycle
  semantics, duplicate trace replacement, and plugin integration.
- VibeProxy Engine-store review through local `127.0.0.1:8320` returned HTTP
  200 for `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings around public decoded record
  access, duplicate trace/issue row collapse, corrupt issue shadowing,
  unbounded sequence fetch, redaction-policy binding, trace scope-key
  integrity, issue provenance union, and issue identity collisions were fixed
  with regressions. Final narrow recheck passed on all three models.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 46
  Apple-platform focused tests after the SwiftData Engine trace/issue store
  implementation, sidecar hardening, and VibeProxy fixes.
- A delegated Swift/iOS review and VibeProxy review of the live graph
  SwiftData slice found valid defects around stale fallback on corrupt rows,
  reverse save ordering, forged scope-key predicates, heterogeneous graph store
  payloads, mutation rollback defaults, tied save-sequence ordering, and extreme
  date digest overflow. Those were fixed with focused regressions.
- Final VibeProxy graph-store recheck through local `127.0.0.1:8320` passed
  cleanly on `gpt-5.5`; `gemini-3.5-flash-low` and
  `claude-haiku-4-5-20251001` only challenged deliberate fail-closed policy or
  marked the remaining observations acceptable/intentional.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 57
  Apple-platform focused tests after the SwiftData graph checkpoint/store
  implementation and review fixes.
- VibeProxy review of the deterministic interpreter through local
  `127.0.0.1:8320` used `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around consent
  receipt replay, future grants, weak HMAC keys, non-finite numeric values,
  cancellation, unsafe identifiers, duplicate output names, and unbounded
  intermediate interpreter state.
- A delegated Swift/iOS reviewer found valid resource-bound and non-finite
  value gaps in the deterministic interpreter. Those were fixed with preflight
  and per-assignment validation plus focused regressions.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 66
  Apple-platform focused tests after the deterministic interpreter and action
  gate hardening.
- Final L17 verification passed:
  `swift test --skip-update`, `swift build --skip-update`,
  `git diff --check`, and the tracked-modified/untracked text trailing-space
  scan.
- VibeProxy L18 review through local `127.0.0.1:8320` used `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`. Valid findings
  around plan-bound execution consent, baseline evidence requirements,
  structural request/plan validation, ASCII digest validation, cancellation
  classification, and bounded approved-plan cache were fixed with regressions.
- Final VibeProxy r3 recheck passed the targeted L18 checks on all three
  models. Remaining risks are deliberate future hardening: durable
  cross-process approval/receipt stores and trusted evidence capture
  attestation.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 73
  Apple-platform focused tests after L18.
- Final L18 verification passed:
  `swift test --skip-update`, `swift build --skip-update`,
  `git diff --check`, and the tracked-modified/untracked text trailing-space
  scan.
- `swift test --skip-update --filter 'App Intent donation records use stable non-sensitive identity'`
  first failed because App Intent donation record/store API was missing.
- Initial VibeProxy L19 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
  Valid findings were fixed around synthesized Codable bypass, stale
  reactivation after invalidation, plaintext record-bound consent fingerprints,
  and descriptor-identifier tampering.
- Final VibeProxy L19 recheck passed on all three models.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 78
  Apple-platform focused tests after adding typed donation records,
  record-bound donation consent, Codable revalidation, and invalidation after
  erasure/scope changes.
- Final verification after L19 passed: `swift test --skip-update`,
  `swift build --skip-update`, `git diff --check`, and the trailing-whitespace
  scan over modified/untracked text files.
- `swift test --skip-update --filter CoreAgentAppIntentsTests` first failed
  because product `CoreAgentAppIntents` required by test target
  `CoreAgentAppIntentsTests` did not exist.
- Added the `CoreAgentAppIntents` product/target, concrete run
  open/pause/continue AppIntent wrappers, CoreAgent descriptor catalog, OS
  policy mapper, runtime environment boundary, and action-gated
  `CoreAgentAppIntentBridge`.
- Initial VibeProxy L21 review through local `127.0.0.1:8320` used
  `gpt-5.5`, `gemini-3.5-flash-low`, and
  `claude-haiku-4-5-20251001`. Valid findings were fixed around concrete
  AppIntent `perform()` bypassing the bridge, mutating requests with nil
  checkpoint keys, cancellation immediately before host work, thrown
  `CancellationError`, unsafe path/control/Unicode run IDs, and catalog policy
  drift from concrete AppIntent metadata.
- `swift test --skip-update --filter CoreAgentAppIntentsTests` passed 10
  focused tests covering descriptor validation, OS policy mapping, unsupported
  CoreAgent mode denial, concrete `perform()` routing through the bridge,
  mutating checkpoint enforcement, consent/checkpoint/operation ordering,
  cancellation before side effects, thrown cancellation, stable catalog entries,
  and strict run-ID validation.
- Final VibeProxy L21 recheck passed on `gpt-5.5`,
  `gemini-3.5-flash-low`, and `claude-haiku-4-5-20251001`.
- `swift test --skip-update --filter CoreAgentApplePlatformTests` passed 78
  Apple-platform focused tests after adding the App Intents target.
- `swift test --skip-update` passed the full package test suite after adding
  the App Intents target.
- `swift build --skip-update` passed after the final L21 hardening.
- `swift test --skip-update --filter CoreAgentApplePlatformTests/helperCodeInterpreter`
  first failed because the helper interpreter boundary types did not exist, then
  passed 4 focused helper tests after adding the validated backend boundary.
- `agy` Gemini 3.5 Flash review found no P0/P1 blockers and one valid P2: helper
  URL canonicalization used `standardizedFileURL` without resolving symlinks.
  That was fixed with `resolvingSymlinksInPath().standardizedFileURL` and
  symlink-aware test expectations.
- `agy` Gemini 3.5 Flash re-review confirmed the symlink canonicalization
  finding fixed and reported no remaining P0/P1 blockers. Cursor Composer 2.5
  review is blocked in this shell by missing Cursor auth; `CURSOR_API_KEY` and
  `CURSOR_AUTH_TOKEN` are unset, and `op whoami` reports no 1Password account.
- Final L29 verification passed:
  `swift test --skip-update --filter CoreAgentApplePlatformTests/helperCodeInterpreter`,
  `swift test --skip-update --filter CoreAgentApplePlatformTests`,
  `swift test --skip-update`, `swift build --skip-update`, `git diff --check`,
  and the targeted trailing-whitespace scan over touched files.

- `CoreAgentAppleWASICodeInterpreter`
  - Consent-gated WASI/WebAssembly backend boundary with module allowlists,
    workspace containment, request/input digests, and authorized backend dispatch.
  - CoreAgent does not execute WASM itself; hosts supply
    `CoreAgentAppleWASICodeInterpreterBackend`.

- `CoreAgentAppleRemoteCodeInterpreter`
  - Consent-gated remote HTTP(S) interpreter backend boundary with endpoint
    allowlists, allowed network policy requirements, request/input digests, and
    authorized backend dispatch.
  - CoreAgent does not perform network I/O itself; hosts supply
    `CoreAgentAppleRemoteCodeInterpreterBackend`.

