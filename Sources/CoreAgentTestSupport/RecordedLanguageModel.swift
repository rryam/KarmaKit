import CoreAgent
import Foundation
import FoundationModels

public enum RecordedLanguageModelError: Error, LocalizedError, Sendable {
  case scriptExhausted
  case scriptedFailure(String)

  public var errorDescription: String? {
    switch self {
    case .scriptExhausted:
      "The recorded language model script has no remaining steps."
    case .scriptedFailure(let message):
      message
    }
  }
}

public enum RecordedLanguageModelStep: Sendable {
  case response(
    text: String,
    inputTokens: Int = 1,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 1,
    reasoningTokens: Int = 0
  )
  case responseFragments([String])
  case toolCall(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    argumentsJSON: String,
    inputTokens: Int = 1,
    outputTokens: Int = 1
  )
  case delayedResponse(text: String, delay: Duration)
  case failure(String)
}

public final class RecordedLanguageModelRecorder: @unchecked Sendable, CoreAgentScriptedModelResponding {
  private let lock = NSLock()
  private var steps: [RecordedLanguageModelStep]
  private var requestTranscripts: [Transcript] = []

  public init(steps: [RecordedLanguageModelStep]) {
    self.steps = steps
  }

  public func capturedTranscripts() -> [Transcript] {
    lock.lock()
    defer { lock.unlock() }
    return requestTranscripts
  }

