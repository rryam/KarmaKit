# Durable Background Tasks

`FoundationModelsAgentBackgroundTasks` stores enough scheduler state to decide
what may run after an app restart. It does not own a model protocol, transcript
format, provider layer, or agent loop. An app passes each record to a
caller-supplied `@Sendable` factory, which uses `AgentSession` and native
Foundation Models values for the actual work.

## State and settlement

Every record starts as `queued`, receives a lease while `preparing`, then moves
through states reported by the execution factory:

| State | Meaning |
| --- | --- |
| `queued` | Persisted and waiting for an eligible scheduler slot |
| `preparing` | Leased to this coordinator, before factory execution |
| `generating` | The caller's native session is running |
| `awaitingApproval` | The caller paused before an approval decision |
| `executingTool` | A tool boundary was durably recorded |
| `settling` | Factory execution returned and terminal persistence is next |
| `completed` | Execution and settlement finished |
| `failed` | Execution or a budget failed |
| `cancelled` | User, ancestor, or shutdown cancellation won |
| `ambiguousAfterCrash` | The task lost control after a non-idempotent mutation began |

`completed`, `failed`, `cancelled`, and `ambiguousAfterCrash` are terminal.
Settlement ignores a late second result. This matters when cancellation and a
factory return race: the first actor-isolated terminal transition wins and the
stored record never moves to a different terminal state.

A terminal record becomes visible to settlement waiters only after the store
accepts its snapshot. If that write fails after factory success, the task stays
nonterminal, and `waitForSettlement(of:)` throws a `persistenceFailed` error
instead of waiting indefinitely. Recovery applies the same replay rules
described below. The coordinator does not report successful work as failed or
completed without a durable terminal record.

`shutdown()` and `cancel(_:includingDescendants:)` settle work that has not
crossed a mutation boundary as cancelled. Once a non-idempotent mutation has
started, either operation records `ambiguousAfterCrash` because the external
API may ignore Swift cancellation and finish the request. The canonical status
name mentions a crash; the scheduler also uses it for cancellation or timeout
after control of an external effect has been lost.

## Stored identity

`BackgroundAgentTaskID` wraps a caller-supplied or generated UUID and maps to
the canonical `AgentTaskID` through `agentTaskID`. The request carries the
`AgentRunLineage` that scheduled the work. Each retry gets a fresh background
run lineage under that parent while the task ID stays fixed.

Each record also stores:

- `ownerID`, `rootTaskID`, `parentTaskID`, and `depth`;
- caller metadata and canonical attempt records;
- a monotonic FIFO sequence and priority;
- submission, update, first-start, and settlement dates;
- attempt count, executor lease, usage, and terminal reason.

Each `BackgroundAgentTaskAttempt` records its lineage, times, mutation
boundary, scheduler stop reason, and optional canonical `AgentTaskResult`.
Outputs and receipts stay in `AgentTaskResult`; the scheduler does not define a
second evidence format.

## Persistence

`BackgroundAgentTaskStore` reads and writes one
`BackgroundAgentTaskStoreSnapshot`. Both the snapshot and every record have
format versions. The production `FileBackgroundAgentTaskStore` encodes sorted
JSON and uses an atomic file replacement, so the old complete snapshot or the
new complete snapshot survives a process stop. Its throwing initializer takes
a nonblocking advisory lock. Another process or store instance cannot open the
same queue file while that lock remains held.

Use one coordinator for a file. Exclusive local ownership is not a distributed
claim protocol or server lease.

The coordinator serializes snapshot updates through one persistence lane. A
submit, execution update, cancellation, or settlement derives its next
snapshot only after the prior write finishes. In-memory state changes only
after the store accepts that snapshot, so a suspended older write cannot
replace newer cancellation or settlement state.

The in-memory store is intended for tests. Its `snapshots()` history also makes
settlement races inspectable.

The file is plaintext. Prompts, metadata, tool names, idempotency keys, evidence
references, and error details may be sensitive. Put it in an app-protected
container, choose the required Foundation file-protection class, and encrypt it
at the app boundary when needed. `ownerID` is stored tenancy metadata; it is not
an authorization check.

