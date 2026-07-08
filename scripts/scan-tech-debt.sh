#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPORT="$ROOT/tech-debt-report.txt"
PATTERN='(TODO|FIXME|HACK|XXX):'

echo "Scanning for tech debt markers..." | tee "$REPORT"

matches=$(grep -RInE "$PATTERN" Sources Tests Package.swift AGENTS.md README.md 2>/dev/null || true)

if [[ -n "$matches" ]]; then
  echo "$matches" | tee -a "$REPORT"
  count=$(echo "$matches" | wc -l | tr -d ' ')
  echo "Found $count tech debt marker(s). Track in issues; new markers require justification." | tee -a "$REPORT"
else
  echo "No TODO/FIXME/HACK markers found." | tee -a "$REPORT"
fi

if [[ "${COREAGENT_STRICT_DEBT:-0}" == "1" && -n "$matches" ]]; then
  exit 1
fi

echo "Tech debt scan complete"
