---
name: test-coreagent
description: Run CoreAgent tests with coverage and provider trait matrix
---

# Test CoreAgent

## When to use

Use after code changes to any module under `Sources/` or `Tests/`.

## Default suite (no network)

```bash
swift test
```

Uses `RecordedLanguageModel` and deterministic fixtures — no API keys required.

## Coverage

```bash
./scripts/run-tests-with-coverage.sh
```

CI enforces a minimum line coverage threshold via `COREAGENT_COVERAGE_THRESHOLD`.

## Provider smoke tests

Only run when touching `CoreAgentProviders` or trait wiring:

```bash
swift test --traits AppleUtilities
swift test --traits Claude
swift test --traits Gemini
swift test --traits AllProviders
```

These are construction/compilation smoke tests, not live API integration tests.

## Conventions

- Add tests under the matching `Tests/<Module>Tests/` target
- Use Swift Testing (`@Test`, `#expect`)
- Do not add network calls to default tests
- Name files `*Tests.swift`

## Flaky test policy

CI retries failed test runs once. If a test flakes, fix isolation or add deterministic fixtures — do not increase retry count.
