#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVCONTAINER=0
for arg in "$@"; do
  case "$arg" in
    --devcontainer) DEVCONTAINER=1 ;;
  esac
done

echo "==> CoreAgent setup"

if [[ "$DEVCONTAINER" -eq 0 ]]; then
  XCODE_PATH="$(find /Applications -maxdepth 1 -type d -name 'Xcode_27*.app' 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "${XCODE_PATH:-}" ]]; then
    echo "==> Selecting Xcode 27 at $XCODE_PATH"
    sudo xcode-select -s "$XCODE_PATH/Contents/Developer"
    xcodebuild -version
  else
    echo "==> Xcode 27 not found; using default toolchain"
    swift --version || true
  fi
fi

if command -v pre-commit >/dev/null 2>&1; then
  echo "==> Installing pre-commit hooks"
  pre-commit install
else
  echo "==> pre-commit not installed (optional: brew install pre-commit)"
fi

echo "==> Resolving SwiftPM dependencies"
swift package resolve

echo "==> Building all test targets"
swift build --build-tests

echo "==> Setup complete"
echo "Run: swift test"
