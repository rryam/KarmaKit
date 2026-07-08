---
name: release-coreagent
description: Cut a CoreAgent release with changelog and GitHub release automation
---

# Release CoreAgent

## When to use

Use when shipping a new semantic version of the Swift package.

## Steps

1. Update `CHANGELOG.md` with a new `## X.Y.Z` section describing user-visible changes.

2. Ensure CI is green on `main`:
   - Agent readiness
   - CI (build + test + coverage)
   - CodeQL

3. Commit the changelog update and merge to `main`.

4. Create and push an annotated tag:
   ```bash
   git tag -a vX.Y.Z -m "CoreAgent X.Y.Z"
   git push origin vX.Y.Z
   ```

5. The `Release` workflow creates a GitHub Release using the matching
   `CHANGELOG.md` section.

## Versioning

Follow semantic versioning:

- **Major** — breaking public API changes
- **Minor** — backward-compatible features
- **Patch** — bug fixes and internal changes

## Dependency policy

New dependencies must be pinned by `revision` or `exact` in `Package.swift`.
Run `./scripts/check-release-age.sh` to enforce minimum release age for exact pins.
