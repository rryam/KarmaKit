// Vendored from rudrankriyam/Core-AI-Framework-Lab (MIT), revision
// 02d7502b1e631f0773189fa2f044b52ade039aa7. Adapted: recipes load from a
// caller-supplied directory as well as a bundle, since a library cannot
// assume the 600 MiB of model assets ship in its own resources.

import Foundation

/// One stage of the Chatterbox pipeline.
public enum ChatterboxPipelineStage: String, CaseIterable, Sendable {
  case t3Embeddings
  case t3Transformer
  case s3gen
  case vocoder
}

enum ChatterboxEntrypointRole: String, Sendable {
  case decode
  case generateMel
  case prefill
  case synthesizeWaveform
}

struct ChatterboxResolvedStage: Sendable {
  let stage: ChatterboxPipelineStage
  let manifest: CoreAIRecipePipelineStageManifest
  let artifact: CoreAIArtifactManifest

  var requiredFunctionNames: Set<String> {
    Set(manifest.entrypoints.values)
  }

  func entrypoint(for role: ChatterboxEntrypointRole) throws -> String {
    guard let name = manifest.entrypoints[role.rawValue] else {
      throw CoreAIManifestValidationError.missingValue(
        path: "pipeline.stages.\(stage.rawValue).entrypoints.\(role.rawValue)"
      )
    }
    return name
  }
}

struct ChatterboxResolvedCapacity: Sendable, Equatable {
  let maximumTextTokens: Int
  let maximumSpeechTokens: Int
  let maximumContextLength: Int
  let requiresStopToken: Bool
  let t3LayerCount: Int
  let t3HeadCount: Int
  let t3HeadDimension: Int
  let t3StartSpeechToken: Int
  let t3StopSpeechToken: Int
  let speechTokenBufferCount: Int
  let endSilenceTokenCount: Int
  let silenceToken: Int
  let melNoiseFrameCount: Int
  let generatedMelFrameCount: Int
  let melFramesPerSpeechToken: Int
  let sourceChannelCount: Int
  let samplesPerMelFrame: Int
  let sampleRate: Int

