# Branch Protection Runbook

Configure required status checks in GitHub so pull requests receive fast,
actionable feedback.

## Recommended required checks

| Check name | Workflow | Notes |
| --- | --- | --- |
| `CI status` | `CI` | Build/test gate (passes when Xcode 27 unavailable + notice) |
| `Agent readiness status` | `Agent Readiness` | Structure, policy, SwiftLint metrics |
| `Analyze Swift` | `CodeQL` | Security scanning |

## Setup

1. Open **Settings → Branches → Branch protection rules**
2. Add or edit rule for `main`
3. Enable **Require status checks to pass before merging**
4. Search for and select the status checks above
5. Enable **Require branches to be up to date before merging**

## Dependabot

Dependabot opens weekly PRs for GitHub Actions and Swift dependencies.
Review pins and trait impact before merging.

## CODEOWNERS

Changes to sensitive paths require review from owners listed in
`.github/CODEOWNERS`.
