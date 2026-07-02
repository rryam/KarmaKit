import Foundation

/// A session that runs the full voice loop for one conversation.
///
/// The session owns turn-taking. It segments user speech from the capture
/// stream, transcribes the finished utterance, streams the responder's
/// reply through the sentence chunker, and pipelines synthesis against
/// playback so the next chunk is synthesized while the current one plays.
/// Sustained user speech during an assistant turn cancels it (barge-in)
/// when the configuration allows.
///
/// ```swift
/// let session = VoiceAgentSession(
///   input: MicrophoneAudioInput(),
///   output: SpeakerAudioOutput(),
///   transcriber: AppTranscriber(),
///   responder: CoreAgentResponder(session: agent),
///   synthesizer: ChatterboxSpeechSynthesizer(engine: chatterbox)
/// )
///
/// for await event in try await session.start() {
///   // Drive UI from ordered session events.
/// }
/// ```
///
/// Every dependency is a protocol, so the ears, brain (CoreAgent over any
/// Foundation Models `LanguageModel`), and mouth (Chatterbox) are swappable
/// without touching the loop.
public actor VoiceAgentSession {
  private let configuration: VoiceAgentConfiguration
  private let input: any AudioInput
  private let output: any AudioOutput
  private let transcriber: any Transcriber
  private let responder: any ConversationResponder
  private let synthesizer: any SpeechSynthesizer

  private var endpointer: UtteranceEndpointer
  private var chunker: SentenceChunker

  private var eventContinuation: AsyncStream<VoiceAgentEvent>.Continuation?
  private var captureTask: Task<Void, Never>?
  private var turnTask: Task<Void, Never>?
  private var chunkContinuation: AsyncStream<String>.Continuation?
  private var hasStarted = false
  private var isStopping = false

  /// Creates a voice agent session.
  ///
  /// - Parameters:
  ///   - configuration: Endpointing, chunking, and barge-in tuning.
  ///   - input: The source of captured audio frames.
  ///   - output: The destination for synthesized speech.
  ///   - transcriber: The speech-to-text engine.
  ///   - responder: The conversational brain.
  ///   - synthesizer: The text-to-speech engine.
  public init(
    configuration: VoiceAgentConfiguration = VoiceAgentConfiguration(),
    input: any AudioInput,
    output: any AudioOutput,
    transcriber: any Transcriber,
    responder: any ConversationResponder,
    synthesizer: any SpeechSynthesizer
  ) {
    self.configuration = configuration
    self.input = input
    self.output = output
    self.transcriber = transcriber
    self.responder = responder
    self.synthesizer = synthesizer
    self.endpointer = UtteranceEndpointer(configuration: configuration.endpointer)
    self.chunker = SentenceChunker(configuration: configuration.chunking)
  }

  /// Starts capturing and returns the ordered event stream.
  ///
  /// A session runs once; create a new session after `stop()`.
  ///
  /// - Returns: A stream of session events, in order.
  public func start() async throws -> AsyncStream<VoiceAgentEvent> {
    precondition(!hasStarted, "VoiceAgentSession.start() may only be called once.")
    hasStarted = true

    let (stream, continuation) = AsyncStream.makeStream(
      of: VoiceAgentEvent.self,
      bufferingPolicy: .unbounded
    )
    eventContinuation = continuation

    let frames = try await input.start()
    emit(.listening)

    captureTask = Task { [weak self] in
      for await frame in frames {
        guard let self else { return }
        await self.handleFrame(frame)
      }
    }
    return stream
  }

  /// Stops the session.
  ///
  /// Cancels any in-flight turn, stops audio capture and playback, emits
  /// `.stopped`, and finishes the event stream.
  public func stop() async {
    guard hasStarted, !isStopping else { return }
    isStopping = true
    captureTask?.cancel()
    captureTask = nil
    await cancelTurn()
    await input.stop()
    await output.stop()
    endpointer.reset()
    emit(.stopped)
    eventContinuation?.finish()
    eventContinuation = nil
  }

  // MARK: - Frame handling

  private func handleFrame(_ frame: AudioFrame) async {
    guard !isStopping else { return }
    for event in endpointer.consume(frame) {
      switch event {
      case .speechStarted:
        await handleSpeechStarted()
      case .utteranceCaptured(let utterance):
        handleUtterance(utterance)
      case .utteranceDiscarded:
        if turnTask == nil {
          emit(.listening)
        }
      }
    }
  }

  private func handleSpeechStarted() async {
    if turnTask != nil {
      guard configuration.allowsBargeIn else { return }
      await cancelTurn()
      await output.stop()
      emit(.bargeIn)
    }
    emit(.userSpeechStarted)
  }

  private func handleUtterance(_ utterance: CapturedUtterance) {
    guard turnTask == nil else {
      // A turn is still running and barge-in is disabled; drop the audio
      // rather than queue talk-over.
      return
    }
    turnTask = Task { [weak self] in
      await self?.runTurn(with: utterance)
    }
  }

  private func cancelTurn() async {
    guard let task = turnTask else { return }
    turnTask = nil
    task.cancel()
    await task.value
  }

  // MARK: - Turn pipeline

  private func runTurn(with utterance: CapturedUtterance) async {
    do {
      emit(.transcribing)
      let userText = try await transcribe(utterance)
      guard !userText.isEmpty else {
        finishTurn(returnToListening: true)
        return
      }
      emit(.userTranscript(userText))
      emit(.thinking)
      let assistantText = try await respondAndSpeak(to: userText)
      emit(.turnCompleted(VoiceAgentTurn(userText: userText, assistantText: assistantText)))
      finishTurn(returnToListening: true)
    } catch is CancellationError {
      finishTurn(returnToListening: false)
    } catch let error as VoiceAgentError {
      await failTurn(with: error)
    } catch {
      await failTurn(with: VoiceAgentError(stage: .response, underlying: error))
    }
  }

  private func failTurn(with error: VoiceAgentError) async {
    guard !Task.isCancelled else {
      finishTurn(returnToListening: false)
      return
    }
    await output.stop()
    emit(.turnFailed(error))
    finishTurn(returnToListening: true)
  }

  private func finishTurn(returnToListening: Bool) {
    chunkContinuation = nil
    chunker = SentenceChunker(configuration: configuration.chunking)
    turnTask = nil
    if returnToListening && !isStopping {
      emit(.listening)
    }
  }

  private func transcribe(_ utterance: CapturedUtterance) async throws -> String {
    let continuation = eventContinuation
    do {
      let text = try await transcriber.transcribe(
        utterance,
        onPartialTranscript: { partial in
          continuation?.yield(.partialUserTranscript(partial))
        }
      )
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw VoiceAgentError(stage: .transcription, underlying: error)
    }
  }

  /// Streams the reply while synthesizing and playing completed sentence
  /// chunks. Three concurrent stages, connected by streams:
  ///
  ///     responder (cumulative partials) -> chunker -> chunk texts
  ///     chunk texts -> synthesizer -> finished audio
  ///     finished audio -> output
  ///
  /// Returns the complete assistant text after all audio has played.
  private func respondAndSpeak(to userText: String) async throws -> String {
    let (chunkStream, chunkContinuation) = AsyncStream.makeStream(
      of: String.self,
      bufferingPolicy: .unbounded
    )
    let (speechStream, speechContinuation) = AsyncStream.makeStream(
      of: SynthesizedSpeech.self,
      bufferingPolicy: .unbounded
    )
    self.chunkContinuation = chunkContinuation
    chunker = SentenceChunker(configuration: configuration.chunking)

    let responder = self.responder
    let synthesizer = self.synthesizer
    let output = self.output
    let events = eventContinuation

    return try await withThrowingTaskGroup(of: String?.self) { group in
      // Stage 1: the responder. Cumulative partials are chunked on the
      // actor so chunk emission stays ordered with the rest of the
      // session.
      group.addTask { [weak self] in
        defer { chunkContinuation.finish() }
        let session = self
        let finalText = try await responder.respond(to: userText) { partial in
          await session?.consumeResponsePartial(partial)
        }
        await session?.flushChunker()
        return finalText
      }

      // Stage 2: serial synthesis, one chunk ahead of playback.
      group.addTask {
        defer { speechContinuation.finish() }
        for await text in chunkStream {
          try Task.checkCancellation()
          events?.yield(.synthesizing(text))
          do {
            let speech = try await synthesizer.synthesize(text)
            speechContinuation.yield(speech)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw VoiceAgentError(stage: .synthesis, underlying: error)
          }
        }
        return nil
      }

      // Stage 3: serial playback.
      group.addTask {
        var hasStartedSpeaking = false
        for await speech in speechStream {
          try Task.checkCancellation()
          if !hasStartedSpeaking {
            hasStartedSpeaking = true
            events?.yield(.speakingStarted)
          }
          do {
            try await output.play(speech)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw VoiceAgentError(stage: .playback, underlying: error)
          }
        }
        if hasStartedSpeaking {
          events?.yield(.speakingFinished)
        }
        return nil
      }

      var assistantText = ""
      do {
        for try await result in group {
          if let result {
            assistantText = result
            emit(.assistantText(result))
          }
        }
      } catch let error as VoiceAgentError {
        group.cancelAll()
        throw error
      } catch is CancellationError {
        group.cancelAll()
        throw CancellationError()
      } catch {
        group.cancelAll()
        throw VoiceAgentError(stage: .response, underlying: error)
      }
      return assistantText
    }
  }

  private func consumeResponsePartial(_ cumulativeText: String) {
    guard !isStopping else { return }
    emit(.partialAssistantText(cumulativeText))
    for chunk in chunker.consume(cumulativeText: cumulativeText) {
      chunkContinuation?.yield(chunk)
    }
  }

  private func flushChunker() {
    for chunk in chunker.finish() {
      chunkContinuation?.yield(chunk)
    }
  }

  private func emit(_ event: VoiceAgentEvent) {
    eventContinuation?.yield(event)
  }
}
