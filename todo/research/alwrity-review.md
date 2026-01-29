# ALwrity Review for aidevops Inspiration

**Task**: t037
**Date**: 2026-01-25
**Status**: Complete

## Overview

[ALwrity](https://github.com/AJaySi/ALwrity) (908 stars, MIT license) is an AI-powered digital marketing platform focused on content creation, SEO optimization, and multi-platform publishing.

**Tech Stack**: Python (FastAPI backend), React 18+ (TypeScript frontend), SQLite/PostgreSQL

**AI Providers**: OpenAI, Google Gemini/Imagen, Hugging Face, Anthropic, Mistral

## Key Features Reviewed

### 1. Phased Content Workflow

ALwrity uses a guided phase-based approach for content creation:

```text
Research -> Outline -> Content -> SEO -> Publish
```

Each phase has:
- Guarded navigation (can't skip ahead)
- Local persistence (resume where you left off)
- Quality checkpoints

**aidevops comparison**: Our content.md workflow is similar but less structured. Could benefit from explicit phase gates.

### 2. Content Calendar AI

AI-powered content planning that:
- Analyzes existing content gaps
- Suggests topics based on keyword research
- Schedules across platforms
- Tracks content lifecycle

**aidevops opportunity**: We have keyword-research.md and google-search-console.md but no unified content calendar. This could be a valuable addition.

### 3. Persona System

Core persona generated from onboarding, then adapted per platform:
- Facebook persona adaptations
- LinkedIn persona adaptations
- Instagram persona adaptations

Personas guide tone, structure, and content preferences.

**aidevops comparison**: Our content/guidelines.md and content/humanise.md handle voice/tone but lack platform-specific persona adaptations.

### 4. Google Grounding + RAG

ALwrity uses:
- Google grounding for factual accuracy
- Exa/Tavily for web research
- Citation management for source tracking

**aidevops comparison**: We have context7, crawl4ai, and serper for research. Could add explicit citation tracking.

### 5. Multi-Platform Publishing

Supports:
- Blog posts (WordPress-like)
- LinkedIn (posts, articles, carousels)
- Instagram (Feed, Stories, Reels)
- YouTube (planning, scene building)
- Podcasts (AI audio generation)

**aidevops comparison**: We have WordPress publishing (mainwp.md, wp-admin.md) and social media (bird.md for X/Twitter). LinkedIn and Instagram are gaps.

### 6. SEO Dashboard

Comprehensive SEO tools:
- On-page analysis
- Meta description generation
- Open Graph validation
- Sitemap analysis
- PageSpeed insights
- Google Search Console integration

**aidevops comparison**: We have strong coverage here:
- `seo/google-search-console.md`
- `seo/keyword-research.md`
- `seo/eeat-score.md`
- `seo/site-crawler.md`
- `seo/dataforseo.md`
- `seo/ahrefs.md`

### 7. Audio/Video Content

- Podcast Maker with AI voice synthesis
- Video Studio with WaveSpeed AI
- YouTube Studio for content planning

**aidevops comparison**: We have video subagents (remotion.md, higgsfield.md) but no podcast/audio generation. Related to t071/t072 (voice AI tasks).

## Recommendations for aidevops

### High Value (Consider Implementing)

1. **Content Calendar Workflow** (~2h)
   - Create `tools/content/content-calendar.md` subagent
   - Integrate with keyword-research and google-search-console
   - Add scheduling and gap analysis

2. **Platform Persona Adaptations** (~1h)
   - Extend content/guidelines.md with platform-specific sections
   - Add LinkedIn, Instagram, YouTube voice guidelines

3. **Citation Tracking** (~30m)
   - Add citation management to content workflow
   - Track sources used in AI-generated content

### Medium Value (Nice to Have)

4. **LinkedIn Content Subagent** (~1h)
   - Create `tools/social-media/linkedin.md`
   - Post types: text, articles, carousels, documents
   - Use existing bird.md pattern

5. **Instagram Content Subagent** (~1h)
   - Create `tools/social-media/instagram.md`
   - Feed, Stories, Reels content planning
   - Image generation integration

### Low Value (Already Covered)

- SEO tools (we have comprehensive coverage)
- WordPress publishing (mainwp.md is robust)
- Web research (context7, crawl4ai, serper)

## Architecture Comparison

| Aspect | ALwrity | aidevops |
|--------|---------|----------|
| **Approach** | Full-stack web app | CLI-first, agent-based |
| **UI** | React web interface | Terminal + AI assistants |
| **Deployment** | Self-hosted or cloud | Local installation |
| **AI Integration** | Direct API calls | MCP servers + subagents |
| **Extensibility** | Plugin system (WIP) | Subagent + skill system |

## Conclusion

ALwrity is a well-designed content marketing platform with good ideas for phased workflows and persona management. However, aidevops already has strong SEO coverage and a different architectural approach (CLI-first vs web-first).

**Key takeaways**:
1. Content calendar is the biggest gap worth filling
2. Platform-specific personas could improve content quality
3. Our SEO tooling is already competitive
4. Audio/video content generation aligns with existing t071/t072 tasks

**New tasks to consider**:
- t075: Content Calendar Workflow subagent (~2h)
- t076: Platform Persona Adaptations (~1h)
- t077: LinkedIn Content Subagent (~1h)

## References

- [ALwrity GitHub](https://github.com/AJaySi/ALwrity)
- [ALwrity Wiki](https://github.com/AJaySi/ALwrity/wiki)
- [ALwrity Docs](https://ajaysi.github.io/ALwrity/)
- [Live Demo](https://www.alwrity.com)
