---
name: youtube-distribution
description: YouTube long-form distribution - competitor research, content strategy, and video production automation
mode: subagent
model: sonnet
subagents:
  - channel-intel
  - topic-research
  - script-writer
  - optimizer
  - pipeline
---

# YouTube Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: YouTube long-form video distribution within the content pipeline
- **Main Agent**: `youtube.md` (this directory) - orchestrator for all YouTube operations
- **Subagents**: `channel-intel`, `topic-research`, `script-writer`, `optimizer`, `pipeline`
- **Helper**: `youtube-helper.sh` - YouTube Data API v3 wrapper
- **Commands**: `/youtube setup`, `/youtube research`, `/youtube script`

**This directory is the authoritative location for all YouTube agents.** YouTube is a distribution channel within the content pipeline (`content.md`). The subagents here handle competitor research, topic ideation, script generation, metadata optimization, and automated pipelines.

<!-- AI-CONTEXT-END -->

## Subagents

| Subagent | Purpose |
|----------|---------|
| `channel-intel.md` | Competitor analysis, outlier detection, content DNA |
| `topic-research.md` | Niche trends, content gaps, keyword clustering |
| `script-writer.md` | Long-form scripts with hooks and retention curves |
| `optimizer.md` | Title, description, tags, thumbnail optimization |
| `pipeline.md` | End-to-end cron-driven automation pipeline |

## Distribution Workflow

When the content pipeline fans out to YouTube:

1. **Receive story and production assets** from upstream pipeline stages
2. **Adapt to YouTube format** using `script-writer.md`
   - Long-form script (8-20 minutes)
   - Scene-by-scene breakdown with B-roll directions
   - Hook optimization for first 30 seconds
3. **Optimize metadata** using `optimizer.md`
   - Title variants with CTR signals
   - SEO-optimized description with timestamps
   - Tag generation (primary + long-tail + competitor)
   - Thumbnail brief
4. **Publish and monitor** using `pipeline.md`

## YouTube-Specific Format Rules

| Parameter | Specification |
|-----------|--------------|
| **Aspect ratio** | 16:9 (landscape) |
| **Resolution** | 1080p minimum, 4K preferred |
| **Length** | 8-20 minutes (optimal for ad revenue) |
| **Thumbnail** | 1280x720, high contrast, readable text |
| **Title** | Under 60 characters, keyword-front |
| **Description** | First 2 lines visible, timestamps, links |
| **Tags** | 5-10 relevant keywords |
| **Chapters** | Timestamps for videos over 5 minutes |

## Cross-Channel Repurposing

From one YouTube video, generate:

- **YouTube Short** - Best 30-60s clip, 9:16 reformat (`content/distribution/short-form.md`)
- **Blog post** - Transcript-based SEO article (`content/distribution/blog.md`)
- **Social posts** - Key insights as X thread, LinkedIn post, Reddit discussion (`content/distribution/social.md`)
- **Email** - Newsletter featuring video + key takeaways (`content/distribution/email.md`)
- **Podcast** - Audio-only version with show notes (`content/distribution/podcast.md`)

## Related Agents

- `youtube.md` - Full YouTube orchestrator (this directory)
- `content/production/video.md` - Video generation (Sora 2 Pro, Veo 3.1)
- `content/production/audio.md` - Voice pipeline
- `content/story.md` - Narrative design and hook formulas
- `content/optimization.md` - A/B testing and analytics
- `youtube-helper.sh` - YouTube Data API v3 wrapper