  init(manifest: CoreAICapacityManifest) throws {
    try manifest.validate()
    guard let maximumTextTokens = manifest.maximumInputTokens else {
      throw CoreAIManifestValidationError.missingValue(
        path: "capacity.maximumInputTokens"
      )
    }
    guard let maximumSpeechTokens = manifest.maximumGeneratedTokens else {
      throw CoreAIManifestValidationError.missingValue(
        path: "capacity.maximumGeneratedTokens"
      )
    }
    guard let maximumContextLength = manifest.maximumContextTokens else {
      throw CoreAIManifestValidationError.missingValue(
        path: "capacity.maximumContextTokens"
      )
    }

    self.maximumTextTokens = maximumTextTokens
    self.maximumSpeechTokens = maximumSpeechTokens
    self.maximumContextLength = maximumContextLength
    requiresStopToken = manifest.requiresStopSignal
    t3LayerCount = try manifest.requiredParameter(named: "t3LayerCount")
    t3HeadCount = try manifest.requiredParameter(named: "t3HeadCount")
    t3HeadDimension = try manifest.requiredParameter(named: "t3HeadDimension")
    t3StartSpeechToken = try manifest.requiredParameter(named: "t3StartSpeechToken")
    t3StopSpeechToken = try manifest.requiredParameter(named: "t3StopSpeechToken")
    speechTokenBufferCount = try manifest.requiredParameter(
      named: "speechTokenBufferCount"
    )
    endSilenceTokenCount = try manifest.requiredParameter(
      named: "endSilenceTokenCount"
    )
    silenceToken = try manifest.requiredParameter(named: "silenceToken")
    melNoiseFrameCount = try manifest.requiredParameter(named: "melNoiseFrameCount")
    generatedMelFrameCount = try manifest.requiredParameter(
      named: "generatedMelFrameCount"
    )
    melFramesPerSpeechToken = try manifest.requiredParameter(
      named: "melFramesPerSpeechToken"
    )
    sourceChannelCount = try manifest.requiredParameter(named: "sourceChannelCount")
    samplesPerMelFrame = try manifest.requiredParameter(named: "samplesPerMelFrame")
    sampleRate = try manifest.requiredParameter(named: "sampleRate")

    let boundedValues: [(String, Int, ClosedRange<Int>)] = [
      ("maximumInputTokens", maximumTextTokens, 1...4_096),
      ("maximumGeneratedTokens", maximumSpeechTokens, 1...4_096),
      ("maximumContextTokens", maximumContextLength, 2...8_192),
      ("t3LayerCount", t3LayerCount, 1...256),
      ("t3HeadCount", t3HeadCount, 1...256),
      ("t3HeadDimension", t3HeadDimension, 1...4_096),
      ("t3StartSpeechToken", t3StartSpeechToken, 0...Int(Int32.max)),
      ("t3StopSpeechToken", t3StopSpeechToken, 0...Int(Int32.max)),
      ("speechTokenBufferCount", speechTokenBufferCount, 1...8_192),
      ("endSilenceTokenCount", endSilenceTokenCount, 0...8_192),
      ("silenceToken", silenceToken, 0...Int(Int32.max)),
      ("melNoiseFrameCount", melNoiseFrameCount, 1...65_536),
      ("generatedMelFrameCount", generatedMelFrameCount, 1...65_536),
      ("melFramesPerSpeechToken", melFramesPerSpeechToken, 1...1_024),
      ("sourceChannelCount", sourceChannelCount, 1...1_024),
      ("samplesPerMelFrame", samplesPerMelFrame, 1...65_536),
      ("sampleRate", sampleRate, 8_000...384_000),
    ]
    for (name, value, range) in boundedValues {
      try Self.require(value, in: range, named: name)
    }

    let bufferedSpeechTokens = try Self.safeSum(
      maximumSpeechTokens,
      endSilenceTokenCount,
      path: "capacity.maximumGeneratedTokens"
    )
    guard bufferedSpeechTokens <= speechTokenBufferCount else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "capacity.maximumGeneratedTokens",
        reason: "generated tokens plus end silence exceed the speech-token buffer"
      )
    }
    guard maximumSpeechTokens < maximumContextLength else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "capacity.maximumGeneratedTokens",
        reason: "it must be lower than maximumContextTokens"
      )
    }
    let expectedMelFrames = try Self.safeProduct(
      [speechTokenBufferCount, melFramesPerSpeechToken],
      maximum: 65_536,
      path: "capacity.parameters.generatedMelFrameCount"
    )
    guard generatedMelFrameCount == expectedMelFrames else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "capacity.parameters.generatedMelFrameCount",
        reason: "it must match buffered speech tokens times mel frames per token"
      )
    }
    _ = try Self.safeProduct(
      [t3LayerCount, t3HeadCount, maximumContextLength, t3HeadDimension],
      maximum: 100_000_000,
      path: "capacity.parameters.t3CacheShape"
    )
    _ = try Self.safeProduct(
      [80, melNoiseFrameCount],
      maximum: 5_000_000,
      path: "capacity.parameters.melNoiseFrameCount"
    )
    _ = try Self.safeProduct(
      [sourceChannelCount, generatedMelFrameCount, samplesPerMelFrame],
      maximum: 50_000_000,
      path: "capacity.parameters.vocoderNoiseShape"
    )
    _ = try Self.safeProduct(
      [sampleRate, 2],
      maximum: Int(UInt32.max),
      path: "capacity.parameters.sampleRate"
    )
  }

  private static func require(
    _ value: Int,
    in range: ClosedRange<Int>,
    named name: String
  ) throws {
    guard range.contains(value) else {
      let path =
        name.hasPrefix("maximum")
        ? "capacity.\(name)"
        : "capacity.parameters.\(name)"
      throw CoreAIManifestValidationError.invalidValue(
        path: path,
        reason: "it must be between \(range.lowerBound) and \(range.upperBound)"
      )
    }
  }

  private static func safeSum(_ lhs: Int, _ rhs: Int, path: String) throws -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
      throw CoreAIManifestValidationError.invalidValue(
        path: path,
        reason: "the configured values overflow the runtime integer range"
      )
    }
    return result
  }

  private static func safeProduct(
    _ values: [Int],
    maximum: Int,
    path: String
  ) throws -> Int {
    var product = 1
    for value in values {
      let (next, overflow) = product.multipliedReportingOverflow(by: value)
      guard !overflow, next <= maximum else {
        throw CoreAIManifestValidationError.invalidValue(
          path: path,
          reason: "the configured shape exceeds the safe runtime capacity"
        )
      }
      product = next
    }
    return product
  }
}

