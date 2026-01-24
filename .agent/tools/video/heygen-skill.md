---
description: "Best practices for HeyGen - AI avatar video creation API"
mode: subagent
imported_from: https://github.com/heygen-com/skills
---

# HeyGen Skill

Best practices for HeyGen - AI avatar video creation API.

## When to use

Use this skill whenever you are dealing with HeyGen API code to obtain domain-specific knowledge for creating AI avatar videos, managing avatars, handling video generation workflows, and integrating with HeyGen's services.

## How to use

Read individual rule files for detailed explanations and code examples:

### Foundation
- [heygen-skill/rules/authentication.md](heygen-skill/rules/authentication.md) - API key setup, X-Api-Key header, and authentication patterns
- [heygen-skill/rules/quota.md](heygen-skill/rules/quota.md) - Credit system, usage limits, and checking remaining quota
- [heygen-skill/rules/video-status.md](heygen-skill/rules/video-status.md) - Polling patterns, status types, and retrieving download URLs
- [heygen-skill/rules/assets.md](heygen-skill/rules/assets.md) - Uploading images, videos, and audio for use in video generation

### Core Video Creation
- [heygen-skill/rules/avatars.md](heygen-skill/rules/avatars.md) - Listing avatars, avatar styles, and avatar_id selection
- [heygen-skill/rules/voices.md](heygen-skill/rules/voices.md) - Listing voices, locales, speed/pitch configuration
- [heygen-skill/rules/scripts.md](heygen-skill/rules/scripts.md) - Writing scripts, pauses/breaks, pacing, and structure templates
- [heygen-skill/rules/video-generation.md](heygen-skill/rules/video-generation.md) - POST /v2/video/generate workflow and multi-scene videos
- [heygen-skill/rules/video-agent.md](heygen-skill/rules/video-agent.md) - One-shot prompt video generation with Video Agent API
- [heygen-skill/rules/dimensions.md](heygen-skill/rules/dimensions.md) - Resolution options (720p/1080p) and aspect ratios

### Video Customization
- [heygen-skill/rules/backgrounds.md](heygen-skill/rules/backgrounds.md) - Solid colors, images, and video backgrounds
- [heygen-skill/rules/text-overlays.md](heygen-skill/rules/text-overlays.md) - Adding text with fonts and positioning
- [heygen-skill/rules/captions.md](heygen-skill/rules/captions.md) - Auto-generated captions and subtitle options

### Advanced Features
- [heygen-skill/rules/templates.md](heygen-skill/rules/templates.md) - Template listing and variable replacement
- [heygen-skill/rules/video-translation.md](heygen-skill/rules/video-translation.md) - Translating videos, quality/fast modes, and dubbing
- [heygen-skill/rules/streaming-avatars.md](heygen-skill/rules/streaming-avatars.md) - Real-time interactive avatar sessions
- [heygen-skill/rules/photo-avatars.md](heygen-skill/rules/photo-avatars.md) - Creating avatars from photos (talking photos)
- [heygen-skill/rules/webhooks.md](heygen-skill/rules/webhooks.md) - Registering webhook endpoints and event types

### Integration
- [heygen-skill/rules/remotion-integration.md](heygen-skill/rules/remotion-integration.md) - Using HeyGen avatar videos in Remotion compositions
