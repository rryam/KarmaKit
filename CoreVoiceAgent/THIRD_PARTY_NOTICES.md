# Third-Party Notices

CoreVoiceAgent composes the following third-party work.

## Vendored code

- **Chatterbox Core AI engine** (`Sources/CoreVoiceAgentChatterbox`):
  vendored from
  [rudrankriyam/Core-AI-Framework-Lab](https://github.com/rudrankriyam/Core-AI-Framework-Lab)
  (MIT), revision `02d7502b1e631f0773189fa2f044b52ade039aa7`, and adapted
  for library use (directory-based recipe loading; results carry raw
  waveforms instead of WAV files).

## Package dependencies

- **[CoreAgent](https://github.com/rudrankriyam/CoreAgent)** — MIT.
- **[coreai-kit](https://github.com/john-rocky/coreai-kit)** — BSD
  3-Clause, copyright (c) 2026 Daisuke Majima. Provides
  `KitParakeetModel`, the Parakeet-TDT Core AI runtime.
- **[swift-transformers](https://github.com/huggingface/swift-transformers)**
  — Apache License 2.0.

## Model weights (downloaded or supplied by the app, not distributed
with this package)

- **NVIDIA Parakeet-TDT-0.6B-v3**
  ([`mlboydaisuke/Parakeet-TDT-0.6B-CoreAI`](https://huggingface.co/mlboydaisuke/Parakeet-TDT-0.6B-CoreAI),
  converted from
  [`nvidia/parakeet-tdt-0.6b-v3`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3))
  — CC-BY-4.0. Ship attribution to NVIDIA with your app.
- **Resemble AI Chatterbox Turbo**
  (converted with
  [Core-AI-Framework-Lab](https://github.com/rudrankriyam/Core-AI-Framework-Lab)
  from
  [`ResembleAI/chatterbox-turbo`](https://huggingface.co/ResembleAI/chatterbox-turbo))
  — MIT.
