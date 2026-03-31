---
name: heygen
description: "Best practices for HeyGen - AI avatar video creation API"
mode: subagent
imported_from: https://github.com/heygen-com/skills
---

# HeyGen Skill

Load when working with HeyGen API code — avatar videos, video generation workflows, service integration.

## Rule Files

### Foundation

| Rule | Covers |
|------|--------|
| [rules-authentication.md](heygen-skill/rules-authentication.md) | API key setup, X-Api-Key header, auth patterns |
| [rules-quota.md](heygen-skill/rules-quota.md) | Credit system, usage limits, remaining quota |
| [rules-video-status.md](heygen-skill/rules-video-status.md) | Polling patterns, status types, download URLs |
| [rules-assets.md](heygen-skill/rules-assets.md) | Uploading images, videos, audio for generation |

### Core Video Creation

| Rule | Covers |
|------|--------|
| [rules-avatars.md](heygen-skill/rules-avatars.md) | Avatar listing, styles, avatar_id selection |
| [rules-voices.md](heygen-skill/rules-voices.md) | Voice listing, locales, speed/pitch config |
| [rules-scripts.md](heygen-skill/rules-scripts.md) | Script writing, pauses/breaks, pacing, templates |
| [rules-video-generation.md](heygen-skill/rules-video-generation.md) | POST /v2/video/generate, multi-scene videos |
| [rules-video-agent.md](heygen-skill/rules-video-agent.md) | One-shot prompt generation via Video Agent API |
| [rules-dimensions.md](heygen-skill/rules-dimensions.md) | Resolution (720p/1080p), aspect ratios |

### Video Customization

| Rule | Covers |
|------|--------|
| [rules-backgrounds.md](heygen-skill/rules-backgrounds.md) | Solid colors, images, video backgrounds |
| [rules-text-overlays.md](heygen-skill/rules-text-overlays.md) | Text with fonts and positioning |
| [rules-captions.md](heygen-skill/rules-captions.md) | Auto-generated captions, subtitle options |

### Advanced Features

| Rule | Covers |
|------|--------|
| [rules-templates.md](heygen-skill/rules-templates.md) | Template listing, variable replacement |
| [rules-video-translation.md](heygen-skill/rules-video-translation.md) | Translation, quality/fast modes, dubbing |
| [rules-streaming-avatars.md](heygen-skill/rules-streaming-avatars.md) | Real-time interactive avatar sessions |
| [rules-photo-avatars.md](heygen-skill/rules-photo-avatars.md) | Avatars from photos (talking photos) |
| [rules-webhooks.md](heygen-skill/rules-webhooks.md) | Webhook endpoints, event types |

### Integration

| Rule | Covers |
|------|--------|
| [rules-remotion-integration.md](heygen-skill/rules-remotion-integration.md) | HeyGen avatar videos in Remotion compositions |
