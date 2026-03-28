---
name: podcast
description: Podcast distribution - audio-first content, show notes, and syndication
mode: subagent
model: sonnet
---

# Podcast - Audio-First Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Distribute content as podcast episodes with show notes and syndication
- **Formats**: Solo episodes, interviews, repurposed video audio, mini-episodes
- **Key Principle**: Audio-first design - content must work without visuals
- **Metrics**: Downloads, listen-through rate, subscriber growth, reviews

**Critical Rules**:

- **Audio quality is non-negotiable** - Bad audio = instant skip
- **Hook in first 30 seconds** - State the value proposition immediately
- **Show notes are SEO content** - Treat them as blog posts with timestamps
- **Consistency beats quality** - Regular schedule > production value
- **Repurpose everything** - Every episode feeds 5+ other channels

**Voice Pipeline** (full details in `content/production/audio.md`):
CapCut AI voice cleanup → ElevenLabs transformation → NEVER publish raw AI audio

<!-- AI-CONTEXT-END -->

## Episode Types

### Solo Episode (15-30 minutes)

1. **Cold open** (0-30s) - Hook with key insight or bold claim
2. **Intro** (30s-1m) - Show name, episode number, what listener learns
3. **Context** (1-3m) - Why this topic matters now, who it's for
4. **Body** (10-20m) - 3-5 main points with examples and stories
5. **Summary** (1-2m) - Key takeaways in bullet form
6. **CTA** (30s) - Subscribe, review, visit link, join community

**Example adaptation** — "Why 95% of AI influencers fail":

```text
[0:00] Hook: "95% of AI influencers will fail this year. Here are the 5 mistakes."
[0:30] Intro: Show name, episode number, what separates the 5% who succeed
[1:00] Context: The AI content gold rush
[3:00-22:00] Body: 5 mistakes (chasing tools vs problems, publishing unedited AI,
             ignoring audience research, no testing/optimization, one-offs vs systems)
[26:00] Summary + [27:00] CTA
```

### Interview Episode (30-60 minutes)

1. **Cold open** (0-30s) - Best quote from the guest
2. **Intro** (30s-2m) - Guest introduction, why they're on the show
3. **Background** (2-5m) - Guest's story and credibility
4. **Core discussion** (20-40m) - 5-7 prepared questions with follow-ups
5. **Rapid fire** (3-5m) - Quick questions for personality and variety
6. **Guest CTA** (1m) + **Host CTA** (30s)

**Interview Prep**: Research guest's recent content. Prepare 7-10 questions (use 5-7). Identify 2-3 unique angles not covered elsewhere. Send guest a brief with topic areas (not exact questions).

### Repurposed Video Episode

Extract audio from YouTube videos for podcast distribution:

1. Extract audio via `yt-dlp-helper.sh`
2. Process through voice pipeline (`content/production/audio.md`)
3. Add podcast intro/outro bumpers
4. Edit for audio-only — remove visual references ("as you can see...")
5. Generate show notes with timestamps
6. Publish to podcast platforms

### Mini-Episode (5-10 minutes)

1. **Hook** (0-15s) - One sentence value proposition
2. **Content** (3-8m) - Single topic, actionable advice
3. **CTA** (15-30s) - Quick subscribe reminder

Best for daily or 3x/week cadence to build consistency.

## Show Notes

Show notes are SEO-optimized blog posts that drive organic traffic, not just summaries.

**Required structure**:

1. **Title** - Episode number + keyword-optimized title
2. **Meta description** - 150-160 chars with primary keyword
3. **Summary** (100-150 words) - What the episode covers and who it's for
4. **Key takeaways** - 5-7 bullet points
5. **Timestamps** - Clickable chapter markers
6. **Transcript** (optional) - Full or partial, keyword-rich
7. **Resources mentioned** - Links to tools, articles, people
8. **CTA** - Subscribe links for all platforms

## Audio Production

### Recording Setup

**Minimum**: USB condenser mic (e.g. AT2020), quiet room with soft surfaces, pop filter, monitoring headphones.

**AI-generated audio**: Script (`content/production/writing.md`) → CapCut AI cleanup → ElevenLabs transformation → LUFS normalization, noise gate, compression.

