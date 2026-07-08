#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_MD="$ROOT/AGENTS.md"

required_sections=(
  "Repository overview"
  "Single-command setup"
  "Build"
  "Test"
  "Environment variables"
  "Conventions"
  "CI expectations"
)

if [[ ! -f "$AGENTS_MD" ]]; then
  echo "AGENTS.md is missing at repository root"
  exit 1
fi

missing=0
for section in "${required_sections[@]}"; do
  if ! grep -Fq "## ${section}" "$AGENTS_MD"; then
    echo "Missing required AGENTS.md section: ## ${section}"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

for path in scripts/setup.sh .env.example Documentation/runbooks .factory/skills; do
  if [[ ! -e "$ROOT/$path" ]]; then
    echo "AGENTS.md references missing path: $path"
    exit 1
  fi
done

echo "AGENTS.md validation passed"
