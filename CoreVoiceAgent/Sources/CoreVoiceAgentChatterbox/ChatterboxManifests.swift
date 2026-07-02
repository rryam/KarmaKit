// Vendored from rudrankriyam/Core-AI-Framework-Lab (MIT), revision
// 02d7502b1e631f0773189fa2f044b52ade039aa7, and adapted for library use:
// the manifest layer is internal here, and recipes load from a directory
// URL as well as a bundle.

import Foundation

enum CoreAIRecipeArtifactKind: String, Codable, CaseIterable, Sendable {
  case modelAsset
  case resourceBundle
  case tokenizer
  case auxiliaryFile
}

struct CoreAIArtifactManifest: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: String
  let displayName: String
  let kind: CoreAIRecipeArtifactKind
  let relativePath: String
  let precision: String?
  let requiredEntrypoints: [String]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    id: String,
    displayName: String,
    kind: CoreAIRecipeArtifactKind,
    relativePath: String,
    precision: String? = nil,
    requiredEntrypoints: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.relativePath = relativePath
    self.precision = precision
    self.requiredEntrypoints = requiredEntrypoints
  }

  func validate(path: String = "artifact") throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "\(path).schemaVersion"
    )
    try CoreAIManifestValidator.requireNonempty(id, path: "\(path).id")
    try CoreAIManifestValidator.requireNonempty(
      displayName,
      path: "\(path).displayName"
    )
    try CoreAIManifestValidator.requireSafeRelativePath(
      relativePath,
      path: "\(path).relativePath"
    )
    try CoreAIManifestValidator.requireUniqueIdentifiers(
      requiredEntrypoints,
      path: "\(path).requiredEntrypoints",
      identifier: { $0 }
    )
    for (index, entrypoint) in requiredEntrypoints.enumerated() {
      try CoreAIManifestValidator.requireNonempty(
        entrypoint,
        path: "\(path).requiredEntrypoints[\(index)]"
      )
    }
    if kind != .modelAsset && !requiredEntrypoints.isEmpty {
      throw CoreAIManifestValidationError.invalidValue(
        path: "\(path).requiredEntrypoints",
        reason: "only model assets can declare Core AI entrypoints"
      )
    }
  }
}

struct CoreAICapacityManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let maximumInputTokens: Int?
  let maximumGeneratedTokens: Int?
  let maximumContextTokens: Int?
  let requiresStopSignal: Bool
  let parameters: [String: Int]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    maximumInputTokens: Int? = nil,
    maximumGeneratedTokens: Int? = nil,
    maximumContextTokens: Int? = nil,
    requiresStopSignal: Bool = false,
    parameters: [String: Int] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.maximumInputTokens = maximumInputTokens
    self.maximumGeneratedTokens = maximumGeneratedTokens
    self.maximumContextTokens = maximumContextTokens
    self.requiresStopSignal = requiresStopSignal
    self.parameters = parameters
  }

  func validate(path: String = "capacity") throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "\(path).schemaVersion"
    )
    try validatePositive(maximumInputTokens, path: "\(path).maximumInputTokens")
    try validatePositive(
      maximumGeneratedTokens,
      path: "\(path).maximumGeneratedTokens"
    )
    try validatePositive(
      maximumContextTokens,
      path: "\(path).maximumContextTokens"
    )
    if let maximumInputTokens,
      let maximumContextTokens,
      maximumInputTokens >= maximumContextTokens
    {
      throw CoreAIManifestValidationError.invalidValue(
        path: "\(path).maximumInputTokens",
        reason: "it must be lower than maximumContextTokens"
      )
    }
    for (name, value) in parameters {
      try CoreAIManifestValidator.requireNonempty(
        name,
        path: "\(path).parameters.key"
      )
      guard value >= 0 else {
        throw CoreAIManifestValidationError.invalidValue(
          path: "\(path).parameters.\(name)",
          reason: "it must be zero or greater"
        )
      }
    }
  }

  func requiredParameter(named name: String, path: String = "capacity") throws -> Int {
    guard let value = parameters[name] else {
      throw CoreAIManifestValidationError.missingValue(
        path: "\(path).parameters.\(name)"
      )
    }
    return value
  }

  private func validatePositive(_ value: Int?, path: String) throws {
    guard let value else { return }
    guard value > 0 else {
      throw CoreAIManifestValidationError.invalidValue(
        path: path,
        reason: "it must be greater than zero"
      )
    }
  }
}

