---
name: video
description: Video creation and AI generation - prompt engineering, programmatic video, generative models, editing workflows
mode: subagent
subagents:
  # Video tools
  - video-prompt-design
  - remotion
  - higgsfield
  # Content integration
  - guidelines
  - summarize
  # Research
  - context7
  - crawl4ai
  # Built-in
  - general
  - explore
---

# Video - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: AI video generation and programmatic video creation
- **Subagents**: `tools/video/` (prompt design, Remotion, Higgsfield)

**Capabilities**:
- AI video prompt engineering (Veo 3, Sora, Kling, Seedance)
- Programmatic video creation with React (Remotion)
- Multi-model AI generation via unified API (Higgsfield)
- Character consistency across video series
- Audio design and hallucination prevention

**Typical Tasks**:
- Craft structured prompts for AI video generation
- Build programmatic video pipelines
- Generate consistent character series
- Design camera work, dialogue, and audio
- Compare and select AI video models

<!-- AI-CONTEXT-END -->

## Subagent Reference

| Subagent | Purpose |
|----------|---------|
| `video-prompt-design` | 7-component meta prompt framework for Veo 3 and similar models |
| `remotion` | Programmatic video creation with React - animations, compositions, rendering |
| `higgsfield` | Unified API for 100+ generative media models (image, video, voice, audio) |

## Workflows

### AI Video Prompt Engineering

1. Define character with 15+ attributes for consistency
2. Structure prompt using 7 components (Subject, Action, Scene, Style, Dialogue, Sounds, Technical)
3. Include camera positioning syntax and negative prompts
4. Specify environment audio explicitly to prevent hallucinations
5. Keep dialogue to 12-15 words for 8-second generations

### Programmatic Video (Remotion)

1. Define compositions with `useCurrentFrame()` and `useVideoConfig()`
2. Drive all animations via `interpolate()` or `spring()`
3. Use `<Sequence>` for time-offset content
4. Render via CLI or Lambda for production

### AI Generation Pipeline (Higgsfield)

1. Generate base image with text-to-image (Soul, FLUX)
2. Create character for consistency across generations
3. Convert to video with image-to-video (DOP, Kling, Seedance)
4. Poll for completion via webhooks or status API

## Integration Points

- `content.md` - Script writing and content planning
- `social-media.md` - Platform-specific video formatting
- `marketing.md` - Campaign video production
- `seo.md` - Video SEO (titles, descriptions, thumbnails)