  package func makeScriptedResponse<Content: Generable & Sendable>(
    for transcript: Transcript,
    contentType: Content.Type
  ) async throws -> CoreAgentScriptedModelResponse<Content> {
    let step = try nextStep(recording: transcript)
    switch step {
    case .response(
      let text,
      let inputTokens,
      let cachedInputTokens,
      let outputTokens,
      let reasoningTokens
    ):
      return try makeTextResponse(
        text: text,
        contentType: contentType,
        inputTokens: inputTokens,
        cachedInputTokens: cachedInputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens,
        continuesAfterToolCalls: false
      )

    case .toolCall(let id, let name, let argumentsJSON, let inputTokens, let outputTokens):
      let arguments = try GeneratedContent(json: argumentsJSON)
      let entry = CoreAgentScriptedModelSupport.toolCallsEntry(
        id: id,
        name: name,
        arguments: arguments
      )
      let content = try placeholderContent(contentType)
      let rawContent = try GeneratedContent(json: #"{"text":""}"#)
      return CoreAgentScriptedModelResponse(
        content: content,
        rawContent: rawContent,
        transcriptEntries: [entry][...],
        usage: CoreAgentScriptedModelSupport.usage(
          inputTokens: inputTokens,
          outputTokens: outputTokens
        ),
        continuesAfterToolCalls: true
      )

    case .responseFragments(let fragments):
      let text = fragments.joined()
      return try makeTextResponse(
        text: text,
        contentType: contentType,
        inputTokens: 1,
        cachedInputTokens: 0,
        outputTokens: fragments.count,
        reasoningTokens: 0,
        continuesAfterToolCalls: false
      )

    case .failure(let message):
      throw RecordedLanguageModelError.scriptedFailure(message)

    case .delayedResponse(let text, let delay):
      try await Task.sleep(for: delay)
      return try makeTextResponse(
        text: text,
        contentType: contentType,
        inputTokens: 1,
        cachedInputTokens: 0,
        outputTokens: 1,
        reasoningTokens: 0,
        continuesAfterToolCalls: false
      )
    }
  }

  package func makeScriptedStreamSnapshot<Content: Generable & Sendable>(
    for transcript: Transcript,
    contentType: Content.Type,
    onPartialResponse: @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> CoreAgentScriptedStreamSnapshot<Content>
  where Content.PartiallyGenerated: Sendable {
    let step = try nextStep(recording: transcript)
    switch step {
    case .responseFragments(let fragments):
      var combined = ""
      var partial = try makePartial("", contentType: contentType).0
      var rawContent = try makePartial("", contentType: contentType).1
      for fragment in fragments {
        combined.append(fragment)
        (partial, rawContent) = try makePartial(combined, contentType: contentType)
        await onPartialResponse(partial, rawContent)
      }
      let entry = CoreAgentScriptedModelSupport.responseEntry(for: combined)
      return CoreAgentScriptedStreamSnapshot(
        content: partial,
        rawContent: rawContent,
        transcriptEntries: [entry][...],
        usage: CoreAgentScriptedModelSupport.usage(
          inputTokens: 1,
          outputTokens: fragments.count
        )
      )

    case .response(let text, let inputTokens, let cachedInputTokens, let outputTokens, let reasoningTokens):
      let (partial, rawContent) = try makePartial(text, contentType: contentType)
      await onPartialResponse(partial, rawContent)
      return CoreAgentScriptedStreamSnapshot(
        content: partial,
        rawContent: rawContent,
        transcriptEntries: [CoreAgentScriptedModelSupport.responseEntry(for: text)][...],
        usage: CoreAgentScriptedModelSupport.usage(
          inputTokens: inputTokens,
          cachedInputTokens: cachedInputTokens,
          outputTokens: outputTokens,
          reasoningTokens: reasoningTokens
        )
      )

    case .failure(let message):
      throw RecordedLanguageModelError.scriptedFailure(message)

    case .delayedResponse(let text, let delay):
      try await Task.sleep(for: delay)
      let (partial, rawContent) = try makePartial(text, contentType: contentType)
      await onPartialResponse(partial, rawContent)
      return CoreAgentScriptedStreamSnapshot(
        content: partial,
        rawContent: rawContent,
        transcriptEntries: [CoreAgentScriptedModelSupport.responseEntry(for: text)][...],
        usage: CoreAgentScriptedModelSupport.usage(inputTokens: 1, outputTokens: 1)
      )

    case .toolCall:
      throw RecordedLanguageModelError.scriptedFailure(
        "RecordedLanguageModel streaming does not support tool-call scripted steps."
      )
    }
  }


  private func makePartial<Content: Generable & Sendable>(
    _ text: String,
    contentType: Content.Type
  ) throws -> (Content.PartiallyGenerated, GeneratedContent)
  where Content.PartiallyGenerated: Sendable {
    let raw = try GeneratedContent(json: text.hasPrefix("{") ? text : #"{"text":"\#(text)"}"#)
    if Content.self == String.self {
      let partial = text as! Content.PartiallyGenerated
      return (partial, raw)
    }
    let partial = try Content.PartiallyGenerated(raw)
    return (partial, raw)
  }

  private func nextStep(recording transcript: Transcript) throws -> RecordedLanguageModelStep {
    lock.lock()
    defer { lock.unlock() }
    requestTranscripts.append(transcript)
    guard !steps.isEmpty else {
      throw RecordedLanguageModelError.scriptExhausted
    }
    return steps.removeFirst()
  }

  private func makeTextResponse<Content: Generable & Sendable>(
    text: String,
    contentType: Content.Type,
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    reasoningTokens: Int,
    continuesAfterToolCalls: Bool
  ) throws -> CoreAgentScriptedModelResponse<Content> {
    let content: Content
    let rawContent: GeneratedContent
    if Content.self == String.self {
      content = text as! Content
      rawContent = try GeneratedContent(json: #"{"text":"\#(text)"}"#)
    } else {
      rawContent = try GeneratedContent(json: text)
      content = try Content(rawContent)
    }
    return CoreAgentScriptedModelResponse(
      content: content,
      rawContent: rawContent,
      transcriptEntries: [CoreAgentScriptedModelSupport.responseEntry(for: text)][...],
      usage: CoreAgentScriptedModelSupport.usage(
        inputTokens: inputTokens,
        cachedInputTokens: cachedInputTokens,
        outputTokens: outputTokens,
        reasoningTokens: reasoningTokens
      ),
      continuesAfterToolCalls: continuesAfterToolCalls
    )
  }

  private func placeholderContent<Content: Generable & Sendable>(
    _ contentType: Content.Type
  ) throws -> Content {
    if Content.self == String.self {
      return "" as! Content
    }
    return try Content(GeneratedContent(json: "{}"))
  }
}

public struct RecordedLanguageModel: Sendable {
  public let recorder: RecordedLanguageModelRecorder

  public init(steps: [RecordedLanguageModelStep]) {
    self.recorder = RecordedLanguageModelRecorder(steps: steps)
  }

  public init(_ recorder: RecordedLanguageModelRecorder) {
    self.recorder = recorder
  }
}


public struct RecordedLanguageModelUnimplementedExecutor: LanguageModelExecutor {
  public typealias Model = RecordedLanguageModel

  public struct Configuration: Hashable, Sendable {
    fileprivate let recorder: RecordedLanguageModelRecorder

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.recorder === rhs.recorder
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(recorder))
    }
  }

  private let recorder: RecordedLanguageModelRecorder

  public init(configuration: Configuration) throws {
    self.recorder = configuration.recorder
  }

  nonisolated(nonsending)
  public func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: RecordedLanguageModel,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    _ = (request, model, channel, recorder)
    throw RecordedLanguageModelError.scriptedFailure(
      "RecordedLanguageModel must run through CoreAgentSession scripted routing."
    )
  }
}

extension RecordedLanguageModel: LanguageModel {
  public typealias Executor = RecordedLanguageModelUnimplementedExecutor

  public var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.guidedGeneration, .toolCalling])
  }

  public var executorConfiguration: RecordedLanguageModelUnimplementedExecutor.Configuration {
    .init(recorder: recorder)
  }
}

extension RecordedLanguageModel: CoreAgentScriptedLanguageModelHarness {
  package var scriptedRecorder: any CoreAgentScriptedModelResponding { recorder }
}
