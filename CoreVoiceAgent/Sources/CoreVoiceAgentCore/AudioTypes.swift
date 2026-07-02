import Foundation

/// A contiguous block of mono PCM audio captured from an audio input.
public struct AudioFrame: Sendable, Equatable {
  /// Mono samples in the range `-1...1`.
  public let samples: [Float]

  /// The number of samples per second.
  public let sampleRate: Int

  /// Creates a frame from mono samples.
  ///
  /// - Parameters:
  ///   - samples: Mono samples in the range `-1...1`.
  ///   - sampleRate: The number of samples per second.
  public init(samples: [Float], sampleRate: Int) {
    self.samples = samples
    self.sampleRate = sampleRate
  }

  /// The duration of this frame.
  public var duration: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return TimeInterval(samples.count) / TimeInterval(sampleRate)
  }

  /// The root-mean-square level of this frame.
  public var rmsLevel: Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples {
      sum += sample * sample
    }
    return (sum / Float(samples.count)).squareRoot()
  }
}

/// One complete spoken utterance, segmented from the capture stream.
public struct CapturedUtterance: Sendable, Equatable {
  /// The reason the utterance was closed.
  public enum CompletionReason: Sendable, Equatable {
    /// The trailing-silence window elapsed.
    case endOfSpeech

    /// The utterance reached the configured maximum duration.
    case maximumDurationReached
  }

  /// Mono samples covering the utterance, including the pre-roll audio
  /// captured before speech was detected.
  public let samples: [Float]

  /// The number of samples per second.
  public let sampleRate: Int

  /// The reason the utterance was closed.
  public let completionReason: CompletionReason

  /// Creates an utterance from segmented audio.
  public init(
    samples: [Float],
    sampleRate: Int,
    completionReason: CompletionReason
  ) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.completionReason = completionReason
  }

  /// The duration of the utterance.
  public var duration: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return TimeInterval(samples.count) / TimeInterval(sampleRate)
  }
}

/// Finished speech audio produced by a speech synthesizer.
public struct SynthesizedSpeech: Sendable, Equatable {
  /// Mono samples in the range `-1...1`.
  public let samples: [Float]

  /// The number of samples per second.
  public let sampleRate: Int

  /// The exact text this audio speaks.
  public let text: String

  /// Creates synthesized speech from mono samples.
  public init(samples: [Float], sampleRate: Int, text: String) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.text = text
  }

  /// The duration of the audio.
  public var duration: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return TimeInterval(samples.count) / TimeInterval(sampleRate)
  }
}
