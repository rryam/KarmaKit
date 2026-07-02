import CoreVoiceAgentCore
import CoreVoiceAgentTestSupport
import Foundation
import Testing

@Suite("UtteranceEndpointer")
struct UtteranceEndpointerTests {
  private let configuration = EndpointerConfiguration(
    activationThreshold: 0.1,
    activationDuration: 0.05,
    endSilenceDuration: 0.3,
    preRollDuration: 0.2,
    minimumUtteranceDuration: 0.2,
    maximumUtteranceDuration: 5.0
  )

  private func consume(
    _ frames: [AudioFrame],
    into endpointer: inout UtteranceEndpointer
  ) -> [UtteranceEndpointer.Event] {
    frames.flatMap { endpointer.consume($0) }
  }

  @Test("Silence produces no events")
  func silenceIsIdle() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    let events = consume(
      AudioFixtures.silenceFrames(duration: 2.0), into: &endpointer)
    #expect(events.isEmpty)
  }

  @Test("Speech followed by silence yields one utterance")
  func speechThenSilenceCapturesUtterance() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    var events = consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)
    events += consume(
      AudioFixtures.speechFrames(duration: 1.0), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)

    #expect(events.first == .speechStarted)
    guard case .utteranceCaptured(let utterance)? = events.last else {
      Issue.record("Expected a captured utterance, got \(events)")
      return
    }
    #expect(utterance.completionReason == .endOfSpeech)
    #expect(utterance.sampleRate == AudioFixtures.sampleRate)
    // Pre-roll + 1.0 s speech + 0.3 s end silence, within one frame of
    // tolerance.
    let expected = 0.2 + 1.0 + 0.3
    #expect(abs(utterance.duration - expected) < 0.05)
  }

  @Test("A short blip is discarded")
  func shortBlipIsDiscarded() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    var events = consume(
      AudioFixtures.speechFrames(duration: 0.1), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)
    #expect(events == [.speechStarted, .utteranceDiscarded])
  }

  @Test("A transient shorter than the activation window never activates")
  func subActivationTransientIsIgnored() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    var events = consume(
      AudioFixtures.speechFrames(duration: 0.04), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)
    #expect(events.isEmpty)
  }

  @Test("A long utterance closes at the maximum duration")
  func maximumDurationCloses() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    let events = consume(
      AudioFixtures.speechFrames(duration: 6.0), into: &endpointer)
    let captured = events.compactMap { event -> CapturedUtterance? in
      if case .utteranceCaptured(let utterance) = event { return utterance }
      return nil
    }
    #expect(captured.count == 1)
    #expect(captured.first?.completionReason == .maximumDurationReached)
  }

  @Test("Speech resumes after a gap shorter than the end-silence window")
  func midUtterancePauseDoesNotSplit() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    var events = consume(
      AudioFixtures.speechFrames(duration: 0.5), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.2), into: &endpointer)
    events += consume(
      AudioFixtures.speechFrames(duration: 0.5), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.4), into: &endpointer)

    let captured = events.filter {
      if case .utteranceCaptured = $0 { return true }
      return false
    }
    #expect(events.filter { $0 == .speechStarted }.count == 1)
    #expect(captured.count == 1)
  }

  @Test("Two utterances separated by silence are both captured")
  func consecutiveUtterances() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    var events = consume(
      AudioFixtures.speechFrames(duration: 0.6), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)
    events += consume(
      AudioFixtures.speechFrames(duration: 0.6), into: &endpointer)
    events += consume(
      AudioFixtures.silenceFrames(duration: 0.5), into: &endpointer)

    let captured = events.filter {
      if case .utteranceCaptured = $0 { return true }
      return false
    }
    #expect(captured.count == 2)
  }

  @Test("reset() drops buffered audio")
  func resetDropsState() {
    var endpointer = UtteranceEndpointer(configuration: configuration)
    _ = consume(AudioFixtures.speechFrames(duration: 0.5), into: &endpointer)
    #expect(endpointer.isCapturing)
    endpointer.reset()
    #expect(!endpointer.isCapturing)
    let events = consume(
      AudioFixtures.silenceFrames(duration: 1.0), into: &endpointer)
    #expect(events.isEmpty)
  }
}
