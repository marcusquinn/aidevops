---
name: youtube
description: YouTube competitor research, content strategy, and video production automation
mode: subagent
model: sonnet
subagents:
  - channel-intel
  - topic-research
  - script-writer
  - optimizer
  - pipeline
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# YouTube - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: YouTube competitor research, content ideation, script generation, and channel optimization
- **Tools**: YouTube Data API v3 (via service account), yt-dlp, DataForSEO, Serper, Outscraper
- **Helper**: `youtube-helper.sh` - Channel lookup, video enumeration, search, transcripts, competitor comparison
- **Memory**: Cross-session persistence via `memory-helper.sh` (namespace: `youtube`)
- **Commands**: `/youtube setup`, `/youtube research`, `/youtube competitors`, `/youtube script`, `/youtube pipeline`

**Subagents** (`youtube/`):

| Subagent | Purpose |
|----------|---------|
| `channel-intel` | Channel profiling, competitor analysis, outlier detection |
| `topic-research` | Niche trends, content gaps, keyword clustering, angle generation |
| `script-writer` | YouTube script generation with hooks, retention curves, remix mode |
| `optimizer` | Title, tags, description, hook, and thumbnail optimization |
| `pipeline` | Automated cron-driven research pipeline |

<!-- AI-CONTEXT-END -->

## When to Use

Read this agent when the user wants to:

- Research YouTube competitors and their content strategy
- Find video topic ideas and content gaps in a niche
- Generate YouTube video scripts (hooks, outlines, full scripts)
- Optimize titles, tags, descriptions, and thumbnails
- Set up automated competitor monitoring
- Analyze what's working in a niche (outlier detection)

## Architecture

The YouTube agent composes existing aidevops tools rather than building from scratch:

```text
youtube.md (orchestrator)
  |
  +-- youtube-helper.sh          YouTube Data API v3 wrapper
  +-- yt-dlp-helper.sh           Video/transcript download
  +-- keyword-research-helper.sh SEO keyword data
  +-- memory-helper.sh           Cross-session persistence
  |
  +-- youtube/channel-intel.md   Competitor profiling
  +-- youtube/topic-research.md  Ideation & gap analysis
  +-- youtube/script-writer.md   Script generation
  +-- youtube/optimizer.md       Title/tag/description optimization
  +-- youtube/pipeline.md        Automated cron pipeline
```

## Data Sources (No Browser Required)

| Source | What It Provides | Quota/Cost |
|--------|-----------------|------------|
| YouTube Data API v3 | Channel metadata, video stats, playlists | 10,000 units/day free |
| yt-dlp | Transcripts, full metadata, downloads | Unlimited (local) |
| DataForSEO | YouTube SERP rankings, keyword volume | Per-request pricing |
| Serper | Google Trends, web search | Per-request pricing |
| Outscraper | YouTube comments, sentiment | Per-request pricing |

**Key insight**: Most YouTube research does NOT need browser automation. The API + yt-dlp approach avoids the context-filling screenshot problem entirely.

## Quick Start

### 1. Setup (one-time)

```bash
# Test YouTube API access
youtube-helper.sh auth-test

# Store your channel and competitors in memory
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"
```

### 2. Research a competitor

```bash
# Channel overview
youtube-helper.sh channel @competitor

# List their videos with stats
youtube-helper.sh videos @competitor 100

# Compare multiple channels
youtube-helper.sh competitors @me @comp1 @comp2 @comp3

# Get transcript of a high-performing video
youtube-helper.sh transcript VIDEO_ID
```

### 3. Find opportunities

```bash
# Trending in your niche
youtube-helper.sh trending "your niche topic" 20

# Search for specific topics
youtube-helper.sh search "topic keyword" video 20
```

### 4. Check quota

```bash
youtube-helper.sh quota
```

## Quota Management

The YouTube Data API has a 10,000 unit daily quota. Budget carefully:

| Operation | Cost | Budget for 10k |
|-----------|------|----------------|
| Channel lookup | 1 unit | 10,000 lookups |
| Video details (batch of 50) | 1 unit | 500,000 videos |
| Playlist items (50 per page) | 1 unit | 500,000 videos |
| **Search** | **100 units** | **100 searches** |
| Transcript (via yt-dlp) | 0 units | Unlimited |

**Strategy**: Use `playlistItems` to enumerate channel videos (1 unit/50 videos) instead of `search` (100 units/50 results). Use yt-dlp for transcripts (free, no quota).

## Memory Namespaces

The YouTube agent uses these memory namespaces for cross-session persistence:

| Namespace | Content |
|-----------|---------|
| `youtube` | Channel profiles, competitor data, niche definition |
| `youtube-topics` | Research findings, content gaps, trending topics |
| `youtube-scripts` | Generated scripts, outlines, hooks |
| `youtube-patterns` | What titles/hooks/topics performed well |

```bash
# Store research finding
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: No one covers [topic] from [angle] perspective"

# Recall previous research
memory-helper.sh recall --namespace youtube "competitor analysis"
```

## Workflow: Full Research Cycle

1. **Channel Intel** (read `youtube/channel-intel.md`)
   - Profile your channel and 3-5 competitors
   - Identify outlier videos (3x+ channel average views)
   - Extract content DNA (topics, formats, angles)

2. **Topic Research** (read `youtube/topic-research.md`)
   - Content gap analysis (your topics vs competitors)
   - Keyword clustering for YouTube search
   - Trend detection (rising topics before they peak)
   - Angle generation (unique takes on proven topics)

3. **Script Writing** (read `youtube/script-writer.md`)
   - Generate scripts with hook -> intro -> body -> CTA
   - Remix mode: transform competitor video into unique script
   - Audience retention curve optimization

4. **Optimization** (read `youtube/optimizer.md`)
   - Title variants with CTR signals
   - Tag generation (primary + long-tail + competitor)
   - SEO-optimized descriptions
   - Thumbnail analysis and generation brief

5. **Pipeline** (read `youtube/pipeline.md`)
   - Automated daily/weekly research via cron
   - Each phase runs as isolated worker (no context overflow)
   - Results persist in memory across sessions

## Related Agents

| Agent | When to Use |
|-------|-------------|
| `seo.md` | Deep keyword research, SERP analysis, backlink data |
| `content.md` | General content writing, SEO optimization |
| `video.md` | Video production (Remotion, Higgsfield, HeyGen) |
| `research.md` | Broad web research beyond YouTube |
| `social-media.md` | Cross-platform promotion strategy |
