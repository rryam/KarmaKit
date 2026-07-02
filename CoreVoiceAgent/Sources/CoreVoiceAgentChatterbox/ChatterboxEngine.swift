// Vendored from rudrankriyam/Core-AI-Framework-Lab (MIT), revision
// 02d7502b1e631f0773189fa2f044b52ade039aa7 (ChatterboxCoreAIEngine).
// Adapted for library use: the engine loads recipes from a directory as
// well as a bundle, and returns the raw waveform instead of writing a
// WAV file, so the voice loop can stream chunks straight into playback.

#if canImport(CoreAI)
import CoreAI
import Foundation
import Tokenizers

/// The Chatterbox Turbo text-to-speech pipeline running natively through
/// Core AI.
///
/// Four `.aimodel` assets drive the fixed-voice inference path: T3
/// embeddings, the INT4 T3 transformer with persistent KV caches, the
/// S3Gen mean-flow decoder, and the HiFT vocoder. `prepare()` specializes
/// and validates all four against the recipe contract; `synthesize(_:)`
/// runs one text chunk through the complete pipeline and returns 24 kHz
/// audio.
///
/// ```swift
/// let engine = ChatterboxEngine(recipeDirectory: modelsDirectory)
/// let inspection = try await engine.prepare()
/// let result = try await engine.synthesize(
///   ChatterboxGenerationRequest(text: "Hello from Core AI.")
/// )
/// ```
///
/// The engine is an actor and runs one generation at a time, which is the
/// contract `VoiceAgentSession` relies on for ordered chunk synthesis.
public actor ChatterboxEngine {
  private struct SpeechTokenGeneration: Sendable {
    let tokens: [Int]
    let reachedStopToken: Bool
    let setupTime: TimeInterval
    let prefillTime: TimeInterval
    let embeddingInferenceTime: TimeInterval
    let transformerInferenceTime: TimeInterval
    let decodeInferenceTime: TimeInterval
    let decodeHostTime: TimeInterval
  }

  private struct MelGeneration: Sendable {
    let mel: NDArray
    let setupTime: TimeInterval
    let noiseTime: TimeInterval
    let inferenceTime: TimeInterval
  }

  private struct WaveformGeneration: Sendable {
    let waveform: [Float]
    let setupTime: TimeInterval
    let noiseTime: TimeInterval
    let inferenceTime: TimeInterval
  }

  private struct PreparedPipeline: Sendable {
    let embeddingPrefill: InferenceFunction
    let embeddingDecode: InferenceFunction
    let transformerPrefill: InferenceFunction
    let transformerDecode: InferenceFunction
    let s3GenURL: URL
    let s3GenEntrypoint: String
    let vocoderURL: URL
    let vocoderEntrypoint: String
    let capacity: ChatterboxResolvedCapacity
  }

  private enum RecipeSource: Sendable {
    case bundle(Bundle)
    case directory(URL)
  }

  private let recipeSource: RecipeSource
  private let fileManager = FileManager.default
  private var tokenizer: (any Tokenizer)?
  private var pipeline: PreparedPipeline?
  private var preferredComputeUnit = CoreAIComputeUnitPreference.automatic

  /// Creates an engine that loads the recipe from a bundle's
  /// `Chatterbox` resource directory.
  public init(bundle: Bundle = .main) {
    recipeSource = .bundle(bundle)
  }

  /// Creates an engine that loads the recipe from a directory containing
  /// `recipe.json` and the artifacts it references.
  ///
  /// - Parameter recipeDirectory: The directory holding the recipe, the
  ///   four `.aimodel` assets, and the tokenizer.
  public init(recipeDirectory: URL) {
    recipeSource = .directory(recipeDirectory)
  }

  /// The sample rate of generated audio, available after `prepare()`.
  public var outputSampleRate: Int? {
    pipeline?.capacity.sampleRate
  }

  /// Specializes, caches, and validates the four pipeline assets.
  ///
  /// Core AI persistently caches the specialized models, so the first
  /// call on a device is the slow one.
  ///
  /// - Returns: A summary of the prepared assets.
  @discardableResult
  public func prepare() async throws -> ChatterboxModelInspection {
    let resources = try loadResources()
    let contract = resources.contract
    let tokenizer = try await AutoTokenizer.from(
      modelFolder: resources.tokenizerURL
    )
    try validateTokenizer(tokenizer)

    preferredComputeUnit = contract.target.preferredComputeUnit
    let options = specializationOptions(for: preferredComputeUnit)
    var assets = [ChatterboxAssetInspection]()
    var models = [ChatterboxPipelineStage: AIModel]()
    var author = ""
    var license = contract.manifest.source.license

    for stage in ChatterboxPipelineStage.allCases {
      let resolvedStage = try contract.resolvedStage(stage)
      let url = try resources.modelURL(for: stage)
      guard AIModelAsset.isValid(at: url) else {
        throw ChatterboxEngineError.invalidModelAsset(
          resolvedStage.artifact.relativePath
        )
      }

      let asset = try AIModelAsset(contentsOf: url)
      let model = try await AIModel.specialize(
        contentsOf: url,
        options: options,
        cache: .default,
        cachePolicy: .persistent
      )
      let functionNames = model.functionNames.sorted()
      let functionNameSet = Set(functionNames)
      let missingFunctions = resolvedStage.requiredFunctionNames
        .subtracting(functionNameSet)
        .sorted()
      guard missingFunctions.isEmpty else {
        throw ChatterboxEngineError.missingEntrypoints(
          asset: resolvedStage.artifact.relativePath,
          names: missingFunctions
        )
      }

      models[stage] = model
      assets.append(
        ChatterboxAssetInspection(
          stage: stage,
          displayName: resolvedStage.manifest.displayName,
          detail: resolvedStage.manifest.detail,
          sourceURL: url,
          functionNames: functionNames,
          sizeInBytes: try allocatedSize(of: url)
        )
      )
      if author.isEmpty {
        author = asset.metadata.author
      }
      if license.isEmpty {
        license = asset.metadata.license
      }
    }

    guard let embeddingsModel = models[.t3Embeddings],
      models[.t3Transformer] != nil,
      models[.s3gen] != nil,
      models[.vocoder] != nil,
      let transformerModel = models[.t3Transformer]
    else {
      throw ChatterboxEngineError.resourcesMissing
    }
    pipeline = PreparedPipeline(
      embeddingPrefill: try loadFunction(
        contract.resolvedStage(.t3Embeddings).entrypoint(for: .prefill),
        from: embeddingsModel
      ),
      embeddingDecode: try loadFunction(
        contract.resolvedStage(.t3Embeddings).entrypoint(for: .decode),
        from: embeddingsModel
      ),
      transformerPrefill: try loadFunction(
        contract.resolvedStage(.t3Transformer).entrypoint(for: .prefill),
        from: transformerModel
      ),
      transformerDecode: try loadFunction(
        contract.resolvedStage(.t3Transformer).entrypoint(for: .decode),
        from: transformerModel
      ),
      s3GenURL: try resources.modelURL(for: .s3gen),
      s3GenEntrypoint: try contract.resolvedStage(.s3gen)
        .entrypoint(for: .generateMel),
      vocoderURL: try resources.modelURL(for: .vocoder),
      vocoderEntrypoint: try contract.resolvedStage(.vocoder)
        .entrypoint(for: .synthesizeWaveform),
      capacity: contract.capacity
    )
    self.tokenizer = tokenizer

    return ChatterboxModelInspection(
      displayName: contract.manifest.displayName,
      author: author,
      license: license,
      deviceArchitectureName: AIModel.deviceArchitectureName,
      assets: assets,
      sampleRate: contract.capacity.sampleRate
    )
  }

  /// Runs one text chunk through the complete pipeline.
  ///
  /// - Parameter request: The text, seed, and token budget.
  /// - Returns: The generated waveform with per-stage metrics.
  public func synthesize(
    _ request: ChatterboxGenerationRequest
  ) async throws -> ChatterboxGenerationResult {
    guard let pipeline, let tokenizer else {
      throw ChatterboxEngineError.modelNotPrepared
    }

    let trimmedText = request.text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmedText.isEmpty else {
      throw ChatterboxEngineError.emptyPrompt
    }

    let startedAt = ContinuousClock.now
    let textPreparationStartedAt = ContinuousClock.now
    let normalizedText = ChatterboxTextNormalizer.normalize(trimmedText)
    let textTokens = tokenizer.encode(text: normalizedText)
    let capacity = pipeline.capacity
    guard textTokens.count <= capacity.maximumTextTokens else {
      throw ChatterboxEngineError.textTooLong(
        tokenCount: textTokens.count,
        maximumTokenCount: capacity.maximumTextTokens
      )
    }
    let textPreparationTime = textPreparationStartedAt.duration(
      to: .now
    ).chatterboxSeconds

    let maximumGeneratedTokens = min(
      max(request.maximumGeneratedTokens, 1),
      capacity.maximumSpeechTokens
    )
    let random = ChatterboxRandomGenerator(seed: request.seed)
    let generation = try await generateSpeechTokens(
      pipeline: pipeline,
      textTokens: textTokens.map(Int32.init),
      maximumGeneratedTokens: maximumGeneratedTokens,
      random: random
    )
    if capacity.requiresStopToken && !generation.reachedStopToken {
      throw ChatterboxEngineError.generationLimitReached
    }
    let speechTokens = generation.tokens
    let melGeneration = try await generateMel(
      modelURL: pipeline.s3GenURL,
      functionName: pipeline.s3GenEntrypoint,
      speechTokens: speechTokens,
      capacity: capacity,
      random: random
    )
    let waveformGeneration = try await generateWaveform(
      modelURL: pipeline.vocoderURL,
      functionName: pipeline.vocoderEntrypoint,
      mel: melGeneration.mel,
      capacity: capacity,
      random: random
    )
    let audioPostprocessingStartedAt = ContinuousClock.now
    let fullWaveform = waveformGeneration.waveform
    let outputSampleCount = min(
      fullWaveform.count,
      (speechTokens.count + capacity.endSilenceTokenCount)
        * capacity.melFramesPerSpeechToken
        * capacity.samplesPerMelFrame
    )
    let waveform = Array(fullWaveform.prefix(outputSampleCount))
    let audioPostprocessingTime = audioPostprocessingStartedAt.duration(
      to: .now
    ).chatterboxSeconds
    let elapsedTime = startedAt.duration(to: .now).chatterboxSeconds

    return ChatterboxGenerationResult(
      samples: waveform,
      sampleRate: capacity.sampleRate,
      normalizedText: normalizedText,
      generatedTokenCount: speechTokens.count,
      elapsedTime: elapsedTime,
      metrics: ChatterboxGenerationMetrics(
        textPreparation: textPreparationTime,
        t3Setup: generation.setupTime,
        t3Prefill: generation.prefillTime,
        t3EmbeddingInference: generation.embeddingInferenceTime,
        t3TransformerInference: generation.transformerInferenceTime,
        t3DecodeInference: generation.decodeInferenceTime,
        t3DecodeHost: generation.decodeHostTime,
        s3GenSetup: melGeneration.setupTime,
        s3GenNoise: melGeneration.noiseTime,
        s3GenInference: melGeneration.inferenceTime,
        vocoderSetup: waveformGeneration.setupTime,
        vocoderNoise: waveformGeneration.noiseTime,
        vocoderInference: waveformGeneration.inferenceTime,
        audioPostprocessing: audioPostprocessingTime
      )
    )
  }

  // MARK: - Internals

  private func loadResources() throws -> ChatterboxRecipeResources {
    switch recipeSource {
    case .bundle(let bundle):
      return try ChatterboxRecipeResources(bundle: bundle)
    case .directory(let url):
      return try ChatterboxRecipeResources(directory: url)
    }
  }

  private func specializationOptions(
    for preference: CoreAIComputeUnitPreference
  ) -> SpecializationOptions {
    let availableKinds = ComputeUnitKind.availableKinds
    let override = ProcessInfo.processInfo.environment[
      "CHATTERBOX_COMPUTE_UNIT"
    ]
    let preferredKind: ComputeUnitKind
    switch override {
    case "neuralEngine" where availableKinds.contains(.neuralEngine):
      preferredKind = .neuralEngine
    case "cpu" where availableKinds.contains(.cpu):
      preferredKind = .cpu
    default:
      switch preference {
      case .gpu where availableKinds.contains(.gpu):
        preferredKind = .gpu
      case .neuralEngine where availableKinds.contains(.neuralEngine):
        preferredKind = .neuralEngine
      case .cpu where availableKinds.contains(.cpu):
        preferredKind = .cpu
      case .automatic, .cpu, .gpu, .neuralEngine:
        preferredKind = availableKinds.contains(.gpu) ? .gpu : .cpu
      }
    }
    return SpecializationOptions(preferredComputeUnitKind: preferredKind)
  }

  private func loadModel(at url: URL) async throws -> AIModel {
    let options = specializationOptions(for: preferredComputeUnit)
    if let cached = try AIModelCache.default.model(
      for: url,
      options: options
    ) {
      return cached
    }
    return try await AIModel.specialize(
      contentsOf: url,
      options: options,
      cache: .default,
      cachePolicy: .persistent
    )
  }

  private func generateSpeechTokens(
    pipeline: PreparedPipeline,
    textTokens: [Int32],
    maximumGeneratedTokens: Int,
    random: ChatterboxRandomGenerator
  ) async throws -> SpeechTokenGeneration {
    let capacity = pipeline.capacity
    let setupStartedAt = ContinuousClock.now
    let embeddingPrefill = pipeline.embeddingPrefill
    let embeddingDecode = pipeline.embeddingDecode
    let transformerPrefill = pipeline.transformerPrefill
    let transformerDecode = pipeline.transformerDecode
    let setupTime = setupStartedAt.duration(to: .now).chatterboxSeconds

    let prefillStartedAt = ContinuousClock.now
    var embeddingOutputs = try await embeddingPrefill.run(
      inputs: [
        "textTokens": NDArray(
          scalars: textTokens,
          shape: [1, textTokens.count]
        )
      ]
    )
    guard
      let inputEmbeddings = embeddingOutputs
        .remove("inputEmbeddings")?.ndArray
    else {
      throw ChatterboxEngineError.missingOutput("inputEmbeddings")
    }

    var sequenceLength = inputEmbeddings.shape[1]
    let availableGeneratedTokens =
      capacity.maximumContextLength
      - sequenceLength
      - 1
    let generationBudget = min(
      maximumGeneratedTokens,
      availableGeneratedTokens
    )
    guard generationBudget > 0 else {
      throw ChatterboxEngineError.textTooLong(
        tokenCount: textTokens.count,
        maximumTokenCount: capacity.maximumTextTokens
      )
    }

    let cacheShape = [
      capacity.t3LayerCount,
      1,
      capacity.t3HeadCount,
      capacity.maximumContextLength,
      capacity.t3HeadDimension,
    ]
    var keyCache = ChatterboxNDArray.zerosFloat16(shape: cacheShape)
    var valueCache = ChatterboxNDArray.zerosFloat16(shape: cacheShape)
    let positionIDs = (0..<sequenceLength).map(Int32.init)

    var transformerOutputs = try await transformerPrefill.run(
      inputs: [
        "inputEmbeddings": inputEmbeddings,
        "positionIDs": NDArray(
          scalars: positionIDs,
          shape: [1, sequenceLength]
        ),
        "keyCache": keyCache,
        "valueCache": valueCache,
      ]
    )
    let prefillResult = try takeTransformerOutputs(
      from: &transformerOutputs
    )
    try ChatterboxNDArray.patchCache(
      &keyCache,
      with: prefillResult.keyUpdates,
      at: 0
    )
    try ChatterboxNDArray.patchCache(
      &valueCache,
      with: prefillResult.valueUpdates,
      at: 0
    )

    var generatedTokens = [Int]()
    var token = try ChatterboxSampler.sample(
      logits: ChatterboxNDArray.lastLogits(from: prefillResult.logits),
      generatedTokens: [capacity.t3StartSpeechToken],
      random: random
    )
    let prefillTime = prefillStartedAt.duration(to: .now).chatterboxSeconds
    if token == capacity.t3StopSpeechToken {
      return SpeechTokenGeneration(
        tokens: [],
        reachedStopToken: true,
        setupTime: setupTime,
        prefillTime: prefillTime,
        embeddingInferenceTime: 0,
        transformerInferenceTime: 0,
        decodeInferenceTime: 0,
        decodeHostTime: 0
      )
    }
    generatedTokens.append(token)

    var embeddingInferenceTime: TimeInterval = 0
    var transformerInferenceTime: TimeInterval = 0
    var decodeHostTime: TimeInterval = 0
    for _ in 1..<generationBudget {
      // Chunked synthesis is cancelled wholesale on barge-in; checking
      // here stops the T3 decode loop within one token.
      try Task.checkCancellation()

      let embeddingInferenceStartedAt = ContinuousClock.now
      var decodeEmbeddingOutputs = try await embeddingDecode.run(
        inputs: [
          "speechToken": NDArray(
            scalars: [Int32(token)],
            shape: [1, 1]
          )
        ]
      )
      guard
        let decodeEmbedding = decodeEmbeddingOutputs
          .remove("inputEmbeddings")?.ndArray
      else {
        throw ChatterboxEngineError.missingOutput("inputEmbeddings")
      }
      embeddingInferenceTime += embeddingInferenceStartedAt.duration(
        to: .now
      ).chatterboxSeconds

      sequenceLength += 1
      let transformerInferenceStartedAt = ContinuousClock.now
      var decodeOutputs = try await transformerDecode.run(
        inputs: [
          "inputEmbeddings": decodeEmbedding,
          "positionIDs": NDArray(
            scalars: [Int32(sequenceLength - 1)],
            shape: [1, 1]
          ),
          "keyCache": keyCache,
          "valueCache": valueCache,
        ]
      )
      let decodeResult = try takeTransformerOutputs(
        from: &decodeOutputs
      )
      transformerInferenceTime += transformerInferenceStartedAt.duration(
        to: .now
      ).chatterboxSeconds

      let decodeHostStartedAt = ContinuousClock.now
      let cacheOffset = sequenceLength - 1
      try ChatterboxNDArray.patchCache(
        &keyCache,
        with: decodeResult.keyUpdates,
        at: cacheOffset
      )
      try ChatterboxNDArray.patchCache(
        &valueCache,
        with: decodeResult.valueUpdates,
        at: cacheOffset
      )
      token = try ChatterboxSampler.sample(
        logits: ChatterboxNDArray.lastLogits(
          from: decodeResult.logits
        ),
        generatedTokens: generatedTokens,
        random: random
      )
      decodeHostTime += decodeHostStartedAt.duration(
        to: .now
      ).chatterboxSeconds
      if token == capacity.t3StopSpeechToken {
        return SpeechTokenGeneration(
          tokens: generatedTokens,
          reachedStopToken: true,
          setupTime: setupTime,
          prefillTime: prefillTime,
          embeddingInferenceTime: embeddingInferenceTime,
          transformerInferenceTime: transformerInferenceTime,
          decodeInferenceTime: embeddingInferenceTime
            + transformerInferenceTime,
          decodeHostTime: decodeHostTime
        )
      }
      generatedTokens.append(token)
    }

    return SpeechTokenGeneration(
      tokens: generatedTokens,
      reachedStopToken: false,
      setupTime: setupTime,
      prefillTime: prefillTime,
      embeddingInferenceTime: embeddingInferenceTime,
      transformerInferenceTime: transformerInferenceTime,
      decodeInferenceTime: embeddingInferenceTime
        + transformerInferenceTime,
      decodeHostTime: decodeHostTime
    )
  }

  private func generateMel(
    modelURL: URL,
    functionName: String,
    speechTokens: [Int],
    capacity: ChatterboxResolvedCapacity,
    random: ChatterboxRandomGenerator
  ) async throws -> MelGeneration {
    var paddedTokens = [Int32](
      repeating: Int32(capacity.silenceToken),
      count: capacity.speechTokenBufferCount
    )
    let validTokens = speechTokens
      .filter { $0 < capacity.t3StartSpeechToken }
      .prefix(
        capacity.speechTokenBufferCount
          - capacity.endSilenceTokenCount
      )
    for (index, token) in validTokens.enumerated() {
      paddedTokens[index] = Int32(token)
    }

    let noiseStartedAt = ContinuousClock.now
    let noiseCount = 80 * capacity.melNoiseFrameCount
    let noise = (0..<noiseCount).map { _ in
      Float16(random.nextNormal())
    }
    let noiseTime = noiseStartedAt.duration(to: .now).chatterboxSeconds
    let setupStartedAt = ContinuousClock.now
    let model = try await loadModel(at: modelURL)
    let function = try loadFunction(functionName, from: model)
    let setupTime = setupStartedAt.duration(to: .now).chatterboxSeconds
    let inferenceStartedAt = ContinuousClock.now
    var outputs = try await function.run(
      inputs: [
        "speechTokens": NDArray(
          scalars: paddedTokens,
          shape: [1, capacity.speechTokenBufferCount]
        ),
        "noise": NDArray(
          scalars: noise,
          shape: [1, 80, capacity.melNoiseFrameCount]
        ),
      ]
    )
    guard let mel = outputs.remove("mel")?.ndArray else {
      throw ChatterboxEngineError.missingOutput("mel")
    }
    return MelGeneration(
      mel: mel,
      setupTime: setupTime,
      noiseTime: noiseTime,
      inferenceTime: inferenceStartedAt.duration(to: .now).chatterboxSeconds
    )
  }

  private func generateWaveform(
    modelURL: URL,
    functionName: String,
    mel: NDArray,
    capacity: ChatterboxResolvedCapacity,
    random: ChatterboxRandomGenerator
  ) async throws -> WaveformGeneration {
    guard let melFrameCount = mel.shape.last,
      melFrameCount == capacity.generatedMelFrameCount
    else {
      throw ChatterboxEngineError.invalidOutputShape(
        "S3Gen returned \(mel.shape.last ?? 0) mel frames; the recipe requires \(capacity.generatedMelFrameCount)."
      )
    }

    let noiseStartedAt = ContinuousClock.now
    var phase = [Float16](
      repeating: 0,
      count: capacity.sourceChannelCount
    )
    for channel in 1..<capacity.sourceChannelCount {
      phase[channel] = Float16(
        (random.nextUnitDouble() * 2 - 1) * Double.pi
      )
    }

    let sampleCount = melFrameCount * capacity.samplesPerMelFrame
    let noiseCount = capacity.sourceChannelCount * sampleCount
    let noise = (0..<noiseCount).map { _ in
      Float16(random.nextNormal())
    }
    let noiseTime = noiseStartedAt.duration(to: .now).chatterboxSeconds
    let setupStartedAt = ContinuousClock.now
    let model = try await loadModel(at: modelURL)
    let function = try loadFunction(functionName, from: model)
    let setupTime = setupStartedAt.duration(to: .now).chatterboxSeconds
    let inferenceStartedAt = ContinuousClock.now
    var outputs = try await function.run(
      inputs: [
        "speech_feat": mel,
        "phase": NDArray(
          scalars: phase,
          shape: [1, capacity.sourceChannelCount, 1]
        ),
        "noise": NDArray(
          scalars: noise,
          shape: [
            1,
            capacity.sourceChannelCount,
            sampleCount,
          ]
        ),
      ]
    )
    guard let waveform = outputs.remove("waveform")?.ndArray else {
      throw ChatterboxEngineError.missingOutput("waveform")
    }
    return WaveformGeneration(
      waveform: try ChatterboxNDArray.floats(from: waveform),
      setupTime: setupTime,
      noiseTime: noiseTime,
      inferenceTime: inferenceStartedAt.duration(to: .now).chatterboxSeconds
    )
  }

  private func loadFunction(
    _ name: String,
    from model: AIModel
  ) throws -> InferenceFunction {
    guard let function = try model.loadFunction(named: name) else {
      throw ChatterboxEngineError.missingFunction(name)
    }
    return function
  }

  private func takeTransformerOutputs(
    from outputs: inout InferenceFunction.Outputs
  ) throws -> (
    logits: NDArray,
    keyUpdates: NDArray,
    valueUpdates: NDArray
  ) {
    guard let logits = outputs.remove("logits")?.ndArray else {
      throw ChatterboxEngineError.missingOutput("logits")
    }
    guard let keyUpdates = outputs.remove("keyUpdates")?.ndArray else {
      throw ChatterboxEngineError.missingOutput("keyUpdates")
    }
    guard let valueUpdates = outputs.remove("valueUpdates")?.ndArray else {
      throw ChatterboxEngineError.missingOutput("valueUpdates")
    }
    return (logits, keyUpdates, valueUpdates)
  }

  private func validateTokenizer(_ tokenizer: any Tokenizer) throws {
    let parityText =
      "This voice is running entirely on my Mac with Core AI. [chuckle] No cloud, no MLX, just Chatterbox."
    let expectedTokens = [
      1_212, 3_809, 318, 2_491, 5_000, 319, 616, 4_100, 351,
      7_231, 9_552, 13, 220, 50_274, 1_400, 6_279, 11, 645,
      10_373, 55, 11, 655, 609, 1_436, 3_524, 13,
    ]
    guard tokenizer.encode(text: parityText) == expectedTokens else {
      throw ChatterboxEngineError.tokenizerParityFailed
    }
  }

  private func allocatedSize(of url: URL) throws -> Int64 {
    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey,
      .fileSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true else {
        continue
      }
      total += Int64(
        values.totalFileAllocatedSize
          ?? values.fileAllocatedSize
          ?? values.fileSize
          ?? 0
      )
    }
    return total
  }
}
#endif
