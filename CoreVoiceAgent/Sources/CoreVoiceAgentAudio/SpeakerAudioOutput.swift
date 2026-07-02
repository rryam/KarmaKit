#if canImport(AVFoundation)
import AVFoundation
import CoreVoiceAgentCore
import Foundation

/// A speaker output that plays synthesized speech with `AVAudioEngine`.
///
/// Chunks are scheduled onto a single player node and `play(_:)` returns
/// when the chunk has been played back, which is the signal the session's
/// playback stage uses to keep chunk order. `stop()` halts the player
/// immediately, discarding scheduled audio — the barge-in path.
public actor SpeakerAudioOutput: AudioOutput {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var connectedSampleRate: Double?

  /// Creates a speaker output.
  public init() {}

  public func play(_ speech: SynthesizedSpeech) async throws {
    guard !speech.samples.isEmpty, speech.sampleRate > 0 else { return }
    let player = try preparePlayer(sampleRate: Double(speech.sampleRate))
    let buffer = try makeBuffer(for: speech)

    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      await withCheckedContinuation { continuation in
        player.scheduleBuffer(
          buffer,
          at: nil,
          options: [],
          completionCallbackType: .dataPlayedBack
        ) { _ in
          continuation.resume()
        }
        player.play()
      }
      try Task.checkCancellation()
    } onCancel: {
      Task { await self.stop() }
    }
  }

  public func stop() async {
    // Stopping the player flushes scheduled buffers and fires their
    // completion handlers, which resumes any in-flight play(_:).
    player?.stop()
  }

  /// Tears down the audio engine. The next `play(_:)` rebuilds it.
  public func shutDown() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    connectedSampleRate = nil
  }

  private func preparePlayer(sampleRate: Double) throws -> AVAudioPlayerNode {
    if let player, let engine, engine.isRunning, connectedSampleRate == sampleRate {
      return player
    }

    let engine = self.engine ?? AVAudioEngine()
    let player = self.player ?? AVAudioPlayerNode()
    if player.engine == nil {
      engine.attach(player)
    }

    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw VoiceAgentError(
        stage: .playback,
        message: "Could not build a playback format at \(sampleRate) Hz."
      )
    }
    // The main mixer resamples from the chunk's rate to the hardware
    // rate.
    engine.connect(player, to: engine.mainMixerNode, format: format)
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }

    self.engine = engine
    self.player = player
    connectedSampleRate = sampleRate
    return player
  }

  private func makeBuffer(for speech: SynthesizedSpeech) throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(speech.sampleRate),
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(speech.samples.count)
      ),
      let channel = buffer.floatChannelData
    else {
      throw VoiceAgentError(
        stage: .playback,
        message: "Could not allocate a playback buffer."
      )
    }
    speech.samples.withUnsafeBufferPointer { samples in
      channel[0].update(from: samples.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(speech.samples.count)
    return buffer
  }
}
#endif
