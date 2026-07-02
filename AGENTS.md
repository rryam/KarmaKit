# AGENTS.md

## Cursor Cloud specific instructions

### What this repository is

CoreAgent (aka CoreVoiceAgent) is an **Apple-platform-only Swift Package Manager
library**, not an application. `Package.swift` declares only `.library`
products (`CoreAgent`, `CoreAgentMemory`, `CoreAgentTestSupport`,
`CoreAgentProviders`) — there is **no executable/app/server to run**. It is
exercised through its test targets.

### Hard constraint: it cannot be built, tested, linted, or run on Linux

Cursor Cloud VMs are Linux (Ubuntu x86_64). This package targets iOS/macOS/
visionOS 27 and requires **Swift 6.4 / Xcode 27 on an Apple Silicon Mac
(macOS 26.4+)**. Do not spend time trying to make `swift build`/`swift test`
pass on the Cloud VM — it is structurally impossible here for three independent
reasons (all verified during setup):

1. **Toolchain gap.** `Package.swift` pins `swift-tools-version: 6.4`. The
   newest Swift release available for Linux is **6.3.3**; Swift 6.4 ships only
   inside Xcode 27, and no Linux 6.4 release/snapshot is published on swift.org
   yet (`swiftly list-available 6.4-snapshot` → HTTP 404). `swift build` fails
   immediately: `using Swift tools version 6.4.0 but the installed version is 6.3.3`.
2. **Manifest API gap.** The manifest uses `.iOS(.v27)`, `.macOS(.v27)`,
   `.visionOS(.v27)`, which `PackageDescription` below 6.4 cannot resolve.
3. **Apple-only frameworks.** The core `CoreAgent` module (and everything that
   depends on it) hard-imports `FoundationModels`, plus `CoreGraphics` and
   Apple's system `CryptoKit`. None of these exist in the Linux Swift SDK
   (`import FoundationModels` → `no such module 'FoundationModels'`). Even the
   `RecordedLanguageModel` test-support path depends on `FoundationModels`, so
   the "no keys / no network" test flow described in the README still requires
   Apple SDKs.

### Where the real commands live (run these on macOS 27 + Xcode 27 only)

The canonical build/lint/test commands are already defined; do not duplicate
them. See `.github/workflows/ci.yml` and `README.md`:

- Lint: `xcrun swift-format lint --strict --recursive Package.swift Sources Tests`
- Build test targets: `swift build --build-tests`
- Test: `swift test` (and the trait matrix: `swift test --traits AllProviders`,
  `--traits AppleUtilities`, `--traits Claude`, `--traits Gemini`)
- Platform builds: `xcodebuild build -scheme CoreAgent-Package -destination 'generic/platform=iOS'`
  (and `generic/platform=visionOS`) with `CODE_SIGNING_ALLOWED=NO`

Note the project's own CI is gated behind an "Xcode 27 available on the runner"
check and is skipped until GitHub's macOS image ships Xcode 27, which reflects
the same bleeding-edge-toolchain reality.

### Practical guidance for Cloud agents

- Code review, reading, search, and non-compiling edits are fine on Linux.
- Any task requiring compilation/tests/lint must be validated on Apple hardware
  (local Xcode 27 or a macOS CI runner with Xcode 27), not in the Cloud VM.
