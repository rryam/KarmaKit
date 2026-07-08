#!/usr/bin/env bash
#
# verify-merge.sh — merge-time verification gate for the CoreAgent stack.
#
# CI's Swift build/test/format jobs SKIP when the GitHub-hosted runner image lacks
# Xcode 27 (see .github/workflows/ci.yml), and SwiftLint tolerates a nonzero error
# budget. That means a green PR does NOT prove the tree builds, tests, or formats
# cleanly under the real toolchain. This script is the local, Xcode-27-backed gate
# to run before and after merging the stack — on the integrated tree — so nothing
# silently regresses.
#
# It fails closed: any single gate failure aborts with a nonzero exit.
#
# Usage:
#   scripts/verify-merge.sh
#
# Tunables (env vars, with defaults):
#   COREAGENT_TEST_FLOOR         Minimum number of default-suite tests (default 467)
#   COREAGENT_UNCHECKED_BASELINE Max allowed '@unchecked Sendable' in Sources (default 7)
#   COREAGENT_MAX_FILE_LINES     Max Swift file length (default 800, via check-large-files.sh)
#   COREAGENT_SKIP_TRAITS        If "1", skip the TalonChannels trait build/test
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_FLOOR="${COREAGENT_TEST_FLOOR:-467}"
UNCHECKED_BASELINE="${COREAGENT_UNCHECKED_BASELINE:-7}"

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '  ----  %s\n' "$1"; }
section() { printf '\n==> %s\n' "$1"; }

