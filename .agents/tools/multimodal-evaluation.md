# Multimodal Architecture Evaluation (t132)

## Decision

**Do NOT create `tools/multimodal/` directory.** Keep the current per-modality structure.

The framework organizes by task intent, not model capability. Route by what the user is doing, not what the underlying model can do:

- `tools/browser/` — not `tools/chromium/`
- `tools/voice/` — not `tools/audio-models/`
- `tools/video/` — not `tools/generative-media/`

A `tools/multimodal/` directory would: (1) violate progressive disclosure — "transcribe this audio" belongs in `tools/voice/transcription.md`, not `tools/multimodal/`; (2) create routing ambiguity — Peekaboo is a browser/desktop tool that uses vision; HeyGen is a video tool that uses voice; (3) duplicate content already in `voice-ai-models.md`; (4) break the cross-references that already work.

Revisit if a dedicated multimodal orchestration pipeline (voice+vision+video in a single workflow) emerges. The cross-reference pattern is sufficient until then.

## Modality Directories

| Directory | Files | Purpose |
|-----------|-------|---------|
| `tools/voice/` | 9 files | TTS, STT, S2S, transcription, voice bridge, Pipecat |
| `tools/video/` | 5 files + heygen-skill/ + remotion-*.md | Video generation, prompt design, downloading |
| `tools/browser/peekaboo.md` | 1 file | Screen capture + AI vision analysis |
| `tools/ocr/` | 1 file | Local document OCR (GLM-OCR via Ollama) |
| `tools/mobile/` | 6 files | iOS/macOS device automation |

## Models Spanning Multiple Modalities

Documented where their primary use case lives, not in a separate directory:

| Model | Modalities | Where Documented |
|-------|-----------|-----------------|
| GPT-4o / GPT-4o Realtime | Text + Vision + Voice (S2S) | `voice-ai-models.md` S2S section, `pipecat-opencode.md` |
| Gemini 2.0 Live / 2.5 | Text + Vision + Voice (streaming) | `voice-ai-models.md` S2S section, `pipecat-opencode.md` |
| MiniCPM-o 4.5 | Text + Vision + Voice (S2S, open weights) | `voice-ai-models.md` S2S section |
| Ultravox | Audio + Text (multimodal) | `voice-ai-models.md` S2S section, `pipecat-opencode.md` |
| HeyGen Streaming Avatars | Voice + Video (avatar) | `heygen-skill/rules-streaming-avatars.md` |
| Higgsfield API | Image + Video + Voice + Audio (unified API) | `higgsfield.md` |

"Multimodal" appears in only 2 files (`voice-ai-models.md`, `compare-models.md`) — confirming it is a model capability, not a workflow category.

## Existing Cross-References (Healthy)

1. **Voice -> Video**: `speech-to-speech.md` links to `tools/video/remotion.md` for video narration
2. **Voice -> Video**: `voice-models.md` links to `heygen-skill/rules-voices.md` for AI voice cloning
3. **Video -> Voice**: `heygen-skill.md` references voice selection for avatar videos
4. **Vision -> OCR**: `peekaboo.md` links to `tools/ocr/glm-ocr.md` for OCR workflows
5. **OCR -> Vision**: `glm-ocr.md` links back to Peekaboo for screen capture + OCR
6. **Voice -> Infrastructure**: `speech-to-speech.md` links to `tools/infrastructure/cloud-gpu.md`
7. **AGENTS.md routing**: Progressive disclosure table routes Voice and Video as separate domains

## Optional Improvements (No New Directory Required)

- **`voice-ai-models.md`**: Add a "Multimodal Model Landscape" heading to the S2S section to make cross-modal coverage explicit
- **`compare-models.md`**: Add `--multimodal` filter to surface models spanning voice+vision+text
- **AGENTS.md routing table**: Add `| Multimodal | See Voice (S2S models), Video (HeyGen, Higgsfield), Browser (Peekaboo vision) |`
