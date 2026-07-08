#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="$root_dir/Sources/CoreAgentTalon"

if [[ ! -d "$target_dir" ]]; then
  echo "CoreAgentTalon target not found: $target_dir" >&2
  exit 1
fi

# 1. Forbidden module imports (messaging / daemon / networking transports).
if grep -RInE '^[[:space:]]*import[[:space:]]+(Network|WhatsApp|Telegram|MCP)\b' "$target_dir"; then
  echo "CoreAgentTalon must not import messaging, daemon, or networking modules." >&2
  exit 1
fi

# 2. Bare networking SYMBOLS. URLSession/URLRequest live in Foundation, so an
#    `import URLSession` clause can never match — guard the symbol usage directly.
if grep -RInE '\b(URLSession|URLRequest|URLConnection|NWConnection|NWListener|Socket)\b' "$target_dir"; then
  echo "CoreAgentTalon must not use networking/socket APIs; keep transports host-provided." >&2
  exit 1
fi

echo "CoreAgentTalon isolation check passed"
