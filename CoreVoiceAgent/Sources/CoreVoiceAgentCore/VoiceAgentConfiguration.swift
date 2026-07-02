import Foundation

/// Tuning for utterance endpointing (voice-activity segmentation).
public struct EndpointerConfiguration: Sendable, Equatable {
  /// The RMS level at or above which a frame counts as speech.
  public var activationThreshold: Float

  /// The consecutive speech required before an utterance starts.
  ///
  /// Filters keyboard taps and other transients.
  public var activationDuration: TimeInterval

  /// The trailing silence that ends an utterance.
  public var endSilenceDuration: TimeInterval

  /// The audio retained from before activation so the first phoneme is
  /// not clipped.
  public var preRollDuration: TimeInterval

  /// The duration below which captured speech is discarded as a noise
  /// blip. Measured on captured speech, excluding pre-roll.
  public var minimumUtteranceDuration: TimeInterval

  /// The hard cap per utterance.
  ///
  /// The default stays inside Parakeet-TDT's ~29-second encoder bucket.
  public var maximumUtteranceDuration: TimeInterval

  /// Creates an endpointer configuration.
  public init(
    activationThreshold: Float = 0.015,
    activationDuration: TimeInterval = 0.1,
    endSilenceDuration: TimeInterval = 0.8,
    preRollDuration: TimeInterval = 0.4,
    minimumUtteranceDuration: TimeInterval = 0.25,
    maximumUtteranceDuration: TimeInterval = 28.0
  ) {
    self.activationThreshold = activationThreshold
    self.activationDuration = activationDuration
    self.endSilenceDuration = endSilenceDuration
    self.preRollDuration = preRollDuration
    self.minimumUtteranceDuration = minimumUtteranceDuration
    self.maximumUtteranceDuration = maximumUtteranceDuration
  }
}

/// Tuning for incremental sentence chunking of streamed assistant text.
public struct SentenceChunkerConfiguration: Sendable, Equatable {
  /// The length at which a chunk is force-flushed at a word boundary, so
  /// a run-on reply cannot exceed the synthesizer's text capacity.
  ///
  /// The default stays comfortably inside Chatterbox Turbo's per-call
  /// text-token budget.
  public var maximumChunkCharacters: Int

  /// The length below which a sentence is merged with the following
  /// sentence instead of being synthesized alone.
  ///
  /// The first chunk of a reply always flushes immediately for
  /// time-to-first-audio.
  public var minimumChunkCharacters: Int

  /// Creates a sentence chunker configuration.
  public init(
    maximumChunkCharacters: Int = 220,
    minimumChunkCharacters: Int = 25
  ) {
    self.maximumChunkCharacters = maximumChunkCharacters
    self.minimumChunkCharacters = minimumChunkCharacters
  }
}

/// Top-level tuning for a voice agent session.
public struct VoiceAgentConfiguration: Sendable, Equatable {
  /// Endpointing (voice-activity segmentation) tuning.
  public var endpointer: EndpointerConfiguration

  /// Sentence chunking tuning for streamed replies.
  public var chunking: SentenceChunkerConfiguration

  /// Whether sustained user speech while the assistant is thinking or
  /// speaking cancels the assistant turn and starts a new user utterance.
  ///
  /// Requires an echo-cancelled input path such as
  /// `MicrophoneAudioInput`'s voice-processed capture.
  public var allowsBargeIn: Bool

  /// Creates a session configuration.
  public init(
    endpointer: EndpointerConfiguration = EndpointerConfiguration(),
    chunking: SentenceChunkerConfiguration = SentenceChunkerConfiguration(),
    allowsBargeIn: Bool = true
  ) {
    self.endpointer = endpointer
    self.chunking = chunking
    self.allowsBargeIn = allowsBargeIn
  }
}
