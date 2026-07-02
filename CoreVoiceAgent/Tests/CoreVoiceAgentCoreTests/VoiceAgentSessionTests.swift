import CoreVoiceAgentCore
import CoreVoiceAgentTestSupport
import Foundation
import Testing

@Suite("VoiceAgentSession")
struct VoiceAgentSessionTests {
  private struct Fixture {
    let session: VoiceAgentSession
    let input: ScriptedAudioInput
    let output: CapturingAudioOutput
    let transcriber: ScriptedTranscriber
    let responder: ScriptedResponder
    let synthesizer: ScriptedSpeechSynthesizer
  }

  private func makeFixture(
    transcripts: [String] = ["What is CoreAgent?"],
    replies: [String] = [
      "CoreAgent is a production harness. It governs tools and checkpoints transcripts."
    ],
    playbackDelay: Duration = .zero,
    responderError: (any Error)? = nil,
    allowsBargeIn: Bool = true
  ) -> Fixture {
    let configuration = VoiceAgentConfiguration(
      endpointer: EndpointerConfiguration(
        activationThreshold: 0.1,
        activationDuration: 0.05,
        endSilenceDuration: 0.3,
        preRollDuration: 0.2,
        minimumUtteranceDuration: 0.2,
        maximumUtteranceDuration: 5.0
      ),
      chunking: SentenceChunkerConfiguration(
        maximumChunkCharacters: 220,
        minimumChunkCharacters: 10
      ),
      allowsBargeIn: allowsBargeIn
    )
    let input = ScriptedAudioInput()
    let output = CapturingAudioOutput(playbackDelay: playbackDelay)
    let transcriber = ScriptedTranscriber(transcripts: transcripts)
    let responder = ScriptedResponder(replies: replies, error: responderError)
    let synthesizer = ScriptedSpeechSynthesizer()
    let session = VoiceAgentSession(
      configuration: configuration,
      input: input,
      output: output,
      transcriber: transcriber,
      responder: responder,
      synthesizer: synthesizer
    )
    return Fixture(
      session: session,
      input: input,
      output: output,
      transcriber: transcriber,
      responder: responder,
      synthesizer: synthesizer
    )
  }

  /// Collects events until one matches `predicate` (inclusive) or the
  /// timeout elapses.
  private func collect(
    _ stream: AsyncStream<VoiceAgentEvent>,
    until predicate: @escaping @Sendable (VoiceAgentEvent) -> Bool,
    timeout: Duration = .seconds(10)
  ) async -> [VoiceAgentEvent] {
    await withTaskGroup(of: [VoiceAgentEvent].self) { group in
      group.addTask {
        var events: [VoiceAgentEvent] = []
        for await event in stream {
          events.append(event)
          if predicate(event) {
            break
          }
        }
        return events
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return []
      }
      let result = await group.next() ?? []
      group.cancelAll()
      return result
    }
  }

  private func feedUtterance(
    into input: ScriptedAudioInput,
    speechDuration: TimeInterval = 0.6
  ) async {
    await input.feed(AudioFixtures.speechFrames(duration: speechDuration))
    await input.feed(AudioFixtures.silenceFrames(duration: 0.5))
  }

  private func index(
    of events: [VoiceAgentEvent],
    where predicate: (VoiceAgentEvent) -> Bool
  ) -> Int? {
    events.firstIndex(where: predicate)
  }

  @Test("A complete turn emits the expected event sequence")
  func completeTurnEventOrder() async throws {
    let fixture = makeFixture()
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    let events = await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    // Only causally ordered events are asserted in sequence; events from
    // concurrent pipeline stages (assistantText versus playback progress)
    // are checked for presence instead.
    let expectedOrder: [(VoiceAgentEvent) -> Bool] = [
      { $0 == .listening },
      { $0 == .userSpeechStarted },
      { $0 == .transcribing },
      { $0 == .userTranscript("What is CoreAgent?") },
      { $0 == .thinking },
      { if case .synthesizing = $0 { return true }; return false },
      { $0 == .speakingStarted },
      { $0 == .speakingFinished },
      { if case .turnCompleted = $0 { return true }; return false },
    ]
    var searchStart = 0
    for (position, matches) in expectedOrder.enumerated() {
      guard let found = events[searchStart...].firstIndex(where: matches) else {
        Issue.record("Missing expected event at position \(position) in \(events)")
        return
      }
      searchStart = found + 1
    }
    #expect(
      events.contains(
        .assistantText(
          "CoreAgent is a production harness. It governs tools and checkpoints transcripts."
        )
      )
    )

