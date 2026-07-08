#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PACKAGE="$ROOT/Package.swift"

declared=()
while IFS= read -r url; do
  declared+=("$url")
done < <(grep -E 'url: "https://' "$PACKAGE" | sed -E 's/.*url: "([^"]+)".*/\1/' | sort -u)

if [[ "${#declared[@]}" -eq 0 ]]; then
  echo "No external Swift package dependencies declared (default resolution)."
  exit 0
fi

echo "Declared dependencies:"
printf '  - %s\n' "${declared[@]}"

# Verify each declared package is referenced by at least one target product.
unused=0
while IFS= read -r url; do
  identity=$(basename "$url" .git)
  if ! grep -q "package: \"$identity\"" "$PACKAGE"; then
    echo "Unused dependency (no target references package: \"$identity\"): $url"
    unused=1
  fi
done < <(printf '%s\n' "${declared[@]}")

if [[ "$unused" -ne 0 ]]; then
  exit 1
fi

echo "All declared dependencies are referenced by targets (trait-gated where applicable)."
