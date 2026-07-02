# Changelog

## 0.1.0

Initial release.

- `CoreVoiceAgentCore`: the platform-independent voice pipeline —
  `VoiceAgentSession` orchestrator with pipelined synthesis/playback and
  barge-in, deterministic energy `UtteranceEndpointer`, incremental
  `SentenceChunker`, and protocol seams (`AudioInput`, `AudioOutput`,
  `Transcriber`, `ConversationResponder`, `SpeechSynthesizer`).
- `CoreVoiceAgent`: `CoreAgentResponder`, adapting `CoreAgentSession`
  (any Foundation Models `LanguageModel`) as the conversational brain.
- `CoreVoiceAgentParakeet`: `ParakeetTranscriber` over `coreai-kit`'s
  `KitParakeetModel` (NVIDIA Parakeet-TDT-0.6B through Core AI).
- `CoreVoiceAgentChatterbox`: `ChatterboxEngine` and
  `ChatterboxSpeechSynthesizer` (Chatterbox Turbo through Core AI),
  vendored from Core-AI-Framework-Lab and adapted to return raw samples
  with cooperative cancellation in the T3 decode loop.
- `CoreVoiceAgentAudio`: `MicrophoneAudioInput` (voice-processed,
  echo-cancelled 16 kHz capture) and `SpeakerAudioOutput`.
- `CoreVoiceAgentTestSupport`: scripted components and audio fixtures;
  27 core tests run on any Swift platform, including Linux.
