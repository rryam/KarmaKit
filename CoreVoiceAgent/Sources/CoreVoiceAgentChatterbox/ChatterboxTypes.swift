import Foundation

/// A request to synthesize one chunk of text.
public struct ChatterboxGenerationRequest: Sendable {
  /// The text to speak.
  public let text: String

  /// The seed for the deterministic sampler and noise sources.
  public let seed: UInt64

  /// The upper bound on generated speech tokens for this call.
  public let maximumGeneratedTokens: Int

  /// Creates a generation request.
  public init(
    text: String,
    seed: UInt64 = 67,
    maximumGeneratedTokens: Int = 253
  ) {
    self.text = text
    self.seed = seed
    self.maximumGeneratedTokens = maximumGeneratedTokens
  }
}

/// Per-stage timing for one generation.
public struct ChatterboxGenerationMetrics: Sendable, Equatable {
  public let textPreparation: TimeInterval
  public let t3Setup: TimeInterval
  public let t3Prefill: TimeInterval
  public let t3EmbeddingInference: TimeInterval
  public let t3TransformerInference: TimeInterval
  public let t3DecodeInference: TimeInterval
  public let t3DecodeHost: TimeInterval
  public let s3GenSetup: TimeInterval
  public let s3GenNoise: TimeInterval
  public let s3GenInference: TimeInterval
  public let vocoderSetup: TimeInterval
  public let vocoderNoise: TimeInterval
  public let vocoderInference: TimeInterval
  public let audioPostprocessing: TimeInterval
}

/// The audio and diagnostics produced by one generation.
///
/// Unlike the Core-AI-Framework-Lab origin of this engine, the result
/// carries the raw waveform rather than a WAV file on disk, so callers
/// can stream it straight into playback. Use `ChatterboxWaveFile` to
/// write a WAV when needed.
public struct ChatterboxGenerationResult: Sendable, Equatable {
  /// Mono samples in the range `-1...1`.
  public let samples: [Float]

  /// The number of samples per second.
  public let sampleRate: Int

  /// The text after Chatterbox normalization, as spoken.
  public let normalizedText: String

  /// The number of speech tokens the T3 stage generated.
  public let generatedTokenCount: Int

  /// The wall-clock time of the whole generation.
  public let elapsedTime: TimeInterval

  /// Per-stage timing.
  public let metrics: ChatterboxGenerationMetrics

  /// The duration of the audio.
  public var audioDuration: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return TimeInterval(samples.count) / TimeInterval(sampleRate)
  }

  /// Generation time divided by audio duration; below 1 is faster than
  /// real time.
  public var realTimeFactor: Double {
    elapsedTime / audioDuration
  }

  /// Audio duration divided by generation time; above 1 is faster than
  /// real time.
  public var realTimeSpeed: Double {
    audioDuration / elapsedTime
  }
}

/// A summary of one loaded model asset.
public struct ChatterboxAssetInspection: Sendable, Equatable {
  public let stage: ChatterboxPipelineStage
  public let displayName: String
  public let detail: String
  public let sourceURL: URL
  public let functionNames: [String]
  public let sizeInBytes: Int64
}

/// A summary of the prepared pipeline.
public struct ChatterboxModelInspection: Sendable, Equatable {
  /// The recipe's display name.
  public let displayName: String

  /// The upstream model author, from asset metadata.
  public let author: String

  /// The upstream model license.
  public let license: String

  /// The Core AI device architecture the assets specialized for.
  public let deviceArchitectureName: String

  /// The loaded assets, one per pipeline stage.
  public let assets: [ChatterboxAssetInspection]

  /// The sample rate of generated audio.
  public let sampleRate: Int

  /// The total size of all loaded assets.
  public var totalSizeInBytes: Int64 {
    assets.reduce(0) { $0 + $1.sizeInBytes }
  }
}

/// Failures surfaced by the Chatterbox engine.
public enum ChatterboxEngineError: Error, LocalizedError, Equatable {
  case resourcesMissing
  case unsafeResourcePath(String)
  case invalidModelAsset(String)
  case modelNotPrepared
  case emptyPrompt
  case textTooLong(tokenCount: Int, maximumTokenCount: Int)
  case generationLimitReached
  case missingEntrypoints(asset: String, names: [String])
  case tokenizerParityFailed
  case missingFunction(String)
  case missingOutput(String)
  case invalidOutputShape(String)
  case invalidWaveFile(String)
  case unsupportedScalarType(String)

  public var errorDescription: String? {
    switch self {
    case .resourcesMissing:
      "The Chatterbox model resources are missing from the recipe directory."
    case .unsafeResourcePath(let path):
      "The Chatterbox resource path is unsafe or escapes its root: \(path)."
    case .invalidModelAsset(let name):
      "\(name) is not a valid Core AI model asset."
    case .modelNotPrepared:
      "Call prepare() before synthesizing."
    case .emptyPrompt:
      "Provide some text for Chatterbox to speak."
    case .textTooLong(let tokenCount, let maximumTokenCount):
      "The text is \(tokenCount) tokens. This recipe supports at most "
        + "\(maximumTokenCount) text tokens per call; chunk the text first."
    case .generationLimitReached:
      "This utterance reached the recipe's speech-token capacity. "
        + "Shorten the text and try again."
    case .missingEntrypoints(let asset, let names):
      "\(asset) is missing required entry points: \(names.joined(separator: ", "))."
    case .tokenizerParityFailed:
      "The Swift tokenizer does not match Chatterbox's source tokenizer."
    case .missingFunction(let name):
      "The Core AI function \(name) could not be loaded."
    case .missingOutput(let name):
      "The Core AI function did not return its \(name) output."
    case .invalidOutputShape(let message):
      message
    case .invalidWaveFile(let message):
      message
    case .unsupportedScalarType(let scalarType):
      "Chatterbox received an unsupported Core AI scalar type: \(scalarType)."
    }
  }
}
