import CoreAIKit
import CoreVoiceAgentCore
import Foundation

/// Errors specific to the Parakeet transcription path.
public enum ParakeetTranscriberError: Error, LocalizedError {
  /// The utterance sample rate does not match Parakeet's 16 kHz input.
  case unsupportedSampleRate(Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSampleRate(let sampleRate):
      "Parakeet requires 16 kHz mono audio; got \(sampleRate) Hz. "
        + "Configure the audio input for 16 kHz capture."
    }
  }
}

/// A transcriber backed by NVIDIA Parakeet-TDT-0.6B running natively
/// through Core AI.
///
/// Parakeet is a token-and-duration transducer: a FastConformer encoder,
/// an LSTM predictor, and a joint network exported as three `.aimodel`
/// graphs, driven by `KitParakeetModel` from the community `coreai-kit`
/// package. It transcribes 25 European languages and decodes a finished
/// clip tens of times faster than real time on device, which is why the
/// session endpoints first and transcribes second.
///
/// ```swift
/// // Downloads the bundle from the Hub on first use.
/// let model = try await KitParakeetModel(model: .parakeetTDT)
/// let transcriber = ParakeetTranscriber(model: model)
/// ```
///
/// The encoder is baked at a ~29-second bucket; keep the endpointer's
/// `maximumUtteranceDuration` at or below the default 28 seconds so every
/// utterance fits one pass.
///
/// The Parakeet weights are published under CC-BY-4.0
/// (`mlboydaisuke/Parakeet-TDT-0.6B-CoreAI`); ship the attribution with
/// your app.
public struct ParakeetTranscriber: Transcriber {
  /// The sample rate Parakeet requires.
  public static let requiredSampleRate = KitParakeetModel.sampleRate

  private let model: KitParakeetModel

  /// Creates a transcriber over a loaded Parakeet model.
  ///
  /// - Parameter model: The loaded Parakeet bundle. The model runs one
  ///   transcription at a time; the session already serializes turns.
  public init(model: KitParakeetModel) {
    self.model = model
  }

  public func transcribe(
    _ utterance: CapturedUtterance,
    onPartialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String {
    guard utterance.sampleRate == Self.requiredSampleRate else {
      throw ParakeetTranscriberError.unsupportedSampleRate(utterance.sampleRate)
    }
    let result = try await model.transcribe(
      samples: utterance.samples,
      sampleRate: utterance.sampleRate,
      onPartial: onPartialTranscript
    )
    return result.text
  }
}
