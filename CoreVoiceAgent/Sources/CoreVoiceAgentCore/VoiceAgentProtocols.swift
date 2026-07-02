import Foundation

/// A source of captured audio frames, such as a microphone.
///
/// Conforming types produce a stream of mono PCM frames when started. The
/// built-in `MicrophoneAudioInput` (in the `CoreVoiceAgentAudio` product)
/// captures voice-processed, echo-cancelled audio with `AVAudioEngine`;
/// test suites use fixture-backed inputs instead.
public protocol AudioInput: Sendable {
  /// Starts capture and returns the stream of frames.
  ///
  /// The stream finishes when the input stops or fails. An input may be
  /// started again after `stop()`.
  func start() async throws -> AsyncStream<AudioFrame>

  /// Stops capture and finishes the stream returned by `start()`.
  func stop() async
}

/// A destination that plays synthesized speech, such as the built-in
/// speaker.
public protocol AudioOutput: Sendable {
  /// Plays one chunk of synthesized speech to completion.
  ///
  /// Returns when the chunk has finished playing. Cancellation stops
  /// playback promptly.
  func play(_ speech: SynthesizedSpeech) async throws

  /// Immediately stops anything that is playing and discards queued audio.
  func stop() async
}

/// A speech-to-text engine that transcribes one completed utterance.
///
/// The batch shape is intentional: the on-device recognizers this package
/// targets — Parakeet-TDT through Core AI, Whisper-family models, and the
/// Speech framework's file path — all transcribe a finished clip many times
/// faster than real time, so the session endpoints first and transcribes
/// second.
public protocol Transcriber: Sendable {
  /// Transcribes a completed utterance.
  ///
  /// - Parameters:
  ///   - utterance: The segmented utterance to transcribe.
  ///   - onPartialTranscript: A closure that receives the running
  ///     transcript while the engine decodes, when the engine supports
  ///     partial results.
  /// - Returns: The final transcript.
  func transcribe(
    _ utterance: CapturedUtterance,
    onPartialTranscript: (@Sendable (String) -> Void)?
  ) async throws -> String
}

/// The conversational brain of a voice agent: user text in, streamed
/// assistant text out.
///
/// `CoreAgentResponder` (in the `CoreVoiceAgent` product) adapts
/// `CoreAgentSession` — and therefore any Foundation Models
/// `LanguageModel`, including the on-device system model — to this
/// protocol. Swap in a different conforming type to change the brain
/// without touching the voice loop.
public protocol ConversationResponder: Sendable {
  /// Produces the assistant's reply to the given user text.
  ///
  /// - Parameters:
  ///   - userText: The transcribed user utterance.
  ///   - onPartialResponse: A closure that receives cumulative snapshots
  ///     of the reply as it streams, matching Foundation Models streaming
  ///     semantics.
  /// - Returns: The complete final reply.
  func respond(
    to userText: String,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> String
}

/// A text-to-speech engine that synthesizes one sentence-sized chunk.
public protocol SpeechSynthesizer: Sendable {
  /// Synthesizes speech audio for the given text.
  ///
  /// - Parameter text: The text to speak.
  /// - Returns: The finished audio.
  func synthesize(_ text: String) async throws -> SynthesizedSpeech
}