enum CoreAIManifestValidationError: Error, Equatable, LocalizedError {
  case unsupportedSchemaVersion(path: String, found: Int, supported: Int)
  case missingValue(path: String)
  case duplicateIdentifier(path: String, identifier: String)
  case invalidRelativePath(path: String, value: String)
  case invalidValue(path: String, reason: String)
  case unknownReference(path: String, identifier: String)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let path, let found, let supported):
      "\(path) uses schema version \(found); this build supports version \(supported)."
    case .missingValue(let path):
      "\(path) must not be empty."
    case .duplicateIdentifier(let path, let identifier):
      "\(path) contains the duplicate identifier \(identifier)."
    case .invalidRelativePath(let path, let value):
      "\(path) must be a safe relative path, but found \(value)."
    case .invalidValue(let path, let reason):
      "\(path) is invalid: \(reason)"
    case .unknownReference(let path, let identifier):
      "\(path) references the unknown identifier \(identifier)."
    }
  }
}

enum CoreAIManifestValidator {
  static func requireCurrentSchemaVersion(
    _ found: Int,
    supported: Int,
    path: String
  ) throws {
    guard found == supported else {
      throw CoreAIManifestValidationError.unsupportedSchemaVersion(
        path: path,
        found: found,
        supported: supported
      )
    }
  }

  static func requireNonempty(_ value: String, path: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAIManifestValidationError.missingValue(path: path)
    }
  }

  static func requireUniqueIdentifiers<T>(
    _ values: [T],
    path: String,
    identifier: (T) -> String
  ) throws {
    var identifiers = Set<String>()
    for value in values {
      let valueIdentifier = identifier(value)
      guard identifiers.insert(valueIdentifier).inserted else {
        throw CoreAIManifestValidationError.duplicateIdentifier(
          path: path,
          identifier: valueIdentifier
        )
      }
    }
  }

  static func requireSafeRelativePath(_ value: String, path: String) throws {
    try requireNonempty(value, path: path)
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    let isUnsafe =
      value.hasPrefix("/")
      || value.hasPrefix("~")
      || value.contains("\\")
      || components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    guard !isUnsafe else {
      throw CoreAIManifestValidationError.invalidRelativePath(
        path: path,
        value: value
      )
    }
  }
}

struct CoreAIRecipeSourceManifest: Codable, Equatable, Sendable {
  let repository: String
  let revision: String
  let license: String

  func validate(path: String = "source") throws {
    try CoreAIManifestValidator.requireNonempty(
      repository,
      path: "\(path).repository"
    )
    try CoreAIManifestValidator.requireNonempty(
      revision,
      path: "\(path).revision"
    )
    try CoreAIManifestValidator.requireNonempty(license, path: "\(path).license")
  }
}

struct CoreAIRecipeManifest: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: String
  let revision: String
  let displayName: String
  let summary: String
  let systemImage: String
  let source: CoreAIRecipeSourceManifest
  let defaultTargetID: String
  let targets: [CoreAITargetManifest]
  let artifacts: [CoreAIArtifactManifest]
  let pipeline: CoreAIRecipePipelineManifest
  let capacity: CoreAICapacityManifest

  var defaultTarget: CoreAITargetManifest? {
    targets.first { $0.id == defaultTargetID }
  }

  func artifact(id: String) -> CoreAIArtifactManifest? {
    artifacts.first { $0.id == id }
  }

  func validate() throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "recipe.schemaVersion"
    )
    try CoreAIManifestValidator.requireNonempty(id, path: "recipe.id")
    try CoreAIManifestValidator.requireNonempty(revision, path: "recipe.revision")
    try CoreAIManifestValidator.requireNonempty(
      displayName,
      path: "recipe.displayName"
    )
    try CoreAIManifestValidator.requireNonempty(summary, path: "recipe.summary")
    try CoreAIManifestValidator.requireNonempty(
      systemImage,
      path: "recipe.systemImage"
    )
    try source.validate()
    guard !targets.isEmpty else {
      throw CoreAIManifestValidationError.missingValue(path: "recipe.targets")
    }
    try CoreAIManifestValidator.requireUniqueIdentifiers(
      targets,
      path: "recipe.targets",
      identifier: \.id
    )
    for (index, target) in targets.enumerated() {
      try target.validate(path: "recipe.targets[\(index)]")
    }
    guard defaultTarget != nil else {
      throw CoreAIManifestValidationError.unknownReference(
        path: "recipe.defaultTargetID",
        identifier: defaultTargetID
      )
    }

    guard !artifacts.isEmpty else {
      throw CoreAIManifestValidationError.missingValue(path: "recipe.artifacts")
    }
    try CoreAIManifestValidator.requireUniqueIdentifiers(
      artifacts,
      path: "recipe.artifacts",
      identifier: \.id
    )
    try CoreAIManifestValidator.requireUniqueIdentifiers(
      artifacts,
      path: "recipe.artifacts.relativePath",
      identifier: \.relativePath
    )
    for (index, artifact) in artifacts.enumerated() {
      try artifact.validate(path: "recipe.artifacts[\(index)]")
    }
    let artifactsByID = Dictionary(
      uniqueKeysWithValues: artifacts.map { ($0.id, $0) }
    )
    try pipeline.validate(artifactsByID: artifactsByID)
    try capacity.validate()
  }
}

