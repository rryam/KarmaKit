# CI Failures Runbook

## Symptoms

Pull request checks fail on `CI`, `Agent Readiness`, or `CodeQL` workflows.

## Xcode 27 unavailable

**Indicator:** `hosted-runner-notice` job succeeds; build/test jobs are skipped.

**Action:**

1. Confirm this is a GitHub runner image limitation, not a code defect.
2. Merge if `Agent Readiness` and `CodeQL` pass and changes are non-runtime.
3. Re-run CI when Xcode 27 appears on `macos-26` images.

## swift-format failures

```bash
xcrun swift-format format --recursive --in-place Package.swift Sources Tests
```

## SwiftLint failures

```bash
brew install swiftlint
swiftlint lint --strict
```

Fix naming, complexity, or length violations. Adjust `.swiftlint.yml` only with team agreement.

## Test failures

1. Reproduce locally: `swift test`
2. For coverage failures: `./scripts/run-tests-with-coverage.sh`
3. If CI passes on retry, investigate flake — see test skill in `.factory/skills/test/`

## Coverage below threshold

1. Add tests for changed code paths
2. Temporarily lower threshold only with explicit maintainer approval

## Agent readiness failures

Run locally:

```bash
./scripts/agent-readiness.sh
./scripts/validate-agents-md.sh
```

## Escalation

Contact CODEOWNERS listed in `.github/CODEOWNERS`.
