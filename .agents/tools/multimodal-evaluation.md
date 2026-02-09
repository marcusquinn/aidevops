# Multimodal Architecture Evaluation (t132)

## Summary

**Recommendation: Do NOT create `tools/multimodal/` directory.**

The current per-modality structure (`tools/voice/`, `tools/video/`, `tools/browser/peekaboo.md`, `tools/ocr/`) is the correct architecture. Cross-references between modalities are already well-maintained. A `tools/multimodal/` directory would create duplication, routing ambiguity, and violate the framework's progressive disclosure pattern.

## Current State

### Modality Directories

| Directory | Files | Purpose |
|-----------|-------|---------|
| `tools/voice/` | 9 files | TTS, STT, S2S, transcription, voice bridge, Pipecat |
| `tools/video/` | 5 files + heygen-skill/ + remotion/ | Video generation, prompt design, downloading |
| `tools/browser/peekaboo.md` | 1 file | Screen capture + AI vision analysis |
| `tools/ocr/` | 1 file | Local document OCR (GLM-OCR via Ollama) |
| `tools/mobile/` | 6 files | iOS/macOS device automation |

### Models Spanning Voice + Vision

These models handle multiple modalities natively (not cascaded pipelines):

| Model | Modalities | Where Documented |
|-------|-----------|-----------------|
| GPT-4o / GPT-4o Realtime | Text + Vision + Voice (S2S) | `voice-ai-models.md:88`, `pipecat-opencode.md:62` |
| Gemini 2.0 Live / 2.5 | Text + Vision + Voice (streaming) | `voice-ai-models.md:89`, `pipecat-opencode.md:62` |
| MiniCPM-o 4.5 | Text + Vision + Voice (S2S, open weights) | `voice-ai-models.md:90` |
| Ultravox | Audio + Text (multimodal) | `voice-ai-models.md:91`, `pipecat-opencode.md:65` |
| HeyGen Streaming Avatars | Voice + Video (avatar) | `heygen-skill/rules/streaming-avatars.md` |
| Higgsfield API | Image + Video + Voice + Audio (unified API) | `higgsfield.md:1-18` |

### Existing Cross-References (Already Working)

The framework already links modalities where they intersect:

1. **Voice -> Video**: `speech-to-speech.md:236-240` links to `tools/video/remotion.md` for video narration
2. **Voice -> Video**: `voice-models.md:308` links to `heygen-skill/rules/voices.md` for AI voice cloning
3. **Video -> Voice**: `heygen-skill.md` references voice selection for avatar videos
4. **Vision -> OCR**: `peekaboo.md:517` links to `tools/ocr/glm-ocr.md` for OCR workflows
5. **OCR -> Vision**: `glm-ocr.md:37` links back to Peekaboo for screen capture + OCR
6. **Voice -> Infrastructure**: `speech-to-speech.md:244` links to `tools/infrastructure/cloud-gpu.md`
7. **AGENTS.md routing**: Progressive disclosure table routes Voice and Video as separate domains

### Where "Multimodal" Appears

Only 2 files use the word "multimodal":

- `voice-ai-models.md:1` — in the S2S section describing models like Ultravox
- `compare-models.md:1` — in model capability comparison

This confirms multimodal is a model capability, not a workflow category.

## Analysis: Why `tools/multimodal/` Would Be Wrong

### 1. Violates Progressive Disclosure

The framework's core pattern is: route by task intent, not by model capability. A user asking "transcribe this audio" should land in `tools/voice/transcription.md`, not `tools/multimodal/`. The fact that the underlying model (Whisper) could theoretically do other things is irrelevant to the user's task.

### 2. Creates Routing Ambiguity

Where would Peekaboo go? It's a screen capture tool (browser/desktop) that happens to use vision models. Where would HeyGen go? It's a video tool that uses voice. A `tools/multimodal/` directory would force every cross-modal tool into an ambiguous category, making discovery harder.

### 3. Duplicates Existing Content

The S2S models (GPT-4o Realtime, Gemini Live, MiniCPM-o) are already documented in `voice-ai-models.md` with their multimodal capabilities noted. Moving them to `tools/multimodal/` would either duplicate content or leave broken references.

### 4. The Cross-References Already Work

The "See Also" sections in voice, video, and vision files already link to each other where workflows cross modality boundaries. This is the correct pattern — keep content where the primary use case lives, cross-reference where workflows intersect.

### 5. Framework Precedent

The framework organizes by task domain, not by technology capability:

- `tools/browser/` — not `tools/chromium/`
- `tools/voice/` — not `tools/audio-models/`
- `tools/video/` — not `tools/generative-media/`

## What Could Be Improved (Without a New Directory)

### A. Add a "Multimodal Models" Section to `voice-ai-models.md`

The S2S section at `voice-ai-models.md:82-93` already covers multimodal models but could be expanded with a clearer "Multimodal Model Landscape" heading that explicitly maps which models span which modalities. This is the natural home since voice is the most common entry point for multimodal interaction.

### B. Add Cross-References to `compare-models.md`

The model comparison tool could gain a `--multimodal` filter to surface models that span voice+vision+text. This is a capability filter on existing data, not a new directory.

### C. Ensure AGENTS.md Routing Covers Multimodal Queries

The progressive disclosure table in AGENTS.md could add a note:

```text
| Multimodal | See Voice (S2S models), Video (HeyGen, Higgsfield), Browser (Peekaboo vision) |
```

This routes users to the right domain-specific docs without creating a new directory.

## Decision

**Keep the current per-modality structure.** The cross-references are healthy. The models that span modalities are documented where their primary use case lives. No `tools/multimodal/` directory is needed.

If multimodal workflows grow significantly (e.g., a dedicated multimodal orchestration pipeline that combines voice+vision+video in a single workflow), revisit this decision. For now, the cross-reference pattern is sufficient and avoids the duplication/routing problems a new directory would create.
