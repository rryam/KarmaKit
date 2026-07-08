#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Agent readiness checks"

./scripts/validate-agents-md.sh
./scripts/scan-tech-debt.sh
./scripts/check-dependencies.sh

# Large files and duplicate code are advisory until legacy files are split
COREAGENT_MAX_FILE_LINES=6000 ./scripts/check-large-files.sh || {
  echo "Warning: oversized files detected (grandfathered during migration)"
}

COREAGENT_DUPLICATE_LINE_THRESHOLD=50 ./scripts/check-duplicate-code.sh || {
  echo "Warning: duplicate blocks detected (review recommended)"
}

echo "==> All required agent readiness checks passed"
