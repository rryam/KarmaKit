#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAX_LINES="${COREAGENT_MAX_FILE_LINES:-800}"
REPORT="$ROOT/large-files-report.txt"
FAILED=0

echo "Checking Swift source files exceed ${MAX_LINES} lines..." | tee "$REPORT"

while IFS= read -r file; do
  lines=$(wc -l < "$file" | tr -d ' ')
  if [[ "$lines" -gt "$MAX_LINES" ]]; then
    echo "OVERSIZED: $file ($lines lines)" | tee -a "$REPORT"
    FAILED=1
  fi
done < <(find Sources Tests -name '*.swift' -type f | sort)

if [[ "$FAILED" -ne 0 ]]; then
  echo "Large file check failed. Split oversized files or raise COREAGENT_MAX_FILE_LINES with justification." | tee -a "$REPORT"
  exit 1
fi

echo "Large file check passed" | tee -a "$REPORT"
