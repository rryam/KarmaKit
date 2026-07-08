# Observability Runbook (Library vs Host App)

CoreAgent is a **library**, not a deployed service. Built-in observability covers
runtime events inside the harness; production monitoring belongs in host apps.

## Provided by CoreAgent

| Capability | Where |
| --- | --- |
| Structured logging | `CoreAgentEvent` observers |
| Distributed tracing | Run IDs, trace IDs, thread IDs on runs |
| Usage metrics | Token usage and duration on responses |
| Log scrubbing | Redaction policies in observability modules |
| Issue pipeline | `CoreAgentEngineIssueScanner` for failed traces |

## Host application responsibilities

Configure these in the **app** that embeds CoreAgent:

| Capability | Typical tooling |
| --- | --- |
| Error tracking | Sentry, Bugsnag, or Rollbar |
| Alerting | PagerDuty, OpsGenie, on-call rotations |
| Deployment observability | Release dashboards, crash-free sessions |
| Product analytics | Amplitude, PostHog, Mixpanel |

CoreAgent checkpoints and memory stores may contain sensitive transcripts — route
observer output through the app's privacy and retention policies before shipping
to third-party services.
