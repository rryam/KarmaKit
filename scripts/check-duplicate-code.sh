#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

THRESHOLD="${COREAGENT_DUPLICATE_LINE_THRESHOLD:-12}"
MIN_BLOCK="${COREAGENT_DUPLICATE_MIN_BLOCK:-6}"

echo "Scanning for duplicate code blocks (>= ${MIN_BLOCK} lines, threshold ${THRESHOLD})..."

python3 - "$ROOT" "$MIN_BLOCK" "$THRESHOLD" <<'PY'
import hashlib
import sys
from pathlib import Path

root, min_block, threshold = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
counts: dict[str, list[str]] = {}

for path in sorted(root.glob("Sources/**/*.swift")):
    lines = [ln.rstrip() for ln in path.read_text(encoding="utf-8").splitlines()]
    filtered = [ln for ln in lines if ln.strip() and not ln.strip().startswith("//")]
    for i in range(len(filtered) - min_block + 1):
        block = "\n".join(filtered[i : i + min_block])
        digest = hashlib.sha256(block.encode()).hexdigest()
        counts.setdefault(digest, []).append(f"{path}:{i+1}")

duplicates = [places for places in counts.values() if len(places) >= threshold]
if duplicates:
    print(f"Found {len(duplicates)} highly duplicated block(s):")
    for places in duplicates[:10]:
        print("  " + ", ".join(places[:5]))
    sys.exit(1)

print("Duplicate code scan passed")
PY
