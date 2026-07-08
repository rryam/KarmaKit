# Incident Response Runbook

CoreAgent is a library package — production incidents typically surface in
**host applications** using CoreAgent. This runbook covers library-side response.

## Severity levels

| Level | Description | Response time |
| --- | --- | --- |
| P0 | Data loss, secret leak, crash in default configuration | Immediate |
| P1 | Security vulnerability in library code | Same day |
| P2 | Regression affecting governed tools, checkpoints, or memory | Next business day |
| P3 | Documentation or non-critical defect | Normal backlog |

## Triage checklist

1. Identify affected module (`CoreAgent`, `CoreAgentMemory`, etc.)
2. Determine if issue requires network, API keys, or Apple Intelligence
3. Reproduce with `RecordedLanguageModel` when possible
4. Check recent releases and `CHANGELOG.md`

## Secret exposure

If API keys or checkpoint material were committed:

1. Rotate exposed credentials immediately
2. Purge secrets from git history if necessary
3. File a private security advisory — do not discuss exploit details publicly

## Communication

- P0/P1: notify CODEOWNERS and open a tracking issue with `P0`/`P1` label
- Provide reproduction steps and affected versions
- Link to fix PR when available

## Recovery validation

- `swift test` passes
- Targeted regression test added
- `CHANGELOG.md` updated for user-visible fixes
