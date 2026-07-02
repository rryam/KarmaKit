# CoreVoiceAgent

**CoreAgent makes any model shippable. CoreVoiceAgent gives it a voice.**

CoreVoiceAgent is an on-device voice agent pipeline for Apple platforms:

```text
microphone ──▶ endpointer ──▶ transcriber ──▶ responder ──▶ chunker ──▶ synthesizer ──▶ speaker
   (ears: Parakeet-TDT via Core AI)      (brain: CoreAgent over      (mouth: Chatterbox Turbo
                                          Foundation Models)          via Core AI)
```

Every stage is a protocol, and the defaults are all local: NVIDIA
Parakeet-TDT-0.6B speech recognition through Core AI, a
[CoreAgent](https://github.com/rudrankriyam/CoreAgent) session over any
Foundation Models `LanguageModel` (the on-device system model by default),
and Resemble AI's Chatterbox Turbo text-to-speech through Core AI. No
cloud, no per-minute pricing, no audio leaving the device.

`VoiceAgentSession` owns the loop: it segments user speech with a
deterministic energy endpointer, transcribes the finished utterance,
streams the reply through an incremental sentence chunker, and pipelines
synthesis against playback so the next sentence is being generated while
the current one plays. Sustained user speech during a reply cancels it
(barge-in) over the echo-cancelled capture path.

## Requirements

- Swift 6.2+ toolchain (Xcode 27 for the CoreAgent and Core AI paths)
- iOS 27+ or macOS 27+ for the full on-device stack
- The platform-independent core (`CoreVoiceAgentCore`) compiles and tests
  anywhere Swift runs, including Linux

## Installation

```swift
dependencies: [
  .package(
    url: "https://github.com/rudrankriyam/CoreVoiceAgent.git",
    from: "0.1.0"
  )
]
```

Pick products by the weight you want to carry:

| Product | What it adds |
| --- | --- |
| `CoreVoiceAgent` | The pipeline plus the CoreAgent-backed responder |
| `CoreVoiceAgentCore` | Just the pipeline and protocols (no Apple-only imports) |
| `CoreVoiceAgentParakeet` | Parakeet-TDT ears via `coreai-kit` |
| `CoreVoiceAgentChatterbox` | Chatterbox Turbo mouth via Core AI |
| `CoreVoiceAgentAudio` | `AVAudioEngine` capture and playback |
| `CoreVoiceAgentTestSupport` | Scripted components and audio fixtures |

## Quick start

```swift
import CoreAgent
import CoreVoiceAgent
import CoreVoiceAgentAudio
import CoreVoiceAgentChatterbox
import CoreVoiceAgentParakeet
import CoreAIKit
import FoundationModels

// The brain: any LanguageModel, wrapped in CoreAgent's production
// harness. Voice turns accumulate in the native transcript, and tool
// governance, checkpoints, and memory apply as they do for text.
let agent = try CoreAgentSession(
  model: SystemLanguageModel.default,
  instructions: Instructions {
    "You are a voice assistant. Keep replies short and speakable."
    "Prefer plain sentences over lists, code, and markup."
  }
)

// The ears: Parakeet-TDT-0.6B, downloaded from the Hub on first use.
let parakeet = try await KitParakeetModel(model: .parakeetTDT)

// The mouth: Chatterbox Turbo from a directory containing recipe.json
// and the four .aimodel assets.
let chatterbox = ChatterboxEngine(recipeDirectory: chatterboxModelsURL)
try await chatterbox.prepare()

let session = VoiceAgentSession(
  input: MicrophoneAudioInput(),
  output: SpeakerAudioOutput(),
  transcriber: ParakeetTranscriber(model: parakeet),
  responder: CoreAgentResponder(session: agent),
  synthesizer: ChatterboxSpeechSynthesizer(engine: chatterbox)
)

for await event in try await session.start() {
  switch event {
  case .userTranscript(let text):
    print("User: \(text)")
  case .assistantText(let text):
    print("Assistant: \(text)")
  case .bargeIn:
    print("(interrupted)")
  default:
    break
  }
}
```

On iOS, configure an `AVAudioSession` with the `.playAndRecord` category
and `.voiceChat` mode, and request microphone permission, before starting
the session.

## Swap the brain

`CoreAgentResponder` carries whichever `LanguageModel` its
`CoreAgentSession` was built with. Everything CoreAgent supports drops in
unchanged — the on-device system model, Claude or Gemini through
`CoreAgentProviders`, a local server through Apple's generic Chat
Completions client, or `RecordedLanguageModel` from
`CoreAgentTestSupport` for deterministic tests:

```swift
let claude = CoreAgentProviderModels.claude(
  auth: .proxied(headers: ["Authorization": appSessionToken]),
  baseURL: relayURL
)
let responder = CoreAgentResponder(session: try CoreAgentSession(model: claude))
```

Governed tools work mid-conversation: a voice turn that triggers a
CoreAgent tool goes through the same approval, allowlist, budget, and
timeout policy as a text turn, and the confirmation is spoken back.

Any other brain conforms in one method:

```swift
struct EchoResponder: ConversationResponder {
  func respond(
    to userText: String,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let reply = "You said: \(userText)"
    await onPartialResponse(reply)
    return reply
  }
}
```

## Swap the ears and mouth

`Transcriber` and `SpeechSynthesizer` are single-method protocols.
Parakeet and Chatterbox are the fully local defaults; the Speech
framework, WhisperKit, or a Kokoro port each fit the same seams.

The batch `Transcriber` shape is deliberate. Parakeet decodes a finished
clip about 48x faster than real time on an iPhone 17 Pro GPU, so
endpoint-then-transcribe adds roughly a third of a second to the turn —
far simpler and more robust than incremental streaming against a model
with a fixed 30-second encoder bucket.

## Model assets

| Stage | Model | Size | License |
| --- | --- | --- | --- |
| Ears | [`mlboydaisuke/Parakeet-TDT-0.6B-CoreAI`](https://huggingface.co/mlboydaisuke/Parakeet-TDT-0.6B-CoreAI) | ~1.3 GB | CC-BY-4.0 |
| Brain | On-device Foundation Models system model | — | — |
| Mouth | Chatterbox Turbo Core AI export ([conversion recipes](https://github.com/rudrankriyam/Core-AI-Framework-Lab)) | ~600 MiB | MIT (weights: Resemble AI) |

`KitParakeetModel` downloads its bundle from the Hub on first use. For
iPhone, AOT-compile the Parakeet encoder to `.aimodelc` as described in
the [coreai-model-zoo notes](https://github.com/john-rocky/coreai-model-zoo);
the raw 1.2 GB asset stalls on-device JIT specialization.

The Chatterbox engine loads a directory (or bundle resource folder)
containing `recipe.json`, the four `.aimodel` assets, and the tokenizer —
the exact layout Core-AI-Framework-Lab produces. Export them with the
conversion scripts there, or copy them from its
`CoreAILab/Resources/Chatterbox`.

## Latency model

Time-to-first-audio for a turn is approximately:

```text
endSilence (0.8 s default)
  + Parakeet pass (~0.3 s warm)
  + first sentence from the model (model-dependent)
  + Chatterbox synthesis of that first sentence
```

The sentence chunker flushes the first completed sentence immediately —
regardless of the minimum-chunk setting — and later chunks synthesize
while earlier ones play, so the perceived gap is dominated by the first
sentence, not the full reply. Shorten `endSilenceDuration` for snappier
turns at the cost of more mid-sentence cutoffs.

## Testing

`CoreVoiceAgentTestSupport` runs the whole loop without hardware, models,
or network:

```swift
let session = VoiceAgentSession(
  input: ScriptedAudioInput(),
  output: CapturingAudioOutput(),
  transcriber: ScriptedTranscriber(transcripts: ["Hello there"]),
  responder: ScriptedResponder(replies: ["Hi! How can I help?"]),
  synthesizer: ScriptedSpeechSynthesizer()
)
```

The core test suite is platform-independent:

```bash
swift test                       # on a Mac, all targets
Scripts/test-core-linux.sh       # on Linux, the core + test support
```

Pair `CoreAgentResponder` with CoreAgent's `RecordedLanguageModel` for
end-to-end voice tests with a deterministic, zero-network brain.

## Deliberate boundaries

- **Endpoint-then-transcribe, not streaming ASR.** See above; the seams
  allow a streaming transcriber later without touching the session.
- **One fixed voice.** The Chatterbox Core AI export currently covers the
  fixed-voice inference path. Voice cloning needs the reference-voice
  encoders converted first.
- **Sentence-granular barge-in.** Cancellation stops synthesis within one
  T3 decode token and playback at the next buffer, but the already-spoken
  words stand — the transcriptual record keeps what the user actually
  heard... and CoreAgent's transcript keeps the full intended reply.
- **The session does not manage audio-session policy.** Categories,
  routing, and interruptions differ per app; `MicrophoneAudioInput`
  documents what it needs.

## License

CoreVoiceAgent is available under the MIT license. See
`THIRD_PARTY_NOTICES.md` for the licenses of the model runtimes and
weights it composes.
