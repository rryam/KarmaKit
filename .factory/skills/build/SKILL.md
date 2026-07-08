---
name: build-coreagent
description: Build CoreAgent and all test targets with SwiftPM or Xcode
---

# Build CoreAgent

## When to use

Use this skill before running tests or when validating compile-time changes across modules.

## Prerequisites

- Swift 6.4 toolchain
- Xcode 27 for Foundation Models APIs (macOS/iOS/visionOS builds)

## Steps

1. Run single-command setup if the clone is fresh:
   ```bash
   ./scripts/setup.sh
   ```

2. Build all library and test targets:
   ```bash
   swift build --build-tests
   ```

3. For Apple platform matrix builds:
   ```bash
   xcodebuild build \
     -scheme CoreAgent-Package \
     -destination 'generic/platform=macOS' \
     CODE_SIGNING_ALLOWED=NO
   ```

4. Verify formatting before committing:
   ```bash
   xcrun swift-format lint --strict --recursive Package.swift Sources Tests
   ```

## Provider traits

Default build uses no external packages. To build with providers:

```bash
swift build --build-tests --traits AllProviders
```

## Failure handling

- If Xcode 27 is missing, select it with `sudo xcode-select -s /Applications/Xcode_27*.app/Contents/Developer`
- If dependency resolution fails, run `swift package resolve` and verify pins in `Package.swift`