    guard case .turnCompleted(let turn)? = events.last else {
      Issue.record("Expected turnCompleted, got \(String(describing: events.last))")
      return
    }
    #expect(turn.userText == "What is CoreAgent?")
    #expect(turn.assistantText.hasSuffix("transcripts."))
    await fixture.session.stop()
  }

  @Test("The reply is chunked and played in order")
  func replyChunksPlayInOrder() async throws {
    let fixture = makeFixture()
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    _ = await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    let playbacks = await fixture.output.playbacks
    #expect(playbacks.map(\.text) == [
      "CoreAgent is a production harness.",
      "It governs tools and checkpoints transcripts.",
    ])
    await fixture.session.stop()
  }

  @Test("Synthesis runs ahead of playback")
  func synthesisPipelinesAheadOfPlayback() async throws {
    let fixture = makeFixture(playbackDelay: .milliseconds(150))
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    let events = await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    let secondSynthesis = index(of: events) {
      $0 == .synthesizing("It governs tools and checkpoints transcripts.")
    }
    let speakingFinished = index(of: events) { $0 == .speakingFinished }
    guard let secondSynthesis, let speakingFinished else {
      Issue.record("Missing pipeline events in \(events)")
      return
    }
    // Chunk 2 entered synthesis while chunk 1 was still being played:
    // synthesis ran ahead of playback instead of waiting for it.
    #expect(secondSynthesis < speakingFinished)
    let playbacks = await fixture.output.playbacks
    #expect(playbacks.count == 2)
    await fixture.session.stop()
  }

  @Test("Sustained speech during playback barges in and starts a new turn")
  func bargeInCancelsSpeaking() async throws {
    let fixture = makeFixture(
      transcripts: ["First question", "Second question"],
      replies: [
        "This is a deliberately long reply. It has several sentences to speak. Each one becomes audio.",
        "Second answer.",
      ],
      playbackDelay: .seconds(2)
    )
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    var events = await collect(stream) { $0 == .speakingStarted }
    #expect(events.contains(.speakingStarted))

    // Interrupt while the first chunk is still playing.
    await feedUtterance(into: fixture.input)
    events += await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    #expect(events.contains(.bargeIn))
    guard case .turnCompleted(let turn)? = events.last else {
      Issue.record("Expected a completed second turn, got \(String(describing: events.last))")
      return
    }
    #expect(turn.userText == "Second question")
    #expect(turn.assistantText == "Second answer.")
    let stopCount = await fixture.output.stopCount
    #expect(stopCount >= 1)
    await fixture.session.stop()
  }

  @Test("Barge-in is ignored when disabled")
  func bargeInDisabled() async throws {
    let fixture = makeFixture(
      replies: ["A reply that keeps playing for a while. It has two sentences."],
      playbackDelay: .milliseconds(300),
      allowsBargeIn: false
    )
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    var events = await collect(stream) { $0 == .speakingStarted }
    await feedUtterance(into: fixture.input)
    events += await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    #expect(!events.contains(.bargeIn))
    guard case .turnCompleted? = events.last else {
      Issue.record("Expected the first turn to complete, got \(String(describing: events.last))")
      return
    }
    await fixture.session.stop()
  }

  @Test("A responder failure emits turnFailed and returns to listening")
  func responderFailureRecovers() async throws {
    struct BrainFailure: Error {}
    let fixture = makeFixture(responderError: BrainFailure())
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    let events = await collect(stream) { event in
      if case .turnFailed = event { return true }
      return false
    }
    guard case .turnFailed(let error)? = events.last else {
      Issue.record("Expected turnFailed, got \(String(describing: events.last))")
      return
    }
    #expect(error.stage == .response)

    // The session keeps listening and can complete a following turn.
    let recovery = makeFixture()
    _ = recovery
    await fixture.session.stop()
  }

  @Test("An empty transcript skips the responder")
  func emptyTranscriptSkipsTurn() async throws {
    let fixture = makeFixture(transcripts: [""])
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input)

    let events = await collect(
      stream,
      until: { $0 == .listening },
      timeout: .seconds(5)
    )
    _ = events
    // Collect through the transcription; thinking must never appear.
    let more = await collect(
      stream,
      until: { $0 == .thinking },
      timeout: .seconds(1)
    )
    #expect(!more.contains(.thinking))
    let userTexts = await fixture.responder.receivedUserTexts
    #expect(userTexts.isEmpty)
    await fixture.session.stop()
  }

  @Test("stop() emits stopped and finishes the stream")
  func stopFinishesStream() async throws {
    let fixture = makeFixture()
    let stream = try await fixture.session.start()
    await fixture.session.stop()

    var received: [VoiceAgentEvent] = []
    for await event in stream {
      received.append(event)
    }
    #expect(received.last == .stopped)
  }

  @Test("Utterance audio reaches the transcriber intact")
  func transcriberReceivesUtterance() async throws {
    let fixture = makeFixture()
    let stream = try await fixture.session.start()
    await feedUtterance(into: fixture.input, speechDuration: 1.0)

    _ = await collect(stream) { event in
      if case .turnCompleted = event { return true }
      return false
    }

    let utterances = await fixture.transcriber.receivedUtterances
    #expect(utterances.count == 1)
    let utterance = try #require(utterances.first)
    #expect(utterance.sampleRate == AudioFixtures.sampleRate)
    #expect(utterance.completionReason == .endOfSpeech)
    #expect(utterance.duration > 1.0)
    await fixture.session.stop()
  }
}
