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
- **Key Principle**: Audio-first — content must work without visuals
- **Metrics**: Downloads, listen-through rate, subscriber growth, reviews

**Critical Rules**:

- **Audio quality is non-negotiable** — bad audio = instant skip
- **Hook in first 30 seconds** — state the value proposition immediately
- **Show notes are SEO content** — treat them as blog posts with timestamps
- **Consistency beats quality** — regular schedule > production value
- **Repurpose everything** — every episode feeds 5+ other channels

**Voice Pipeline** (full details in `content/production-audio.md`):
CapCut AI voice cleanup → ElevenLabs transformation → NEVER publish raw AI audio

<!-- AI-CONTEXT-END -->

## Episode Types

**Solo (15-30 min)**: Cold open (0-30s hook) → Intro (show name, episode, what listener learns) → Context (1-3m, why now) → Body (10-20m, 3-5 points with examples) → Summary (key takeaways) → CTA (30s: subscribe, review, link).

**Interview (30-60 min)**: Cold open (best guest quote) → Guest intro + background (2-5m) → Core discussion (20-40m, 5-7 questions) → Rapid fire (3-5m) → Guest CTA + Host CTA. Prep: research recent content, prepare 7-10 questions (use 5-7), find 2-3 unique angles, send topic brief (not exact questions).

**Repurposed Video**: Extract audio via `yt-dlp-helper.sh` → voice pipeline (`content/production-audio.md`) → add bumpers → edit out visual references ("as you can see...") → generate show notes with timestamps → publish.

**Mini (5-10 min)**: Hook (0-15s, one sentence) → single topic with actionable advice → CTA (15-30s). Best for daily or 3x/week cadence.

## Show Notes

SEO-optimized blog posts, not summaries. Required structure:

1. **Title** — episode number + keyword-optimized title
2. **Meta description** — 150-160 chars with primary keyword
3. **Summary** (100-150 words) — what it covers and who it's for
4. **Key takeaways** — 5-7 bullet points
5. **Timestamps** — clickable chapter markers
6. **Transcript** (optional) — full or partial, keyword-rich
7. **Resources mentioned** — links to tools, articles, people
8. **CTA** — subscribe links for all platforms

## Audio Production

**Recording**: USB condenser mic (e.g. AT2020), quiet room with soft surfaces, pop filter, monitoring headphones.

**AI-generated audio**: Script (`content/production-writing.md`) → CapCut AI cleanup → ElevenLabs transformation → LUFS normalization, noise gate, compression.

**Specifications**:

| Parameter | Specification |
|-----------|--------------|
| **Format** | MP3 (192kbps) or AAC (128kbps) |
| **Sample rate** | 44.1kHz |
| **Channels** | Mono (solo), Stereo (interview/music) |
| **LUFS** | -16 LUFS (podcast standard) |
| **Bit depth** | 16-bit |
| **Silence** | 0.5s at start, 1s at end |

**Post-production checklist**: noise reduction → LUFS normalized to -16 → intro/outro bumpers → chapter markers → ID3 tags (title, artist, album, episode number, artwork) → show notes with timestamps → transcript (if applicable).

## Distribution and Syndication

**Hosting**: Buzzsprout (beginner-friendly, analytics), Transistor (multi-show, teams), Podbean (monetization), Anchor/Spotify for Podcasters (free, Spotify-native).

**Platform syndication** — submit RSS feed to:

| Platform | Notes |
|----------|-------|
| **Apple Podcasts** | Podcasts Connect, 24-48h review |
| **Spotify** | Spotify for Podcasters, near-instant |
| **YouTube Music** | Migrated from Google Podcasts, auto-indexed |
| **Amazon Music** | Amazon Music for Podcasters, 24-48h review |
| **Overcast** | Auto-indexed from Apple |
| **Pocket Casts** | Auto-indexed |
| **YouTube** | Upload as video or use RSS (requires video or static image) |

**Publishing cadence**:

| Cadence | Best For | Effort |
|---------|----------|--------|
| **Daily** (mini-episodes) | News, tips, building habit | High (batch record) |
| **3x/week** | Rapid growth, niche authority | Medium-high |
| **Weekly** | Sustainable, quality-focused | Medium |
| **Bi-weekly** | Side project, interview-heavy | Low-medium |

## Cross-Channel Repurposing

From one episode, generate:

| Output | Channel | How |
|--------|---------|-----|
| **Audiogram clips** (30-60s) | `content/distribution-short-form.md` | Extract best quotes, add waveform visual |
| **Blog post** | `content/distribution-blog.md` | Expand show notes into full article |
| **Social quotes** | `content/distribution-social.md` | Key insights as posts |
| **Newsletter feature** | `content/distribution-email.md` | Episode summary + key takeaway |
| **YouTube video** | `content/distribution-youtube/` | Record video version or add static image |
| **Transcript** | Blog/SEO | Full transcript as long-form SEO content |

**Audiogram**: Extract 30-60s clip → waveform/static image → captions (80%+ watch without sound) → 9:16 for TikTok/Reels/Shorts, 1:1 for X/LinkedIn.

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

**Content pipeline**: `content/research.md` (audience research), `content/story.md` (hooks/narrative), `content/production-audio.md` (voice pipeline), `content/production-writing.md` (scripts), `content/optimization.md` (A/B testing).

**Distribution**: `content/distribution-youtube/`, `content/distribution-short-form.md`, `content/distribution-social.md`, `content/distribution-blog.md`, `content/distribution-email.md`.

**Tools**: `tools/voice/speech-to-speech.md`, `youtube-helper.sh`.
