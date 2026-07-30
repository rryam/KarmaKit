# ``FoundationModelsAgentBackgroundTasks``

Persist and recover app-managed `AgentSession` work without replacing the
native Foundation Models loop.

## Overview

The module provides an app-owned coordinator, a versioned store protocol, and
an atomically replaced file store with exclusive local locking. Each task keeps
its prompt, scheduler hierarchy, priority, budgets, lease, and terminal reason.
Its stable ID maps to `AgentTaskID`, and every attempt records a distinct
`AgentRunLineage` plus an optional canonical `AgentTaskResult`.

Execution stays with the app. Supply a `@Sendable` factory that creates or
restores `AgentSession`, calls its native response APIs, and reports scheduler
state through ``BackgroundAgentTaskExecutionContext``.

Recovery requeues only work whose recorded mutation policy permits replay. A
task that may have completed a non-idempotent external effect settles as
``BackgroundAgentTaskState/ambiguousAfterCrash``.

This module does not request OS execution time. iOS may suspend or terminate
the app, and no arbitrary background work is guaranteed to continue.

For the full state and recovery contract, see <doc:DurableBackgroundTasks>.

## Topics

### Coordinating work

- ``BackgroundAgentTaskCoordinator``
- ``BackgroundAgentTaskRequest``
- ``BackgroundAgentTaskRecord``
- ``BackgroundAgentTaskOutcome``
- ``BackgroundAgentTaskExecutionContext``
- ``BackgroundAgentTaskAttempt``

### Persistence

- ``BackgroundAgentTaskStore``
- ``BackgroundAgentTaskStoreSnapshot``
- ``FileBackgroundAgentTaskStore``
- ``InMemoryBackgroundAgentTaskStore``

### Scheduling and recovery

- ``BackgroundAgentTaskState``
- ``BackgroundAgentTaskPriority``
- ``BackgroundAgentTaskRecoveryPolicy``
- ``BackgroundAgentTaskBudget``
- ``BackgroundAgentTaskCoordinatorConfiguration``
