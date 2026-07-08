// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "CoreAgentTalonChannels",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
    .visionOS(.v27),
  ],
  products: [
    .library(name: "CoreAgentTalonChannels", targets: ["CoreAgentTalonChannels"])
  ],
  traits: [
    .trait(
      name: "TalonChannels",
      description: "Enable host-provided Talon channel adapter contracts."
    )
  ],
  targets: [
    .target(
      name: "CoreAgentTalonChannels",
      path: ".",
      exclude: ["Package.swift"],
      swiftSettings: [
        .define("COREAGENT_TALON_CHANNELS", .when(traits: ["TalonChannels"]))
      ]
    )
  ]
)
