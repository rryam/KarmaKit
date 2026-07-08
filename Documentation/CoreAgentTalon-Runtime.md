# CoreAgentTalon Runtime

`CoreAgentTalon` is the portable Talon runtime core for CoreAgent. It maps the
LangChain Talon host model to typed, deterministic, in-process Swift primitives
without a live daemon, messaging bridge, timer, or network transport in the
package.

## Host lifecycle

`CoreAgentTalonHost` owns conversation actors keyed by
`CoreAgentTalonConversationID`. Each conversation wraps one `CoreAgentSession`
from a host-supplied session factory.

- Runs for the same conversation pass through a conversation-local async lock, so
  two turns for one id never overlap.
- Runs for distinct conversation ids use distinct conversation actors and can
  proceed independently.
- `/stop` maps to `stop(conversationID:)`, which cancels the in-flight task for
  that conversation. The cancelled run returns `.cancelled`, and the host can
  accept later runs.
- `/new` maps to `newConversation(replacing:)`, which calls
  `CoreAgentSession.reset(removingCheckpoint:)`, rotates the conversation id via
  an injected generator, and leaves sibling conversations unchanged.

## Cron policy

`CoreAgentTalonCronScheduler` is a host-triggered policy over a durable
`CoreAgentTalonCronJobStore`.

- It loads jobs on each `fireDueJobs()` call.
- It compares `nextRunAt` against an injected `CoreAgentTalonClock`.
- It fires only due enabled jobs in deterministic `nextRunAt` then id order.
- It persists updated `lastRunAt` and `nextRunAt` values after firing.

The core never starts timers or background tasks. Apple hosts can map this policy
to platform scheduling APIs outside the portable target.

## Events

Every host, run, command, and cron lifecycle transition can be represented as a
Codable `CoreAgentTalonEvent` whose `type` is `talon_event`. Payloads are typed
enum cases for conversation, command, run, and cron evidence, and round-trip
without lossy string parsing.

## Isolation

`scripts/check-talon-core-isolation.sh` enforces that `Sources/CoreAgentTalon`
does not import messaging, daemon, or networking modules such as `Network`,
`URLSession`, WhatsApp, Telegram, or MCP.