### Audio Specifications

| Parameter | Specification |
|-----------|--------------|
| **Format** | MP3 (192kbps) or AAC (128kbps) |
| **Sample rate** | 44.1kHz |
| **Channels** | Mono (solo), Stereo (interview/music) |
| **LUFS** | -16 LUFS (podcast standard) |
| **Bit depth** | 16-bit |
| **Silence** | 0.5s at start, 1s at end |

### Post-Production Checklist

- [ ] Noise reduction applied
- [ ] LUFS normalized to -16
- [ ] Intro/outro bumpers added
- [ ] Chapter markers set
- [ ] ID3 tags filled (title, artist, album, episode number, artwork)
- [ ] Show notes written with timestamps
- [ ] Transcript generated (if applicable)

## Distribution and Syndication

### Hosting Platforms

- **Buzzsprout** - Beginner-friendly, good analytics
- **Transistor** - Multiple shows, team features
- **Podbean** - Monetization built-in
- **Anchor/Spotify for Podcasters** - Free, Spotify-native

### Platform Syndication

Submit RSS feed to all major platforms:

| Platform | Notes |
|----------|-------|
| **Apple Podcasts** | Podcasts Connect, 24-48h review |
| **Spotify** | Spotify for Podcasters, near-instant |
| **YouTube Music** | Migrated from Google Podcasts, auto-indexed |
| **Amazon Music** | Amazon Music for Podcasters, 24-48h review |
| **Overcast** | Auto-indexed from Apple |
| **Pocket Casts** | Auto-indexed |
| **YouTube** | Upload as video or use RSS (requires video or static image) |

### Publishing Cadence

| Cadence | Best For | Effort |
|---------|----------|--------|
| **Daily** (mini-episodes) | News, tips, building habit | High (batch record) |
| **3x/week** | Rapid growth, niche authority | Medium-high |
| **Weekly** | Sustainable, quality-focused | Medium |
| **Bi-weekly** | Side project, interview-heavy | Low-medium |

## Cross-Channel Repurposing

From one podcast episode, generate:

| Output | Channel | How |
|--------|---------|-----|
| **Audiogram clips** (30-60s) | `content/distribution/short-form.md` | Extract best quotes, add waveform visual |
| **Blog post** | `content/distribution/blog.md` | Expand show notes into full article |
| **Social quotes** | `content/distribution/social.md` | Key insights as posts |
| **Newsletter feature** | `content/distribution/email.md` | Episode summary + key takeaway |
| **YouTube video** | `content/distribution/youtube/` | Record video version or add static image |
| **Transcript** | Blog/SEO | Full transcript as long-form SEO content |

**Audiogram production**: Extract 30-60s clip → add waveform/static image → add captions (80%+ watch without sound) → format 9:16 for TikTok/Reels/Shorts, 1:1 for X/LinkedIn.

## Analytics and Growth

| Metric | Target | Action if Below |
|--------|--------|----------------|
| **Downloads/episode** | Growing MoM | Improve titles, promote more |
| **Listen-through rate** | 60%+ | Tighter editing, better structure |
| **Subscriber growth** | 5%+ MoM | Cross-promote, guest appearances |
| **Reviews** | 4.5+ stars | Ask in CTA, improve quality |
| **Show notes traffic** | Growing | Improve SEO, add more links |

**Growth levers** (ordered by impact): Guest appearances on other podcasts → cross-promotion with complementary shows → audiogram clips on social → SEO-optimized show notes → email newsletter → YouTube video versions → community building (Discord/Slack/forum).

## Related

**Content pipeline**: `content/research.md` (audience research), `content/story.md` (hooks/narrative), `content/production/audio.md` (voice pipeline), `content/production/writing.md` (scripts), `content/optimization.md` (A/B testing).

**Distribution**: `content/distribution/youtube/`, `content/distribution/short-form.md`, `content/distribution/social.md`, `content/distribution/blog.md`, `content/distribution/email.md`.

**Tools**: `tools/voice/speech-to-speech.md`, `youtube-helper.sh`.