## Recovery rules

On a new coordinator start, every nonterminal leased record is treated as work
interrupted by the prior process. A running coordinator reclaims an in-flight
record only after its lease expires, and never reclaims an ID still present in
its own running table.

| Interrupted state | Recovery |
| --- | --- |
| `preparing` | Queue again if attempt and elapsed-time budgets remain |
| `generating` | Queue again; mutations must not start without the tool-boundary call below |
| `awaitingApproval` | Queue again and request a fresh decision |
| read-only `executingTool` | Queue again |
| any state after an idempotent mutation boundary | Queue again with the declared key |
| any state after a non-idempotent mutation boundary | Settle as `ambiguousAfterCrash` |

The coordinator never turns `ambiguousAfterCrash` back into queued work.
Inspect the external system, then submit a new task only after the app knows
whether the effect happened.

Recovery runs only when the app calls `start()` or `resume()`. The package does
not install a timer that wakes expired leases.

## Side-effect protocol

The execution factory must durably mark a mutation before making its external
request:

```swift
let key = "invoice:\(invoiceID):capture"

let request = BackgroundAgentTaskRequest(
  prompt: "Capture the approved invoice.",
  ownerID: userID,
  parentLineage: parentRun.lineage,
  recoveryPolicy: .idempotentMutation(idempotencyKey: key)
)

let coordinator = try BackgroundAgentTaskCoordinator(store: store) {
  record, context in
  try await context.markAwaitingApproval()
  try await requireApproval(for: record)
  try await context.markGenerating()

  try await context.markExecutingMutation(
    named: "capture_invoice",
    idempotencyKey: key
  )
  try await billing.capture(invoiceID, idempotencyKey: key)
  try await context.markToolFinished()

  return BackgroundAgentTaskOutcome(
    taskResult: try makeCanonicalTaskResult(for: record)
  )
}
```

`.readOnly` rejects `markExecutingMutation`. A
`.nonReplayableMutation` must omit the key and will become ambiguous if the
process stops at or after the recorded boundary.

One background task may cross one mutation boundary. Split independent writes
into separate tasks, each with its own idempotency key and canonical evidence.

Opaque profile-owned tools and ordinary `AgentSession` tools do not
automatically notify this separate scheduler. The app must wrap a mutating tool
or its external client so the context call happens first. Failing to do that
breaks the recovery contract.

## Scheduling and budgets

The coordinator enforces one global active-task limit and one limit for
siblings sharing a parent. Submission rejects excess depth or total fan-out.
Within the same effective priority, the persisted sequence is FIFO; prompts
remain distinct even when their text matches.

Waiting tasks gain one priority class per configured starvation interval, up
to `critical`. This gives old work a deterministic path to execution.

Each task carries maximum elapsed time, attempts, turns, tool calls, and tokens.
The coordinator cancels cooperative execution when elapsed time expires.
`markExecutingTool` consumes one tool-call unit. The factory must report native
session usage with `recordUsage`; the scheduler cannot infer usage from an
opaque caller-owned session. Turn and token limits are cooperative accounting:
the model may spend them before the factory reports usage. The scheduler saves
the observed overage, then fails the task.

## Process runtime is not OS runtime

Durability answers, "What should this app do when it runs again?" It does not
answer, "Will iOS keep this process alive?"

iOS can suspend or terminate an app while a task is generating, waiting for
approval, or calling a tool. This package does not request execution time,
register `BGTaskScheduler` identifiers, schedule refresh or processing tasks,
or provide a background-task UI. An app may connect those OS APIs separately,
subject to Apple's scheduling decisions and entitlement rules.

## Deliberate scope

This product stops at an exclusively owned, file-backed scheduler. It does not
implement `ChildAgentTool`, a distributed queue, server coordination,
`BGTaskScheduler` registration, or arbitrary rich-prompt serialization.
Callers that need image or custom-segment input should persist an app-owned
asset reference in metadata and rebuild the native `Prompt` inside the
execution factory.
