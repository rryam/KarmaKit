#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="$root_dir/Sources/CoreAgentTalon"

if [[ ! -d "$target_dir" ]]; then
  echo "CoreAgentTalon target not found: $target_dir" >&2
  exit 1
fi

if grep -RInE '^[[:space:]]*import[[:space:]]+(Network|URLSession|WhatsApp|Telegram|MCP)\b' "$target_dir"; then
  echo "CoreAgentTalon must not import messaging, daemon, or networking modules." >&2
  exit 1
fi

echo "CoreAgentTalon isolation check passed"
