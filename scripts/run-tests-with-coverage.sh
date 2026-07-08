#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

THRESHOLD="${COREAGENT_COVERAGE_THRESHOLD:-60}"
BUILD_DIR="${SWIFT_BUILD_DIR:-$ROOT/.build}"

mkdir -p .test-metrics
echo "Running tests with coverage (threshold: ${THRESHOLD}%)"
START=$(date +%s)

swift test --enable-code-coverage --parallel 2>&1 | tee .test-metrics/last-run.log

END=$(date +%s)
echo $((END - START)) > .test-metrics/last-duration-seconds.txt

PROFDATA="$(find "$BUILD_DIR" -name 'default.profdata' -print -quit 2>/dev/null || true)"
if [[ -z "$PROFDATA" ]]; then
  echo "Warning: profdata not found; skipping coverage threshold enforcement"
  exit 0
fi

LLVM_COV="llvm-cov"
if command -v xcrun >/dev/null 2>&1; then
  LLVM_COV="$(xcrun --find llvm-cov 2>/dev/null || echo llvm-cov)"
fi

TEST_BINARY="$(find "$BUILD_DIR" -type f -perm +111 \( -name 'CoreAgentPackageTests' -o -path '*/CoreAgent*Tests' \) 2>/dev/null | head -1 || true)"

if [[ -n "$TEST_BINARY" && -f "$PROFDATA" ]]; then
  REPORT=$("$LLVM_COV" report "$TEST_BINARY" -instr-profile="$PROFDATA" 2>/dev/null || true)
  echo "$REPORT" | tee .test-metrics/coverage-summary.txt
  LINE_COV=$(echo "$REPORT" | awk '/TOTAL/ { gsub("%","",$4); print $4; exit }')
  if [[ -n "${LINE_COV:-}" ]]; then
    echo "Line coverage: ${LINE_COV}%"
    if awk "BEGIN { exit !(${LINE_COV} < ${THRESHOLD}) }"; then
      echo "Coverage ${LINE_COV}% is below threshold ${THRESHOLD}%"
      exit 1
    fi
  fi
else
  echo "Could not locate test binary for coverage report; tests still passed"
fi

echo "Coverage check complete"
