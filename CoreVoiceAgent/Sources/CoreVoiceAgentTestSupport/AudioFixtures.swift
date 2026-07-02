import CoreVoiceAgentCore
import Foundation

/// Deterministic audio fixtures for exercising the voice pipeline without
/// audio hardware.
public enum AudioFixtures {
  /// The sample rate used by all fixtures, matching the on-device
  /// recognizers' 16 kHz input.
  public static let sampleRate = 16_000

  /// The duration of one fixture frame (10 ms, a typical capture buffer).
  public static let frameDuration: TimeInterval = 0.01

  /// Returns frames of constant-amplitude speech-like audio.
  ///
  /// - Parameters:
  ///   - duration: The total duration to produce.
  ///   - amplitude: The per-sample amplitude; the default is comfortably
  ///     above the default activation threshold.
  public static func speechFrames(
    duration: TimeInterval,
    amplitude: Float = 0.5
  ) -> [AudioFrame] {
    frames(duration: duration, amplitude: amplitude)
  }

  /// Returns frames of silence.
  ///
  /// - Parameter duration: The total duration to produce.
  public static func silenceFrames(duration: TimeInterval) -> [AudioFrame] {
    frames(duration: duration, amplitude: 0)
  }

  private static func frames(
    duration: TimeInterval,
    amplitude: Float
  ) -> [AudioFrame] {
    let samplesPerFrame = Int(TimeInterval(sampleRate) * frameDuration)
    let frameCount = Int((duration / frameDuration).rounded())
    let samples = [Float](repeating: amplitude, count: samplesPerFrame)
    return (0..<max(frameCount, 0)).map { _ in
      AudioFrame(samples: samples, sampleRate: sampleRate)
    }
  }
}
