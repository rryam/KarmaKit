#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Agent readiness checks"

./scripts/validate-agents-md.sh
./scripts/scan-tech-debt.sh
./scripts/check-dependencies.sh

# File size gate is enforced at 800 (legacy monoliths fully split); matches CI.
./scripts/check-large-files.sh

# Duplicate code remains advisory (known duplicated private helpers pending consolidation).
COREAGENT_DUPLICATE_LINE_THRESHOLD=50 ./scripts/check-duplicate-code.sh || {
  echo "Warning: duplicate blocks detected (review recommended)"
}

echo "==> All required agent readiness checks passed"
