#!/usr/bin/env bash
# Runs the platform-independent core test suite on Linux (or any host
# without the Apple SDKs) by building a shadow package that contains only
# the CoreVoiceAgentCore, CoreVoiceAgentTestSupport, and
# CoreVoiceAgentCoreTests targets. The canonical Package.swift depends on
# CoreAgent and Core AI runtimes that require Xcode 27, so it cannot be
# resolved off-platform; the shadow package symlinks the same sources.
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHADOW_DIR="$(mktemp -d)"
trap 'rm -rf "$SHADOW_DIR"' EXIT

mkdir -p "$SHADOW_DIR/Sources" "$SHADOW_DIR/Tests"
ln -s "$PACKAGE_ROOT/Sources/CoreVoiceAgentCore" "$SHADOW_DIR/Sources/CoreVoiceAgentCore"
ln -s "$PACKAGE_ROOT/Sources/CoreVoiceAgentTestSupport" "$SHADOW_DIR/Sources/CoreVoiceAgentTestSupport"
ln -s "$PACKAGE_ROOT/Tests/CoreVoiceAgentCoreTests" "$SHADOW_DIR/Tests/CoreVoiceAgentCoreTests"

cat > "$SHADOW_DIR/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "core-voice-agent-core-tests",
  platforms: [
    .macOS(.v13)
  ],
  targets: [
    .target(name: "CoreVoiceAgentCore"),
    .target(name: "CoreVoiceAgentTestSupport", dependencies: ["CoreVoiceAgentCore"]),
    .testTarget(
      name: "CoreVoiceAgentCoreTests",
      dependencies: ["CoreVoiceAgentCore", "CoreVoiceAgentTestSupport"]
    ),
  ]
)
EOF

swift test --package-path "$SHADOW_DIR" "$@"
