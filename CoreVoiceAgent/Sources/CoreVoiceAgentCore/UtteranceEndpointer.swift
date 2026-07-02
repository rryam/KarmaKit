import Foundation

/// Segments a continuous frame stream into discrete utterances using
/// energy-based voice-activity detection with hysteresis.
///
/// The endpointer is a deterministic value machine: time advances only with
/// the audio it consumes (frame duration = samples / sample rate), never
/// with the wall clock, so identical input always produces identical
/// segmentation. The session feeds it every captured frame and reacts to
/// the returned events.
public struct UtteranceEndpointer: Sendable {
  /// What happened as a result of consuming one frame.
  public enum Event: Sendable, Equatable {
    /// Sustained speech crossed the activation threshold; an utterance is
    /// now being captured. Used by the session for barge-in.
    case speechStarted
    /// An utterance was closed and is ready for transcription.
    case utteranceCaptured(CapturedUtterance)
    /// Captured speech was too short and was dropped as a noise blip.
    case utteranceDiscarded
  }

  private enum State: Sendable {
    case idle
    case activating
    case capturing
  }

  private let configuration: EndpointerConfiguration

  private var state: State = .idle
  /// Rolling audio kept while idle so the start of speech is not clipped.
  private var preRoll: [AudioFrame] = []
  private var preRollDuration: TimeInterval = 0
  /// Consecutive speech frames observed while activating.
  private var pendingSpeech: [AudioFrame] = []
  private var pendingSpeechDuration: TimeInterval = 0
  /// Everything captured for the current utterance (including pre-roll).
  private var captured: [AudioFrame] = []
  /// Speech-plus-gap audio captured after activation (excludes pre-roll).
  private var capturedSpeechDuration: TimeInterval = 0
  private var trailingSilenceDuration: TimeInterval = 0

  public init(configuration: EndpointerConfiguration) {
    self.configuration = configuration
  }

  /// Consume one frame and return the events it triggered, in order.
  public mutating func consume(_ frame: AudioFrame) -> [Event] {
    guard !frame.samples.isEmpty, frame.sampleRate > 0 else { return [] }
    let isSpeech = frame.rmsLevel >= configuration.activationThreshold

    switch state {
    case .idle:
      if isSpeech {
        pendingSpeech.append(frame)
        pendingSpeechDuration += frame.duration
        state = .activating
        return checkActivation()
      }
      appendPreRoll(frame)
      return []

    case .activating:
      if isSpeech {
        pendingSpeech.append(frame)
        pendingSpeechDuration += frame.duration
        return checkActivation()
      }
      // The burst ended before it qualified as speech; fold it back into
      // the pre-roll so nothing is lost if speech starts right after.
      for pending in pendingSpeech {
        appendPreRoll(pending)
      }
      appendPreRoll(frame)
      pendingSpeech.removeAll()
      pendingSpeechDuration = 0
      state = .idle
      return []

    case .capturing:
      captured.append(frame)
      capturedSpeechDuration += frame.duration
      if isSpeech {
        trailingSilenceDuration = 0
      } else {
        trailingSilenceDuration += frame.duration
        if trailingSilenceDuration >= configuration.endSilenceDuration {
          return [closeUtterance(reason: .endOfSpeech)]
        }
      }
      if capturedSpeechDuration >= configuration.maximumUtteranceDuration {
        return [closeUtterance(reason: .maximumDurationReached)]
      }
      return []
    }
  }

  /// True while an utterance is actively being captured.
  public var isCapturing: Bool {
    if case .capturing = state { return true }
    return false
  }

  /// Drop all buffered audio and return to idle. Used when the session
  /// stops or wants a clean slate after an error.
  public mutating func reset() {
    state = .idle
    preRoll.removeAll()
    preRollDuration = 0
    pendingSpeech.removeAll()
    pendingSpeechDuration = 0
    captured.removeAll()
    capturedSpeechDuration = 0
    trailingSilenceDuration = 0
  }

  private mutating func checkActivation() -> [Event] {
    guard pendingSpeechDuration >= configuration.activationDuration else {
      return []
    }
    captured = preRoll + pendingSpeech
    capturedSpeechDuration = pendingSpeechDuration
    trailingSilenceDuration = 0
    preRoll.removeAll()
    preRollDuration = 0
    pendingSpeech.removeAll()
    pendingSpeechDuration = 0
    state = .capturing
    return [.speechStarted]
  }

  private mutating func closeUtterance(
    reason: CapturedUtterance.CompletionReason
  ) -> Event {
    let frames = captured
    let sampleRate = frames.first?.sampleRate ?? 0
    let speechDuration = capturedSpeechDuration - trailingSilenceDuration

    captured.removeAll()
    capturedSpeechDuration = 0
    trailingSilenceDuration = 0
    state = .idle

    guard speechDuration >= configuration.minimumUtteranceDuration else {
      return .utteranceDiscarded
    }

    var samples = [Float]()
    samples.reserveCapacity(frames.reduce(0) { $0 + $1.samples.count })
    for frame in frames {
      samples.append(contentsOf: frame.samples)
    }
    return .utteranceCaptured(
      CapturedUtterance(
        samples: samples,
        sampleRate: sampleRate,
        completionReason: reason
      )
    )
  }

  private mutating func appendPreRoll(_ frame: AudioFrame) {
    preRoll.append(frame)
    preRollDuration += frame.duration
    while preRollDuration > configuration.preRollDuration, preRoll.count > 1 {
      let removed = preRoll.removeFirst()
      preRollDuration -= removed.duration
    }
  }
}
