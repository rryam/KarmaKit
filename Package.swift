// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "FoundationModelsAgent",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
    .visionOS(.v27),
  ],
  products: [
    .library(name: "FoundationModelsAgent", targets: ["FoundationModelsAgent"]),
    .library(name: "FoundationModelsAgentMemory", targets: ["FoundationModelsAgentMemory"]),
    .library(
      name: "FoundationModelsAgentTestSupport", targets: ["FoundationModelsAgentTestSupport"]),
    .library(name: "FoundationModelsAgentProviders", targets: ["FoundationModelsAgentProviders"]),
  ],
  traits: [
    .trait(
      name: "AppleUtilities",
      description:
        "Enable Apple's FoundationModelsUtilities provider, including its generic Chat Completions client."
    ),
    .trait(
      name: "Claude",
      description: "Enable Anthropic's ClaudeForFoundationModels provider."
    ),
    .trait(
      name: "Gemini",
      description: "Enable Firebase AI Logic's Gemini Foundation Models provider."
    ),
    .trait(
      name: "AllProviders",
      description: "Enable every first-party provider integration.",
      enabledTraits: ["AppleUtilities", "Claude", "Gemini"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/foundation-models-utilities.git",
      revision: "376ca60e61985369d5067bd3c575bdb6a13f0e1b"
    ),
    .package(
      url: "https://github.com/anthropics/ClaudeForFoundationModels.git",
      exact: "0.1.4"
    ),
    .package(
      url: "https://github.com/firebase/firebase-ios-sdk.git",
      revision: "e1aea87c02dba201ff119b1c18dae58a024ad0ca"
    ),
  ],
  targets: [
    .target(
      name: "FoundationModelsAgent",
      // SwiftPM otherwise reports the DocC catalog as an unhandled source file.
      exclude: ["Documentation.docc"]
    ),
    .target(
      name: "FoundationModelsAgentMemory",
      dependencies: ["FoundationModelsAgent"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "FoundationModelsAgentTestSupport",
      dependencies: ["FoundationModelsAgent"]
    ),
    .target(
      name: "FoundationModelsAgentProviders",
      dependencies: [
        "FoundationModelsAgent",
        .product(
          name: "FoundationModelsUtilities",
          package: "foundation-models-utilities",
          condition: .when(traits: ["AppleUtilities"])
        ),
        .product(
          name: "ClaudeForFoundationModels",
          package: "ClaudeForFoundationModels",
          condition: .when(traits: ["Claude"])
        ),
        .product(
          name: "FirebaseAILogic",
          package: "firebase-ios-sdk",
          condition: .when(traits: ["Gemini"])
        ),
      ],
      swiftSettings: [
        .define("FOUNDATIONMODELSAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("FOUNDATIONMODELSAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("FOUNDATIONMODELSAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
    .testTarget(
      name: "FoundationModelsAgentTests",
      dependencies: ["FoundationModelsAgent", "FoundationModelsAgentTestSupport"]
    ),
    .testTarget(
      name: "FoundationModelsAgentProviderTests",
      dependencies: ["FoundationModelsAgent", "FoundationModelsAgentProviders"],
      swiftSettings: [
        .define("FOUNDATIONMODELSAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("FOUNDATIONMODELSAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("FOUNDATIONMODELSAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
    .testTarget(
      name: "FoundationModelsAgentMemoryTests",
      dependencies: ["FoundationModelsAgent", "FoundationModelsAgentMemory"]
    ),
    .testTarget(
      name: "FoundationModelsAgentMemoryIntegrationTests",
      dependencies: [
        "FoundationModelsAgent", "FoundationModelsAgentMemory", "FoundationModelsAgentTestSupport",
      ]
    ),
  ]
)
