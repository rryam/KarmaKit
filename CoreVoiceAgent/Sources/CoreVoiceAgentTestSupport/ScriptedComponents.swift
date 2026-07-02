import CoreVoiceAgentCore
import Foundation

/// An audio input that replays scripted frames on demand.
///
/// Tests drive the session deterministically by feeding frames and
/// awaiting the resulting events; the input never produces audio on its
/// own.
public actor ScriptedAudioInput: AudioInput {
  private var continuation: AsyncStream<AudioFrame>.Continuation?

  public init() {}

  public func start() async throws -> AsyncStream<AudioFrame> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: AudioFrame.self,
      bufferingPolicy: .unbounded
    )
    self.continuation = continuation
    return stream
  }

  public func stop() async {
    continuation?.finish()
    continuation = nil
  }

  /// Feeds one frame into the capture stream.
  public func feed(_ frame: AudioFrame) {
    continuation?.yield(frame)
  }

  /// Feeds a sequence of frames into the capture stream, in order.
  public func feed(_ frames: [AudioFrame]) {
    for frame in frames {
      continuation?.yield(frame)
    }
  }
}

/// An audio output that records everything it is asked to play.
public actor CapturingAudioOutput: AudioOutput {
  /// A record of one playback request.
  public struct Playback: Sendable, Equatable {
    public let text: String
    public let duration: TimeInterval

    public init(text: String, duration: TimeInterval) {
      self.text = text
      self.duration = duration
    }
  }

  /// Every chunk played to completion, in order.
  public private(set) var playbacks: [Playback] = []

  /// The number of times `stop()` was called.
  public private(set) var stopCount = 0

  /// An artificial per-chunk playback delay, so tests can hold the
  /// session in its speaking state.
  private let playbackDelay: Duration

  /// Creates a capturing output.
  ///
  /// - Parameter playbackDelay: An artificial delay applied to every
  ///   chunk before it completes.
  public init(playbackDelay: Duration = .zero) {
    self.playbackDelay = playbackDelay
  }

  public func play(_ speech: SynthesizedSpeech) async throws {
    if playbackDelay > .zero {
      try await Task.sleep(for: playbackDelay)
    }
    playbacks.append(Playback(text: speech.text, duration: speech.duration))
  }

  public func stop() async {
    stopCount += 1
  }
}

/// A transcriber that returns scripted transcripts in order.
public actor ScriptedTranscriber: Transcriber {
  /// Every utterance received, in order.
  public private(set) var receivedUtterances: [CapturedUtterance] = []

  private var transcripts: [String]
  private let partials: [String]
  private let delay: Duration

  /// Creates a scripted transcriber.
  ///
  /// - Parameters:
  ///   - transcripts: The transcripts to return, one per call, in order.
  ///     The last transcript repeats once the script is exhausted.
  ///   - partials: Partial transcripts delivered before each result.
  ///   - delay: An artificial decoding delay before each result.
  public init(
    transcripts: [String],
    partials: [String] = [],
    delay: Duration = .zero
  ) {
    self.transcripts = transcripts
    self.partials = partials
    self.delay = delay
  }

  public func transcribe(
    _ utterance: CapturedUtterance,
    onPartialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String {
    receivedUtterances.append(utterance)
    if delay > .zero {
      try await Task.sleep(for: delay)
    }
    for partial in partials {
      onPartialTranscript?(partial)
    }
    guard !transcripts.isEmpty else { return "" }
    return transcripts.count == 1 ? transcripts[0] : transcripts.removeFirst()
  }
}

/// A responder that streams a scripted reply in fixed-size pieces.
public actor ScriptedResponder: ConversationResponder {
  /// Every user text received, in order.
  public private(set) var receivedUserTexts: [String] = []

  private var replies: [String]
  private let pieceLength: Int
  private let delayPerPiece: Duration
  private let error: (any Error)?

  /// Creates a scripted responder.
  ///
  /// - Parameters:
  ///   - replies: The replies to produce, one per call, in order. The
  ///     last reply repeats once the script is exhausted.
  ///   - pieceLength: The number of characters revealed per cumulative
  ///     partial snapshot.
  ///   - delayPerPiece: An artificial generation delay between snapshots.
  ///   - error: An error thrown instead of producing a reply.
  public init(
    replies: [String],
    pieceLength: Int = 12,
    delayPerPiece: Duration = .zero,
    error: (any Error)? = nil
  ) {
    self.replies = replies
    self.pieceLength = pieceLength
    self.delayPerPiece = delayPerPiece
    self.error = error
  }

  public func respond(
    to userText: String,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    receivedUserTexts.append(userText)
    if let error {
      throw error
    }
    guard !replies.isEmpty else { return "" }
    let reply = replies.count == 1 ? replies[0] : replies.removeFirst()

    var end = reply.startIndex
    while end < reply.endIndex {
      try Task.checkCancellation()
      end =
        reply.index(end, offsetBy: pieceLength, limitedBy: reply.endIndex)
        ?? reply.endIndex
      if delayPerPiece > .zero {
        try await Task.sleep(for: delayPerPiece)
      }
      await onPartialResponse(String(reply[..<end]))
    }
    return reply
  }
}

/// A synthesizer that produces silent audio proportional to text length.
public actor ScriptedSpeechSynthesizer: SpeechSynthesizer {
  /// The sample rate of produced audio, matching Chatterbox's 24 kHz
  /// output.
  public static let sampleRate = 24_000

  /// Every text synthesized, in order.
  public private(set) var synthesizedTexts: [String] = []

  private let delay: Duration
  private let error: (any Error)?

  /// Creates a scripted synthesizer.
  ///
  /// - Parameters:
  ///   - delay: An artificial synthesis delay per chunk.
  ///   - error: An error thrown instead of synthesizing.
  public init(delay: Duration = .zero, error: (any Error)? = nil) {
    self.delay = delay
    self.error = error
  }

  public func synthesize(_ text: String) async throws -> SynthesizedSpeech {
    if let error {
      throw error
    }
    if delay > .zero {
      try await Task.sleep(for: delay)
    }
    synthesizedTexts.append(text)
    // 50 ms of audio per character keeps durations proportional and
    // deterministic.
    let sampleCount = max(text.count, 1) * Self.sampleRate / 20
    return SynthesizedSpeech(
      samples: [Float](repeating: 0, count: sampleCount),
      sampleRate: Self.sampleRate,
      text: text
    )
  }
}
