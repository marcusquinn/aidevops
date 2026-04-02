---
name: heygen
description: "Best practices for HeyGen - AI avatar video creation API"
mode: subagent
imported_from: https://github.com/heygen-com/skills
---

# HeyGen Skill

Load when working with HeyGen API code — avatar videos, video generation workflows, service integration.

## Rule Files

| Rule | Category | Covers |
|------|----------|--------|
| [rules-authentication.md](heygen-skill/rules-authentication.md) | Foundation | API key setup, X-Api-Key header, auth patterns |
| [rules-quota.md](heygen-skill/rules-quota.md) | Foundation | Credit system, usage limits, remaining quota |
| [rules-video-status.md](heygen-skill/rules-video-status.md) | Foundation | Polling patterns, status types, download URLs |
| [rules-assets.md](heygen-skill/rules-assets.md) | Foundation | Uploading images, videos, audio for generation |
| [rules-avatars.md](heygen-skill/rules-avatars.md) | Core | Avatar listing, styles, avatar_id selection |
| [rules-voices.md](heygen-skill/rules-voices.md) | Core | Voice listing, locales, speed/pitch config |
| [rules-scripts.md](heygen-skill/rules-scripts.md) | Core | Script writing, pauses/breaks, pacing, templates |
| [rules-video-generation.md](heygen-skill/rules-video-generation.md) | Core | POST /v2/video/generate, multi-scene videos |
| [rules-video-agent.md](heygen-skill/rules-video-agent.md) | Core | One-shot prompt generation via Video Agent API |
| [rules-dimensions.md](heygen-skill/rules-dimensions.md) | Core | Resolution (720p/1080p), aspect ratios |
| [rules-backgrounds.md](heygen-skill/rules-backgrounds.md) | Customization | Solid colors, images, video backgrounds |
| [rules-text-overlays.md](heygen-skill/rules-text-overlays.md) | Customization | Text with fonts and positioning |
| [rules-captions.md](heygen-skill/rules-captions.md) | Customization | Auto-generated captions, subtitle options |
| [rules-templates.md](heygen-skill/rules-templates.md) | Advanced | Template listing, variable replacement |
| [rules-video-translation.md](heygen-skill/rules-video-translation.md) | Advanced | Translation, quality/fast modes, dubbing |
| [rules-streaming-avatars.md](heygen-skill/rules-streaming-avatars.md) | Advanced | Real-time interactive avatar sessions |
| [rules-photo-avatars.md](heygen-skill/rules-photo-avatars.md) | Advanced | Avatars from photos (talking photos) |
| [rules-webhooks.md](heygen-skill/rules-webhooks.md) | Advanced | Webhook endpoints, event types |
| [rules-remotion-integration.md](heygen-skill/rules-remotion-integration.md) | Integration | HeyGen avatar videos in Remotion compositions |
