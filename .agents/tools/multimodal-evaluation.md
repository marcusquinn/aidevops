<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Multimodal Architecture Evaluation (t132)

## Decision

**Do NOT create `tools/multimodal/` directory.** Keep the current per-modality structure (`tools/voice/`, `tools/video/`, `tools/browser/peekaboo.md`, `tools/ocr/`). Cross-references are healthy and sufficient.

## Why Per-Modality Structure Is Correct

1. **Progressive Disclosure**: Route by task intent, not model capability. User asking "transcribe audio" lands in `tools/voice/transcription.md`, not `tools/multimodal/`.
2. **Avoids Routing Ambiguity**: Peekaboo (screen capture + vision) and HeyGen (video + voice) belong in their primary domains, not an ambiguous multimodal category.
3. **No Content Duplication**: S2S models (GPT-4o Realtime, Gemini Live, MiniCPM-o) documented in `voice-ai-models.md` with multimodal capabilities noted. Moving them creates duplication or broken references.
4. **Framework Precedent**: Organize by task domain, not technology capability (`tools/browser/` not `tools/chromium/`, `tools/voice/` not `tools/audio-models/`).

## Current Cross-References (Already Working)

| Link | Purpose |
|------|---------|
| `speech-to-speech.md` → `tools/video/remotion.md` | Video narration |
| `voice-models.md` → `heygen-skill/rules-voices.md` | AI voice cloning |
| `heygen-skill.md` → voice selection | Avatar video voices |
| `peekaboo.md` → `tools/ocr/glm-ocr.md` | Screen capture + OCR |
| `glm-ocr.md` → Peekaboo | OCR workflows |
| `speech-to-speech.md` → `tools/infrastructure/cloud-gpu.md` | GPU infrastructure |

## Multimodal Models (Documented in Primary Domains)

| Model | Modalities | Location |
|-------|-----------|----------|
| GPT-4o / GPT-4o Realtime | Text + Vision + Voice (S2S) | `voice-ai-models.md` |
| Gemini 2.0 Live / 2.5 | Text + Vision + Voice (streaming) | `voice-ai-models.md` |
| MiniCPM-o 4.5 | Text + Vision + Voice (S2S, open weights) | `voice-ai-models.md` |
| Ultravox | Audio + Text | `voice-ai-models.md` |
| HeyGen Streaming Avatars | Voice + Video (avatar) | `heygen-skill/` |
| Higgsfield API | Image + Video + Voice + Audio (unified) | `higgsfield.md` |

## Optional Improvements (No New Directory)

1. **Expand `voice-ai-models.md` S2S section** with "Multimodal Model Landscape" heading mapping which models span which modalities (voice is most common entry point).
2. **Add `--multimodal` filter to `compare-models.md`** to surface voice+vision+text models (capability filter on existing data).
3. **Add AGENTS.md routing note**: `| Multimodal | See Voice (S2S models), Video (HeyGen, Higgsfield), Browser (Peekaboo vision) |`

## Revisit Condition

If multimodal workflows grow significantly (e.g., dedicated orchestration pipeline combining voice+vision+video), revisit this decision. Current cross-reference pattern is sufficient and avoids duplication/routing problems.
