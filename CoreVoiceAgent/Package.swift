// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CoreVoiceAgent",
  platforms: [
    .iOS("27.0"),
    .macOS("27.0"),
  ],
  products: [
    // The umbrella product: the voice pipeline plus the CoreAgent-backed
    // conversation brain (on-device Foundation Models by default, any
    // `LanguageModel` by construction).
    .library(name: "CoreVoiceAgent", targets: ["CoreVoiceAgent"]),
    // The platform-independent voice pipeline: protocols, endpointing,
    // sentence chunking, and the session orchestrator. No Apple-only
    // framework imports; compiles and tests on Linux.
    .library(name: "CoreVoiceAgentCore", targets: ["CoreVoiceAgentCore"]),
    // NVIDIA Parakeet-TDT-0.6B speech-to-text through Core AI, via the
    // community coreai-kit runtime.
    .library(name: "CoreVoiceAgentParakeet", targets: ["CoreVoiceAgentParakeet"]),
    // Resemble AI Chatterbox Turbo text-to-speech through Core AI, vendored
    // from Core-AI-Framework-Lab and adapted to return raw samples.
    .library(name: "CoreVoiceAgentChatterbox", targets: ["CoreVoiceAgentChatterbox"]),
    // AVAudioEngine microphone capture (voice-processed, echo-cancelled)
    // and speaker playback.
    .library(name: "CoreVoiceAgentAudio", targets: ["CoreVoiceAgentAudio"]),
    // Deterministic scripted transcriber/responder/synthesizer and audio
    // fixtures for tests. No network, no models, no audio hardware.
    .library(name: "CoreVoiceAgentTestSupport", targets: ["CoreVoiceAgentTestSupport"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/rudrankriyam/CoreAgent.git",
      from: "0.3.0"
    ),
    // Community Core AI runtime that ships KitParakeetModel. No release tag
    // yet, so the dependency pins a verified commit.
    .package(
      url: "https://github.com/john-rocky/coreai-kit.git",
      revision: "7ddc5cce7770a4d283e15c8b191ce5584936f1b4"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers.git",
      from: "1.1.0"
    ),
  ],
  targets: [
    .target(name: "CoreVoiceAgentCore"),
    .target(
      name: "CoreVoiceAgent",
      dependencies: [
        "CoreVoiceAgentCore",
        .product(name: "CoreAgent", package: "CoreAgent"),
      ]
    ),
    .target(
      name: "CoreVoiceAgentParakeet",
      dependencies: [
        "CoreVoiceAgentCore",
        .product(name: "CoreAIKit", package: "coreai-kit"),
      ]
    ),
    .target(
      name: "CoreVoiceAgentChatterbox",
      dependencies: [
        "CoreVoiceAgentCore",
        .product(name: "Transformers", package: "swift-transformers"),
      ],
      linkerSettings: [
        .linkedFramework("CoreAI")
      ]
    ),
    .target(
      name: "CoreVoiceAgentAudio",
      dependencies: ["CoreVoiceAgentCore"],
      linkerSettings: [
        .linkedFramework("AVFoundation")
      ]
    ),
    .target(
      name: "CoreVoiceAgentTestSupport",
      dependencies: ["CoreVoiceAgentCore"]
    ),
    .testTarget(
      name: "CoreVoiceAgentCoreTests",
      dependencies: ["CoreVoiceAgentCore", "CoreVoiceAgentTestSupport"]
    ),
  ]
)
