#if canImport(CoreAI)
import CoreVoiceAgentCore
import Foundation

/// A speech synthesizer backed by the Chatterbox Turbo pipeline running
/// natively through Core AI.
///
/// The voice loop hands this synthesizer one sentence-sized chunk at a
/// time; the engine actor serializes generations, and the session
/// pipelines the next chunk's synthesis against the current chunk's
/// playback.
///
/// ```swift
/// let engine = ChatterboxEngine(recipeDirectory: modelsDirectory)
/// try await engine.prepare()
/// let synthesizer = ChatterboxSpeechSynthesizer(engine: engine)
/// ```
///
/// Keep the session's `maximumChunkCharacters` at its default so every
/// chunk fits the recipe's per-call text-token budget.
public struct ChatterboxSpeechSynthesizer: SpeechSynthesizer {
  /// The wrapped engine. Call `prepare()` on it before the first turn.
  public let engine: ChatterboxEngine

  /// The seed for the deterministic sampler, fixed per synthesizer so a
  /// reply keeps one consistent delivery across chunks.
  public let seed: UInt64

  /// Creates a synthesizer over a prepared engine.
  ///
  /// - Parameters:
  ///   - engine: The engine that owns the pipeline assets.
  ///   - seed: The sampler seed applied to every chunk.
  public init(engine: ChatterboxEngine, seed: UInt64 = 67) {
    self.engine = engine
    self.seed = seed
  }

  public func synthesize(_ text: String) async throws -> SynthesizedSpeech {
    let result = try await engine.synthesize(
      ChatterboxGenerationRequest(text: text, seed: seed)
    )
    return SynthesizedSpeech(
      samples: result.samples,
      sampleRate: result.sampleRate,
      text: text
    )
  }
}
#endif
