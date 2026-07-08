#!/usr/bin/env bash
# Optional dead-code analysis with Periphery (https://github.com/peripheryapp/periphery)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v periphery >/dev/null 2>&1; then
  echo "Periphery not installed. Install with: brew install peripheryapp/periphery/periphery"
  echo "Skipping dead code detection."
  exit 0
fi

periphery scan --project "$ROOT" --schemes CoreAgent-Package --quiet
