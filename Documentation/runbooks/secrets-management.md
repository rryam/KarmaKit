# Secrets Management Runbook

CoreAgent is a library — **applications** own secret storage. This document
defines repository and integration expectations.

## Repository rules

- Never commit `.env`, API keys, `GoogleService-Info.plist`, or encryption keys
- Use `.env.example` as the template for local development variables
- Pre-commit hooks run `detect-private-key`
- GitHub secret scanning is enabled on the repository

## Local development

```bash
cp .env.example .env
# Fill in values only for optional live provider tests
```

Variables:

| Variable | Storage recommendation |
| --- | --- |
| `ANTHROPIC_API_KEY` | `.env` locally; Keychain in apps |
| `COREAGENT_CHAT_COMPLETIONS_API_KEY` | `.env` locally; Keychain in apps |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to service account JSON outside repo |

## Production applications

- Store provider credentials in **Keychain** or platform secret managers
- Encrypt checkpoint files at the application boundary
- Use `CoreAgent` redaction policies for event observers
- Do not log raw tool arguments containing user secrets

## CI

CI does not require production secrets. Provider tests are smoke tests only.

## Rotation

When a secret may be exposed:

1. Revoke and reissue the credential
2. Update app configuration / Keychain entries
3. Audit observer logs and checkpoints for leakage
