import CoreAgent
import CoreVoiceAgentCore
import Foundation
import FoundationModels

/// A conversation responder backed by a `CoreAgentSession`.
///
/// This is the seam that makes the brain swappable: `CoreAgentSession`
/// accepts any Foundation Models `LanguageModel` — the on-device system
/// model, a provider model from `CoreAgentProviders`, or a recorded model
/// from `CoreAgentTestSupport` — and this responder carries whichever one
/// the session was built with into the voice loop, along with CoreAgent's
/// tool governance, checkpoints, memory, and observability.
///
/// ```swift
/// let agent = try CoreAgentSession(
///   model: SystemLanguageModel.default,
///   instructions: Instructions {
///     "You are a voice assistant. Keep replies short and speakable."
///     "Prefer plain sentences over lists, code, and markup."
///   }
/// )
///
/// let responder = CoreAgentResponder(session: agent)
/// ```
///
/// The `CoreAgentSession` is persistent, so the voice conversation
/// accumulates in its native transcript across turns — and checkpoints,
/// retention, and memory plugins apply to voice turns exactly as they do
/// to text turns.
public struct CoreAgentResponder: ConversationResponder {
  /// The wrapped agent session.
  public let session: CoreAgentSession

  /// Generation options applied to every voice turn.
  public let options: GenerationOptions

  /// Creates a responder over an existing agent session.
  ///
  /// - Parameters:
  ///   - session: The agent session that owns the model, tools, and
  ///     transcript.
  ///   - options: Generation options applied to every voice turn.
  public init(
    session: CoreAgentSession,
    options: GenerationOptions = GenerationOptions()
  ) {
    self.session = session
    self.options = options
  }

  public func respond(
    to userText: String,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let response = try await session.respondStreaming(
      to: userText,
      options: options,
      onPartialResponse: onPartialResponse
    )
    return response.content
  }
}