struct ChatterboxRecipeContract: Sendable {
  let manifest: CoreAIRecipeManifest
  let target: CoreAITargetManifest
  let tokenizerArtifact: CoreAIArtifactManifest
  let capacity: ChatterboxResolvedCapacity
  private let stagesByID: [ChatterboxPipelineStage: ChatterboxResolvedStage]

  init(manifest: CoreAIRecipeManifest) throws {
    try manifest.validate()
    guard manifest.pipeline.experience == .textToSpeech else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "pipeline.experience",
        reason: "Chatterbox requires the textToSpeech experience"
      )
    }
    guard let target = manifest.defaultTarget else {
      throw CoreAIManifestValidationError.unknownReference(
        path: "recipe.defaultTargetID",
        identifier: manifest.defaultTargetID
      )
    }
    guard let tokenizerID = manifest.pipeline.tokenizerArtifactID,
      let tokenizerArtifact = manifest.artifact(id: tokenizerID)
    else {
      throw CoreAIManifestValidationError.missingValue(
        path: "pipeline.tokenizerArtifactID"
      )
    }

    var resolvedStages = [ChatterboxPipelineStage: ChatterboxResolvedStage]()
    for stageManifest in manifest.pipeline.stages {
      guard let stage = ChatterboxPipelineStage(rawValue: stageManifest.id) else {
        throw CoreAIManifestValidationError.invalidValue(
          path: "pipeline.stages.\(stageManifest.id).id",
          reason: "the stage is not supported by the Chatterbox runtime adapter"
        )
      }
      guard let artifact = manifest.artifact(id: stageManifest.artifactID) else {
        throw CoreAIManifestValidationError.unknownReference(
          path: "pipeline.stages.\(stageManifest.id).artifactID",
          identifier: stageManifest.artifactID
        )
      }
      resolvedStages[stage] = ChatterboxResolvedStage(
        stage: stage,
        manifest: stageManifest,
        artifact: artifact
      )
    }
    let missingStages = Set(ChatterboxPipelineStage.allCases)
      .subtracting(resolvedStages.keys)
    guard missingStages.isEmpty else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "pipeline.stages",
        reason:
          "missing Chatterbox stages: \(missingStages.map(\.rawValue).sorted().joined(separator: ", "))"
      )
    }

    self.manifest = manifest
    self.target = target
    self.tokenizerArtifact = tokenizerArtifact
    capacity = try ChatterboxResolvedCapacity(manifest: manifest.capacity)
    stagesByID = resolvedStages
    try validateEntrypointRoles()
  }

  func resolvedStage(_ stage: ChatterboxPipelineStage) throws -> ChatterboxResolvedStage {
    guard let resolved = stagesByID[stage] else {
      throw CoreAIManifestValidationError.missingValue(
        path: "pipeline.stages.\(stage.rawValue)"
      )
    }
    return resolved
  }

  private func validateEntrypointRoles() throws {
    for stage in [ChatterboxPipelineStage.t3Embeddings, .t3Transformer] {
      try validateEntrypointRoles([.prefill, .decode], for: stage)
    }
    try validateEntrypointRoles([.generateMel], for: .s3gen)
    try validateEntrypointRoles([.synthesizeWaveform], for: .vocoder)
  }

  private func validateEntrypointRoles(
    _ expectedRoles: Set<ChatterboxEntrypointRole>,
    for stage: ChatterboxPipelineStage
  ) throws {
    let resolved = try resolvedStage(stage)
    let expectedKeys = Set(expectedRoles.map(\.rawValue))
    let actualKeys = Set(resolved.manifest.entrypoints.keys)
    guard actualKeys == expectedKeys else {
      throw CoreAIManifestValidationError.invalidValue(
        path: "pipeline.stages.\(stage.rawValue).entrypoints",
        reason: "expected exactly these roles: \(expectedKeys.sorted().joined(separator: ", "))"
      )
    }
    for role in expectedRoles {
      _ = try resolved.entrypoint(for: role)
    }
  }
}