enum CoreAIExperienceKind: String, Codable, CaseIterable, Sendable {
  case audio
  case diffusion
  case embeddings
  case generic
  case textGeneration
  case textToSpeech
  case vision
}

struct CoreAIRecipePipelineStageManifest: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: String
  let displayName: String
  let detail: String
  let artifactID: String
  let entrypoints: [String: String]

  func validate(
    artifactsByID: [String: CoreAIArtifactManifest],
    path: String
  ) throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "\(path).schemaVersion"
    )
    try CoreAIManifestValidator.requireNonempty(id, path: "\(path).id")
    try CoreAIManifestValidator.requireNonempty(
      displayName,
      path: "\(path).displayName"
    )
    try CoreAIManifestValidator.requireNonempty(detail, path: "\(path).detail")
    guard let artifact = artifactsByID[artifactID] else {
      throw CoreAIManifestValidationError.unknownReference(
        path: "\(path).artifactID",
        identifier: artifactID
      )
    }
    guard artifact.kind == .modelAsset else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "\(path).artifactID",
        reason: "pipeline stages must reference a model asset"
      )
    }
    guard !entrypoints.isEmpty else {
      throw CoreAIManifestValidationError.missingValue(
        path: "\(path).entrypoints"
      )
    }
    let requiredEntrypoints = Set(artifact.requiredEntrypoints)
    for (role, entrypoint) in entrypoints {
      try CoreAIManifestValidator.requireNonempty(
        role,
        path: "\(path).entrypoints.role"
      )
      try CoreAIManifestValidator.requireNonempty(
        entrypoint,
        path: "\(path).entrypoints.\(role)"
      )
      guard requiredEntrypoints.contains(entrypoint) else {
        throw CoreAIManifestValidationError.unknownReference(
          path: "\(path).entrypoints.\(role)",
          identifier: entrypoint
        )
      }
    }
    guard Set(entrypoints.values) == requiredEntrypoints else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "\(path).entrypoints",
        reason: "the stage must map every required artifact entrypoint"
      )
    }
  }
}

struct CoreAIRecipePipelineManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let experience: CoreAIExperienceKind
  let tokenizerArtifactID: String?
  let stages: [CoreAIRecipePipelineStageManifest]

  func validate(
    artifactsByID: [String: CoreAIArtifactManifest],
    path: String = "pipeline"
  ) throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "\(path).schemaVersion"
    )
    guard !stages.isEmpty else {
      throw CoreAIManifestValidationError.missingValue(path: "\(path).stages")
    }
    try CoreAIManifestValidator.requireUniqueIdentifiers(
      stages,
      path: "\(path).stages",
      identifier: \.id
    )
    if let tokenizerArtifactID {
      guard let tokenizer = artifactsByID[tokenizerArtifactID] else {
        throw CoreAIManifestValidationError.unknownReference(
          path: "\(path).tokenizerArtifactID",
          identifier: tokenizerArtifactID
        )
      }
      guard tokenizer.kind == .tokenizer else {
        throw CoreAIManifestValidationError.invalidValue(
          path: "\(path).tokenizerArtifactID",
          reason: "the referenced artifact is not a tokenizer"
        )
      }
    }
    for (index, stage) in stages.enumerated() {
      try stage.validate(
        artifactsByID: artifactsByID,
        path: "\(path).stages[\(index)]"
      )
    }
  }
}

enum CoreAITargetPlatform: String, Codable, CaseIterable, Sendable {
  case iOS
  case macOS
}

enum CoreAIComputeUnitPreference: String, Codable, CaseIterable, Sendable {
  case automatic
  case cpu
  case gpu
  case neuralEngine
}

struct CoreAITargetManifest: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: String
  let displayName: String
  let platform: CoreAITargetPlatform
  let minimumOSVersion: String
  let preferredComputeUnit: CoreAIComputeUnitPreference
  let expectsFrequentReshapes: Bool

  func validate(path: String = "target") throws {
    try CoreAIManifestValidator.requireCurrentSchemaVersion(
      schemaVersion,
      supported: Self.currentSchemaVersion,
      path: "\(path).schemaVersion"
    )
    try CoreAIManifestValidator.requireNonempty(id, path: "\(path).id")
    try CoreAIManifestValidator.requireNonempty(
      displayName,
      path: "\(path).displayName"
    )
    try CoreAIManifestValidator.requireNonempty(
      minimumOSVersion,
      path: "\(path).minimumOSVersion"
    )
  }
}

extension Duration {
  /// This duration expressed in seconds.
  var chatterboxSeconds: Double {
    let components = components
    return Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
