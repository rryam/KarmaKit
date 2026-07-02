#if canImport(AVFoundation)
import AVFoundation
import CoreVoiceAgentCore
import Foundation

/// A microphone input that captures voice-processed, echo-cancelled
/// 16 kHz mono audio with `AVAudioEngine`.
///
/// Voice processing is what makes barge-in reliable: the system's voice
/// I/O unit removes the device's own playback from the microphone
/// signal, so the endpointer hears the user rather than the assistant.
///
/// On iOS, configure and activate an `AVAudioSession` with the
/// `.playAndRecord` category and `.voiceChat` mode before starting the
/// session, and request microphone permission; the input does not manage
/// session state or permission prompts for the app.
public actor MicrophoneAudioInput: AudioInput {
  /// The sample rate frames are delivered at, matching the on-device
  /// recognizers' 16 kHz input.
  public static let outputSampleRate = 16_000.0

  /// The duration of each delivered frame.
  public static let frameDuration: TimeInterval = 0.02

  private var engine: AVAudioEngine?
  private var continuation: AsyncStream<AudioFrame>.Continuation?

  /// Creates a microphone input.
  public init() {}

  public func start() async throws -> AsyncStream<AudioFrame> {
    await stopCapture()

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    // The voice-processing I/O unit provides echo cancellation and
    // automatic gain control. Enable it before wiring the graph.
    try inputNode.setVoiceProcessingEnabled(true)

    let (stream, continuation) = AsyncStream.makeStream(
      of: AudioFrame.self,
      bufferingPolicy: .unbounded
    )

    let captureFormat = inputNode.outputFormat(forBus: 0)
    guard
      let deliveryFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.outputSampleRate,
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: captureFormat, to: deliveryFormat)
    else {
      throw VoiceAgentError(
        stage: .audioInput,
        message: "Could not build a 16 kHz mono conversion for the capture format."
      )
    }

    let bufferFrameCount = AVAudioFrameCount(
      captureFormat.sampleRate * Self.frameDuration
    )
    inputNode.installTap(
      onBus: 0,
      bufferSize: bufferFrameCount,
      format: captureFormat
    ) { buffer, _ in
      let ratio = deliveryFormat.sampleRate / captureFormat.sampleRate
      let capacity = AVAudioFrameCount(
        (Double(buffer.frameLength) * ratio).rounded(.up) + 32
      )
      guard
        let converted = AVAudioPCMBuffer(
          pcmFormat: deliveryFormat,
          frameCapacity: capacity
        )
      else { return }

      var isBufferConsumed = false
      var conversionError: NSError?
      converter.convert(to: converted, error: &conversionError) { _, inputStatus in
        if isBufferConsumed {
          inputStatus.pointee = .noDataNow
          return nil
        }
        isBufferConsumed = true
        inputStatus.pointee = .haveData
        return buffer
      }
      guard conversionError == nil, converted.frameLength > 0,
        let channel = converted.floatChannelData
      else { return }

      let samples = Array(
        UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))
      )
      continuation.yield(
        AudioFrame(samples: samples, sampleRate: Int(Self.outputSampleRate))
      )
    }

    engine.prepare()
    try engine.start()
    self.engine = engine
    self.continuation = continuation
    return stream
  }

  public func stop() async {
    await stopCapture()
  }

  private func stopCapture() async {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    continuation?.finish()
    continuation = nil
  }
}
#endif
