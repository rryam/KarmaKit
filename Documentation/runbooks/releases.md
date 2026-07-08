# Release Runbook

## Preconditions

- All required CI workflows green on `main`
- `CHANGELOG.md` contains a section for the target version
- No open P0/P1 release blockers

## Release steps

1. Verify version in `CHANGELOG.md` matches the intended tag (`vX.Y.Z`).
2. Tag `main`:
   ```bash
   git checkout main
   git pull
   git tag -a vX.Y.Z -m "CoreAgent X.Y.Z"
   git push origin vX.Y.Z
   ```
3. Monitor the **Release** workflow in GitHub Actions.
4. Confirm the GitHub Release contains changelog notes.

## Post-release

- Verify SwiftPM clients can resolve the new tag
- Watch for downstream issue reports
- Open a tracking issue for any known limitations documented in the release notes

## Rollback

SwiftPM clients pin versions; rollback is:

1. Mark the GitHub Release as deprecated in release notes
2. Publish a patch release fixing the regression
3. Do not delete tags that may already be resolved by clients
