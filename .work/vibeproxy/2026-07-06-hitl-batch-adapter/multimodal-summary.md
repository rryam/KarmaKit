# VibeProxy Multimodal Smoke

Date: 2026-07-06
Gateway: `http://127.0.0.1:8320/v1/chat/completions`

Fixture:

- `multimodal-rgb.png`
- 32x32 RGB PNG
- Locally validated with `file` and `sips -g pixelWidth -g pixelHeight`

Results:

| Model | HTTP | Summary |
| --- | --- | --- |
| `gpt-5.5` | 200 | Processed image input and identified a solid red square. |
| `gemini-3.5-flash-low` | 200 | Processed image input and identified a solid red square. |
| `claude-haiku-4-5-20251001` | 200 | Processed image input and identified a 32x32 RGB PNG red square. |

Notes:

- Direct `gemini-3.5-flash` was not a direct VibeProxy model ID on `:8320`; the working direct Gemini model ID was `gemini-3.5-flash-low`.
- No audio/video route was exposed by the discovered OpenAI-compatible VibeProxy endpoints.