FAILURES=0
record_fail() {
  fail "$1"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# 0. Identity / provenance logging (Fable: always log the SHA you verified)
# ---------------------------------------------------------------------------
section "Repository identity"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(detached)')"
HEAD_SHA="$(git rev-parse HEAD)"
TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
info "branch:   $BRANCH"
info "HEAD:     $HEAD_SHA"
info "tree:     $TREE_SHA"
if [[ -n "$(git status --porcelain)" ]]; then
  info "worktree: DIRTY (uncommitted changes present)"
  git status --short | sed 's/^/          /'
else
  info "worktree: clean"
fi

# ---------------------------------------------------------------------------
# 1. Toolchain check — this gate is only meaningful under Xcode 27 swift-format
# ---------------------------------------------------------------------------
section "Toolchain"
if command -v xcrun >/dev/null 2>&1; then
  info "xcode-select: $(xcode-select -p 2>/dev/null || echo unknown)"
  info "swift: $(swift --version 2>&1 | head -1)"
  if xcrun --find swift-format >/dev/null 2>&1; then
    pass "swift-format available: $(xcrun --find swift-format)"
  else
    record_fail "swift-format not found via xcrun — format gate cannot run"
  fi
else
  record_fail "xcrun not available — this script must run on macOS with Xcode 27"
fi

# ---------------------------------------------------------------------------
# 2. Strict format lint on the integrated tree (CI skips this without Xcode 27)
# ---------------------------------------------------------------------------
section "swift-format lint --strict (Package.swift Sources Tests)"
if xcrun swift-format lint --strict --recursive Package.swift Sources Tests >/tmp/verify-merge-format.log 2>&1; then
  pass "format lint clean"
else
  ERRS="$(grep -c 'error:' /tmp/verify-merge-format.log || true)"
  record_fail "format lint reported ${ERRS} error(s); see /tmp/verify-merge-format.log"
  grep 'error:' /tmp/verify-merge-format.log | sed 's/^/          /' | head -20 || true
fi

# ---------------------------------------------------------------------------
# 3. Build all test targets (default trait resolution — no external packages)
# ---------------------------------------------------------------------------
section "swift build --build-tests (default traits)"
if swift build --build-tests >/tmp/verify-merge-build.log 2>&1; then
  pass "default build succeeded"
else
  record_fail "default build failed; see /tmp/verify-merge-build.log"
  tail -20 /tmp/verify-merge-build.log | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
# 4. Default test suite + test floor (guards against silent test loss)
# ---------------------------------------------------------------------------
section "swift test (default suite) with test floor >= ${TEST_FLOOR}"
if swift test >/tmp/verify-merge-test.log 2>&1; then
  pass "default test suite passed"
else
  record_fail "default test suite failed; see /tmp/verify-merge-test.log"
  grep -E '✘|error:|Fatal' /tmp/verify-merge-test.log | sed 's/^/          /' | head -20 || true
fi
# Sum the per-target "Test run with N tests" lines (Swift Testing reports per target).
TEST_COUNT="$(grep -oE 'Test run with [0-9]+ test' /tmp/verify-merge-test.log \
  | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')"
info "default-suite tests observed: ${TEST_COUNT}"
if [[ "${TEST_COUNT}" -lt "${TEST_FLOOR}" ]]; then
  record_fail "test count ${TEST_COUNT} is below floor ${TEST_FLOOR} — tests may have been dropped"
else
  pass "test floor satisfied (${TEST_COUNT} >= ${TEST_FLOOR})"
fi

# ---------------------------------------------------------------------------
# 5. TalonChannels trait build + test (CI never compiles this target today)
# ---------------------------------------------------------------------------
if [[ "${COREAGENT_SKIP_TRAITS:-0}" == "1" ]]; then
  section "TalonChannels trait (SKIPPED via COREAGENT_SKIP_TRAITS=1)"
else
  section "TalonChannels trait build + test"
  if swift build --traits TalonChannels --build-tests >/tmp/verify-merge-trait-build.log 2>&1; then
    pass "TalonChannels build succeeded"
  else
    record_fail "TalonChannels build failed; see /tmp/verify-merge-trait-build.log"
    tail -20 /tmp/verify-merge-trait-build.log | sed 's/^/          /'
  fi
  if swift test --traits TalonChannels >/tmp/verify-merge-trait-test.log 2>&1; then
    pass "TalonChannels tests passed"
  else
    record_fail "TalonChannels tests failed; see /tmp/verify-merge-trait-test.log"
    grep -E '✘|error:|Fatal' /tmp/verify-merge-trait-test.log | sed 's/^/          /' | head -20 || true
  fi
fi

# ---------------------------------------------------------------------------
# 6. 800-line file-size gate (reuse the canonical readiness script)
# ---------------------------------------------------------------------------
section "800-line file-size gate"
if ./scripts/check-large-files.sh >/tmp/verify-merge-largefiles.log 2>&1; then
  pass "no oversized Swift files"
else
  record_fail "oversized Swift file(s) detected; see /tmp/verify-merge-largefiles.log"
  grep 'OVERSIZED' /tmp/verify-merge-largefiles.log | sed 's/^/          /' || true
fi

# ---------------------------------------------------------------------------
# 7. '@unchecked Sendable' baseline (security: manual concurrency proofs)
# ---------------------------------------------------------------------------
section "@unchecked Sendable baseline (<= ${UNCHECKED_BASELINE} in Sources)"
UNCHECKED_COUNT="$(grep -rn '@unchecked Sendable' Sources | wc -l | tr -d ' ')"
info "occurrences:"
grep -rn '@unchecked Sendable' Sources | sed 's/^/          /' || true
if [[ "${UNCHECKED_COUNT}" -gt "${UNCHECKED_BASELINE}" ]]; then
  record_fail "@unchecked Sendable count ${UNCHECKED_COUNT} exceeds baseline ${UNCHECKED_BASELINE}"
  info "Each @unchecked Sendable is a manual concurrency-safety proof obligation."
  info "If the increase is intentional, justify it and raise COREAGENT_UNCHECKED_BASELINE."
else
  pass "@unchecked Sendable within baseline (${UNCHECKED_COUNT} <= ${UNCHECKED_BASELINE})"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
info "verified tree: ${TREE_SHA} (HEAD ${HEAD_SHA} on ${BRANCH})"
if [[ "${FAILURES}" -ne 0 ]]; then
  fail "${FAILURES} gate(s) failed"
  exit 1
fi
pass "all merge-verification gates passed"