/// A validated on-disk Chatterbox recipe: `recipe.json` plus the model
/// and tokenizer artifacts it references.
struct ChatterboxRecipeResources: Sendable {
  let rootURL: URL
  let contract: ChatterboxRecipeContract
  let tokenizerURL: URL
  private let artifactURLsByID: [String: URL]

  /// Loads the recipe shipped in a bundle's `Chatterbox` resource
  /// directory.
  init(bundle: Bundle) throws {
    guard
      let rootURL = bundle.url(
        forResource: "Chatterbox",
        withExtension: nil
      )
    else {
      throw ChatterboxEngineError.resourcesMissing
    }
    try self.init(directory: rootURL)
  }

  /// Loads a recipe from a directory containing `recipe.json` and its
  /// artifacts, such as a download location or a developer checkout.
  init(directory rootURL: URL) throws {
    let rootURL = rootURL.standardizedFileURL
    guard
      try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        != true
    else {
      throw ChatterboxEngineError.unsafeResourcePath(rootURL.path)
    }
    let manifestURL = try Self.validatedArtifactURL(
      rootURL: rootURL,
      relativePath: "recipe.json"
    )
    let manifest = try JSONDecoder().decode(
      CoreAIRecipeManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    let contract = try ChatterboxRecipeContract(manifest: manifest)

    var artifactURLsByID: [String: URL] = [:]
    for artifact in manifest.artifacts {
      artifactURLsByID[artifact.id] = try Self.validatedArtifactURL(
        rootURL: rootURL,
        relativePath: artifact.relativePath
      )
    }
    guard let tokenizerURL = artifactURLsByID[contract.tokenizerArtifact.id] else {
      throw ChatterboxEngineError.resourcesMissing
    }

    self.rootURL = rootURL
    self.contract = contract
    self.tokenizerURL = tokenizerURL
    self.artifactURLsByID = artifactURLsByID
  }

  func modelURL(for stage: ChatterboxPipelineStage) throws -> URL {
    let artifact = try contract.resolvedStage(stage).artifact
    guard let url = artifactURLsByID[artifact.id] else {
      throw ChatterboxEngineError.resourcesMissing
    }
    return url
  }

  private static func validatedArtifactURL(
    rootURL: URL,
    relativePath: String
  ) throws -> URL {
    let candidate = rootURL.appending(path: relativePath).standardizedFileURL
    guard isDescendant(candidate, of: rootURL) else {
      throw ChatterboxEngineError.unsafeResourcePath(relativePath)
    }

    var currentURL = rootURL
    let rootComponentCount = rootURL.pathComponents.count
    for component in candidate.pathComponents.dropFirst(rootComponentCount) {
      currentURL.append(path: component)
      guard FileManager.default.fileExists(atPath: currentURL.path) else {
        throw ChatterboxEngineError.resourcesMissing
      }
      let values = try currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw ChatterboxEngineError.unsafeResourcePath(relativePath)
      }
    }

    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(resolvedCandidate, of: resolvedRoot) else {
      throw ChatterboxEngineError.unsafeResourcePath(relativePath)
    }
    try rejectDescendantSymlinks(
      in: candidate,
      relativePath: relativePath
    )
    return resolvedCandidate
  }

  private static func rejectDescendantSymlinks(
    in artifactURL: URL,
    relativePath: String
  ) throws {
    let resourceValues = try artifactURL.resourceValues(
      forKeys: [.isDirectoryKey]
    )
    guard resourceValues.isDirectory == true else { return }

    var enumerationError: Error?
    let enumerator = FileManager.default.enumerator(
      at: artifactURL,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    )
    guard let enumerator else {
      throw ChatterboxEngineError.resourcesMissing
    }
    for case let descendantURL as URL in enumerator {
      let values = try descendantURL.resourceValues(
        forKeys: [.isSymbolicLinkKey]
      )
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        throw ChatterboxEngineError.unsafeResourcePath(relativePath)
      }
    }
    if let enumerationError {
      throw enumerationError
    }
  }

  private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootComponents = root.pathComponents
    let candidateComponents = candidate.pathComponents
    return candidateComponents.count > rootComponents.count
      && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
  }
}
