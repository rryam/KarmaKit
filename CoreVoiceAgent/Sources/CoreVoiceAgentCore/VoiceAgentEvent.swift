import Foundation

/// One completed exchange between the user and the assistant.
public struct VoiceAgentTurn: Sendable, Equatable {
  /// The final transcript of the user's utterance.
  public let userText: String

  /// The assistant's complete reply.
  public let assistantText: String

  /// Creates a turn from its transcripts.
  public init(userText: String, assistantText: String) {
    self.userText = userText
    self.assistantText = assistantText
  }
}

/// An ordered notification emitted by a voice agent session.
///
/// Events describe the session's progress through each turn, from speech
/// detection through transcription, response generation, and playback.
/// Observe them to drive UI state:
///
/// ```swift
/// for await event in try await session.start() {
///   switch event {
///   case .userTranscript(let text):
///     viewModel.showUserMessage(text)
///   case .partialAssistantText(let text):
///     viewModel.updateAssistantMessage(text)
///   default:
///     break
///   }
/// }
/// ```
public enum VoiceAgentEvent: Sendable, Equatable {
  /// The session is capturing audio and waiting for speech.
  case listening

  /// Sustained speech was detected; an utterance is being captured.
  case userSpeechStarted

  /// The endpointer closed the utterance and transcription is running.
  case transcribing

  /// The running transcript while the recognizer decodes, when available.
  case partialUserTranscript(String)

  /// The final transcript for the current user turn.
  case userTranscript(String)

  /// The responder is generating a reply.
  case thinking

  /// A cumulative snapshot of the streamed assistant reply.
  case partialAssistantText(String)

  /// The complete assistant reply for the turn.
  case assistantText(String)

  /// A sentence chunk was handed to the speech synthesizer.
  case synthesizing(String)

  /// The first audio chunk of the reply started playing.
  case speakingStarted

  /// All audio for the reply finished playing.
  case speakingFinished

  /// The user interrupted the assistant; the in-flight turn was cancelled.
  case bargeIn

  /// A user/assistant exchange completed end to end.
  case turnCompleted(VoiceAgentTurn)

  /// A turn failed with a recoverable error; the session returns to
  /// listening.
  case turnFailed(VoiceAgentError)

  /// The session stopped and the event stream is about to finish.
  case stopped
}

/// An error surfaced by a voice agent session.
public struct VoiceAgentError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The pipeline stage where the failure occurred.
  public enum Stage: String, Sendable {
    case audioInput
    case transcription
    case response
    case synthesis
    case playback
  }

  /// The pipeline stage where the failure occurred.
  public let stage: Stage

  /// A human-readable description of the failure.
  public let message: String

  /// Creates an error with a message.
  public init(stage: Stage, message: String) {
    self.stage = stage
    self.message = message
  }

  /// Creates an error that wraps an underlying error.
  public init(stage: Stage, underlying error: any Error) {
    self.stage = stage
    self.message = String(describing: error)
  }

  public var description: String {
    "\(stage.rawValue): \(message)"
  }
}
