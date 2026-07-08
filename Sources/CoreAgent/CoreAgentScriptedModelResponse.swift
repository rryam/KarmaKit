import Foundation
import FoundationModels

package protocol CoreAgentScriptedLanguageModelHarness: LanguageModel {
  var scriptedRecorder: any CoreAgentScriptedModelResponding { get }
}

package enum CoreAgentScriptedModelBridgeError: Error, LocalizedError, Sendable {
  case missingScriptedTool(String)

  package var errorDescription: String? {
    switch self {
    case .missingScriptedTool(let name):
      "No scripted tool named \(name) is registered on this CoreAgent session."
    }
  }
}

package enum CoreAgentScriptedModelSupport {
  package static func apply(
    _ entries: ArraySlice<Transcript.Entry>,
    to session: LanguageModelSession
  ) {
    guard !entries.isEmpty else { return }
    var transcript = session.transcript
    transcript.append(contentsOf: entries)
    session.transcript = transcript
  }

  package static func appendPrompt(
    _ prompt: Prompt,
    contextBlocks: [CoreAgentContextBlock],
    fallbackText: String? = nil,
    to session: LanguageModelSession
  ) {
    var segments: [Transcript.Segment] = contextBlocks.map {
      .text(.init(content: $0.content))
    }
    if let fallbackText, !fallbackText.isEmpty {
      segments.append(.text(.init(content: fallbackText)))
    } else {
      segments.append(contentsOf: transcriptSegments(for: prompt))
    }
    let entry = Transcript.Entry.prompt(.init(segments: segments))
    apply([entry][...], to: session)
  }

  package static func responseEntry(for text: String) -> Transcript.Entry {
    let segment = Transcript.Segment.text(.init(content: text))
    return .response(.init(assetIDs: [], segments: [segment]))
  }

  package static func toolCallsEntry(
    id: String,
    name: String,
    arguments: GeneratedContent
  ) -> Transcript.Entry {
    .toolCalls(
      Transcript.ToolCalls([Transcript.ToolCall(id: id, toolName: name, arguments: arguments)]))
  }

  package static func toolOutputEntry(
    id: String,
    toolName: String,
    output: Prompt
  ) -> Transcript.Entry {
    .toolOutput(
      .init(
        id: id,
        toolName: toolName,
        segments: transcriptSegments(for: output)
      )
    )
  }

  package static func usage(
    inputTokens: Int,
    cachedInputTokens: Int = 0,
    outputTokens: Int,
    reasoningTokens: Int = 0
  ) -> LanguageModelSession.Usage {
    .init(
      input: .init(totalTokenCount: inputTokens, cachedTokenCount: cachedInputTokens),
      output: .init(totalTokenCount: outputTokens, reasoningTokenCount: reasoningTokens)
    )
  }

  package static func decodedText(from rawContent: GeneratedContent) throws -> String {
    let json = rawContent.jsonString
    if let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = object["text"] as? String
    {
      return text
    }
    return try String(rawContent)
  }

  package static func content<Content: Generable & Sendable>(
    _ type: Content.Type,
    from rawContent: GeneratedContent
  ) throws -> Content {
    if Content.self == String.self {
      return try decodedText(from: rawContent) as! Content
    }
    return try Content(rawContent)
  }

  package static func transcriptSegments(for prompt: Prompt) -> [Transcript.Segment] {
    if let text = promptText(prompt) {
      return [.text(.init(content: text))]
    }
    return []
  }

  private static func promptText(_ prompt: Prompt) -> String? {
    let mirror = Mirror(reflecting: prompt)
    for child in mirror.children {
      if child.label == "components", let components = child.value as? [Any] {
        let parts = components.compactMap { componentText($0) }
        if !parts.isEmpty {
          return parts.joined()
        }
      }
      if let text = child.value as? String {
        return text
      }
      if let nested = child.value as? Prompt {
        return promptText(nested)
      }
      if let array = child.value as? [Any] {
        let parts = array.compactMap { element -> String? in
          if let text = element as? String { return text }
          if let nested = element as? Prompt { return promptText(nested) }
          return componentText(element)
        }
        if !parts.isEmpty {
          return parts.joined()
        }
      }
    }
    return nil
  }

  private static func componentText(_ component: Any) -> String? {
    let mirror = Mirror(reflecting: component)
    if mirror.displayStyle == .enum {
      guard let associated = mirror.children.first?.value else { return nil }
      return promptTextValue(associated) ?? componentText(associated)
    }
    return promptTextValue(component)
  }

  private static func promptTextValue(_ value: Any) -> String? {
    let mirror = Mirror(reflecting: value)
    for child in mirror.children where child.label == "value" {
      if let text = child.value as? String {
        return text
      }
    }
    return nil
  }
}

package struct CoreAgentScriptedModelResponse<Content: Generable & Sendable>: Sendable {
  package let content: Content
  package let rawContent: GeneratedContent
  package let transcriptEntries: ArraySlice<Transcript.Entry>
  package let usage: LanguageModelSession.Usage
  package let continuesAfterToolCalls: Bool

  package init(
    content: Content,
    rawContent: GeneratedContent,
    transcriptEntries: ArraySlice<Transcript.Entry>,
    usage: LanguageModelSession.Usage,
    continuesAfterToolCalls: Bool = false
  ) {
    self.content = content
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.continuesAfterToolCalls = continuesAfterToolCalls
  }
}

package protocol CoreAgentScriptedModelResponding: AnyObject, Sendable {
  func makeScriptedResponse<Content: Generable & Sendable>(
    for transcript: Transcript,
    contentType: Content.Type
  ) async throws -> CoreAgentScriptedModelResponse<Content>

  func makeScriptedStreamSnapshot<Content: Generable & Sendable>(
    for transcript: Transcript,
    contentType: Content.Type,
    onPartialResponse: @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> CoreAgentScriptedStreamSnapshot<Content>
  where Content.PartiallyGenerated: Sendable
}

package struct CoreAgentScriptedStreamSnapshot<Content: Generable & Sendable>: Sendable
where Content.PartiallyGenerated: Sendable {
  package let content: Content.PartiallyGenerated
  package let rawContent: GeneratedContent
  package let transcriptEntries: ArraySlice<Transcript.Entry>
  package let usage: LanguageModelSession.Usage

  package init(
    content: Content.PartiallyGenerated,
    rawContent: GeneratedContent,
    transcriptEntries: ArraySlice<Transcript.Entry>,
    usage: LanguageModelSession.Usage
  ) {
    self.content = content
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
  }
}
