# AGENTS.md

Guidance for coding agents working in the CoreAgent repository.

## Repository overview

CoreAgent is a Swift Package Manager library that wraps Apple's Foundation Models
API with production harness features: tool governance, checkpoints, memory,
tracing, and optional provider integrations.

- **Language:** Swift 6.4
- **Platforms:** iOS 27+, macOS 27+, visionOS 27+
- **Toolchain:** Xcode 27 (required for Foundation Models)
- **Package manifest:** `Package.swift`
- **Architecture docs:** `Documentation/`

## Single-command setup

```bash
./scripts/setup.sh
```

This selects Xcode 27 when available, resolves SwiftPM dependencies, and builds
all test targets.

## Build

```bash
# Resolve dependencies and compile all library + test targets
swift build --build-tests

# Build a specific scheme for Apple platforms (requires Xcode)
xcodebuild build \
  -scheme CoreAgent-Package \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Test

```bash
# Default test suite (no network, no API keys)
swift test

# Provider trait smoke tests (still no live network in CI)
swift test --traits AppleUtilities
swift test --traits Claude
swift test --traits Gemini
swift test --traits AllProviders

# With code coverage (used in CI)
swift test --enable-code-coverage
```

Tests use Swift Testing (`import Testing`). Test files live under `Tests/` and
follow the `*Tests.swift` naming convention.

## Format and lint

```bash
# Format (CI enforces this with --strict)
xcrun swift-format format --recursive --in-place Package.swift Sources Tests

# Lint
xcrun swift-format lint --strict --recursive Package.swift Sources Tests

# SwiftLint (naming, complexity, style rules)
swiftlint lint --strict
```

Install hooks once:

```bash
pre-commit install
```

## Environment variables

Copy `.env.example` to `.env` for local provider testing. **Never commit `.env`.**

| Variable | Purpose |
| --- | --- |
| `ANTHROPIC_API_KEY` | Optional live Claude provider tests |
| `COREAGENT_CHAT_COMPLETIONS_BASE_URL` | Optional Chat Completions endpoint |
| `COREAGENT_CHAT_COMPLETIONS_API_KEY` | Optional Chat Completions API key |
| `GOOGLE_APPLICATION_CREDENTIALS` | Optional Firebase/Gemini integration tests |

Provider trait tests in CI are construction-only smoke tests and do not require
these variables.

## Module map

| Target | Role |
| --- | --- |
| `CoreAgent` | Main session harness around Foundation Models |
| `CoreAgentMemory` | SQLite long-term memory with FTS5 |
| `CoreAgentGraph` | Graph runtime |
| `CoreAgentEngine` | Engine runtime and issue scanner |
| `CoreAgentSkills` | Skills runtime |
| `CoreAgentDeep` | Deep agent runtime (task ledger, filesystem) |
| `CoreAgentApplePlatform` | Apple platform integrations |
| `CoreAgentAppIntents` | App Intents bridge |
| `CoreAgentAgenticKit` | AgenticKit integration |
| `CoreAgentProviders` | Optional provider adapters (behind traits) |
| `CoreAgentTestSupport` | `RecordedLanguageModel` and test fixtures |

## Conventions

- Prefer extending existing patterns in the nearest module; do not introduce a
  parallel agent loop or message format.
- Foundation Models owns the inner model/tool loop; CoreAgent adds harness
  policy around it.
- Use `Sendable` and strict concurrency; the package targets Swift 6.
- Pin new dependencies by `revision` or `exact` version in `Package.swift`.
- Keep public API changes backward compatible unless intentionally versioned.
- Document behavioral changes in `CHANGELOG.md`.
- File names use `CoreAgent` prefix for types in their module (e.g.
  `CoreAgentSession.swift`).
- Maximum file size: 800 lines (enforced in CI); split large files instead of
  growing monoliths.

## Feature flags (SwiftPM traits)

Optional provider integrations are compile-time feature flags via SwiftPM traits:

- `AppleUtilities` — Foundation Models utilities / Chat Completions client
- `Claude` — Anthropic Claude provider
- `Gemini` — Firebase Gemini provider
- `AllProviders` — enables all of the above

Default resolution uses **no** external packages. Enable traits only when needed.

## Agent skills

Reusable task playbooks live in `.factory/skills/`. Read the relevant `SKILL.md`
before making non-trivial changes in that area.

## Runbooks

Operational guides for CI failures, releases, and incidents:
`Documentation/runbooks/`.

## Security

- Never commit API keys, plist secrets, or checkpoint encryption keys.
- Use app Keychain / platform secret storage in production apps.
- Redaction policies scrub tokens and secrets from `CoreAgentEvent` observers.
- Report security issues privately to maintainers; do not open public issues for
  vulnerabilities.

## CI expectations

Pull requests must pass these GitHub status checks:

| Check | Workflow | Scope |
| --- | --- | --- |
| `CI status` | `CI` | Format, build, tests, coverage, provider/platform builds |
| `Agent readiness status` | `Agent Readiness` | AGENTS.md, debt, file size, duplicates, deps, SwiftLint |
| `Analyze Swift` | `CodeQL` | Security (SAST) |

If GitHub-hosted runners lack Xcode 27, build/test jobs skip with a notice;
readiness and security jobs still run. See
`Documentation/runbooks/branch-protection.md` for enabling required checks.

## What not to do

- Do not add network calls to default unit tests.
- Do not disable concurrency checking or `@preconcurrency` without cause.
- Do not add dependencies without pinning and a trait when optional.
- Do not run full `swift test --traits AllProviders` unless touching providers.
