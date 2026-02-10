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
- **Success Metrics**: Downloads, listen-through rate, subscriber growth, reviews

**Critical Rules**:

- **Audio quality is non-negotiable** - Bad audio = instant skip (use voice pipeline)
- **Hook in first 30 seconds** - State the value proposition immediately
- **Show notes are SEO content** - Treat them as blog posts with timestamps
- **Consistency beats quality** - Regular schedule matters more than production value
- **Repurpose everything** - Every podcast episode feeds 5+ other channels

**Voice Pipeline** (from `content/production/audio.md`):

1. CapCut AI voice cleanup (normalize accents, remove artifacts)
2. ElevenLabs transformation (voice cloning or style transfer)
3. NEVER publish raw AI audio - always process through the pipeline

<!-- AI-CONTEXT-END -->

## Episode Types

### Solo Episode (15-30 minutes)

**Purpose**: Share expertise, frameworks, and insights directly.

**Structure**:

1. **Cold open** (0-30s) - Hook with the episode's key insight or bold claim
2. **Intro** (30s-1m) - Show name, episode number, what the listener will learn
3. **Context** (1-3m) - Why this topic matters now, who it's for
4. **Body** (10-20m) - 3-5 main points with examples and stories
5. **Summary** (1-2m) - Key takeaways in bullet form
6. **CTA** (30s) - Subscribe, review, visit link, join community

**Content Adaptation from Pipeline**:

```text
Story: "Why 95% of AI influencers fail"

Solo Episode Outline:
[0:00] "95% of AI influencers will fail this year. I spent 6 months
       studying why. Here are the 5 mistakes they're all making."

[0:30] "Welcome to [Show Name], episode [X]. I'm [Name], and today
       we're breaking down what separates the 5% who succeed in AI
       content from the 95% who don't."

[1:00] Context: The AI content gold rush, why everyone's jumping in,
       and why most will fail.

[3:00] Mistake 1: Chasing tools instead of problems
       - Example: Sora 2 demos vs solving video production pain
       - What the top creators do instead

[8:00] Mistake 2: Publishing unedited AI content
       - Why audiences can always tell
       - The editing workflow that works

[13:00] Mistake 3: Ignoring audience research
        - The 30-Minute Expert Method
        - Reddit as a goldmine for audience insights

[18:00] Mistake 4: No testing or optimization
        - The 10-variant rule
        - A/B testing discipline

[22:00] Mistake 5: One-off posts instead of systems
        - The multi-media multiplier
        - Building repeatable content systems

[26:00] Summary: "If you take one thing from this episode..."

[27:00] CTA: "Subscribe, leave a review, and check the show notes
        for the full framework breakdown."
```

### Interview Episode (30-60 minutes)

**Structure**:

1. **Cold open** (0-30s) - Best quote or insight from the guest
2. **Intro** (30s-2m) - Guest introduction, why they're on the show
3. **Background** (2-5m) - Guest's story and credibility
4. **Core discussion** (20-40m) - 5-7 prepared questions with follow-ups
5. **Rapid fire** (3-5m) - Quick questions for personality and variety
6. **Guest CTA** (1m) - Where to find the guest
7. **Host CTA** (30s) - Subscribe, review, next episode preview

**Interview Prep**:

- Research guest's recent content, interviews, and social posts
- Prepare 7-10 questions (use 5-7, save rest for follow-ups)
- Identify 2-3 unique angles not covered in other interviews
- Send guest a brief with topic areas (not exact questions)

### Repurposed Video Episode

**Purpose**: Extract audio from YouTube videos for podcast distribution.

**Workflow**:

1. **Extract audio** from YouTube video using `yt-dlp-helper.sh`
2. **Process through voice pipeline** (`content/production/audio.md`)
3. **Add podcast intro/outro** (pre-recorded bumpers)
4. **Edit for audio-only** - Remove visual references ("as you can see...")
5. **Generate show notes** with timestamps
6. **Publish** to podcast platforms

### Mini-Episode (5-10 minutes)

**Purpose**: Quick tips, news commentary, or single-concept deep dives.

**Structure**:

1. **Hook** (0-15s) - One sentence value proposition
2. **Content** (3-8m) - Single topic, actionable advice
3. **CTA** (15-30s) - Quick subscribe reminder

**Best For**: Daily or 3x/week publishing cadence, building consistency.

## Show Notes

### Show Notes as SEO Content

Show notes are not just episode summaries - they're SEO-optimized blog posts that drive organic traffic to your podcast.

**Structure**:

1. **Title** - Episode number + keyword-optimized title
2. **Meta description** - 150-160 chars with primary keyword
3. **Summary** (100-150 words) - What the episode covers and who it's for
4. **Key takeaways** - 5-7 bullet points
5. **Timestamps** - Clickable chapter markers
6. **Transcript** (optional) - Full or partial, keyword-rich
7. **Resources mentioned** - Links to tools, articles, people
8. **CTA** - Subscribe links for all platforms

**Example Show Notes**:

```markdown
# Episode 47: Why 95% of AI Influencers Fail (And How to Be in the 5%)

After studying 50 AI content creators for 6 months, I identified the
5 critical mistakes that separate the failures from the successes.

## Key Takeaways

- Chasing tools instead of solving audience problems is the #1 killer
- AI-generated content must be edited ruthlessly before publishing
- The 30-Minute Expert Method for audience research
- Test 10 variants before committing to any approach
- Build systems, not one-off viral attempts

## Timestamps

- 0:00 - Introduction
- 3:00 - Mistake 1: Chasing tools instead of problems
- 8:00 - Mistake 2: Publishing unedited AI content
- 13:00 - Mistake 3: Ignoring audience research
- 18:00 - Mistake 4: No testing or optimization
- 22:00 - Mistake 5: One-off posts instead of systems
- 26:00 - Summary and key takeaways

## Resources Mentioned

- [Sora 2 Pro](link) - AI video generation
- [The 30-Minute Expert Method](link) - Audience research framework
- [Content Optimization Guide](link) - A/B testing discipline

## Subscribe

- [Apple Podcasts](link)
- [Spotify](link)
- [YouTube](link)
- [RSS Feed](link)
```

## Audio Production

### Recording Setup

**Minimum Quality**:

- USB condenser microphone (Audio-Technica AT2020 or similar)
- Quiet room with soft surfaces (reduce echo)
- Pop filter
- Headphones for monitoring

**AI-Generated Audio** (from `content/production/audio.md`):

1. **Script** from `content/production/writing.md`
2. **CapCut AI voice cleanup** - Normalize and clean
3. **ElevenLabs transformation** - Voice clone or style transfer
4. **Post-processing** - LUFS normalization, noise gate, compression

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

### Podcast Hosting

**Hosting Platform** (choose one):

- **Buzzsprout** - Beginner-friendly, good analytics
- **Transistor** - Multiple shows, team features
- **Podbean** - Monetization built-in
- **Anchor/Spotify for Podcasters** - Free, Spotify-native

### Platform Syndication

Submit RSS feed to all major platforms:

| Platform | Submission | Notes |
|----------|-----------|-------|
| **Apple Podcasts** | Podcasts Connect | 24-48h review |
| **Spotify** | Spotify for Podcasters | Near-instant |
| **Google Podcasts** | Google Podcasts Manager | Auto-indexed from RSS |
| **Amazon Music** | Amazon Music for Podcasters | 24-48h review |
| **Overcast** | Auto-indexed from Apple | No submission needed |
| **Pocket Casts** | Auto-indexed | No submission needed |
| **YouTube** | Upload as video or use RSS | Requires video or static image |

### Publishing Cadence

| Cadence | Best For | Effort Level |
|---------|----------|-------------|
| **Daily** (mini-episodes) | News, tips, building habit | High (batch record) |
| **3x/week** | Rapid growth, niche authority | Medium-high |
| **Weekly** | Sustainable, quality-focused | Medium |
| **Bi-weekly** | Side project, interview-heavy | Low-medium |

## Cross-Channel Repurposing

From one podcast episode, generate:

| Output | Channel | How |
|--------|---------|-----|
| **Audiogram clips** (30-60s) | Short-form (`content/distribution/short-form.md`) | Extract best quotes, add waveform visual |
| **Blog post** | Blog (`content/distribution/blog.md`) | Expand show notes into full article |
| **Social quotes** | Social (`content/distribution/social.md`) | Key insights as X posts, LinkedIn quotes |
| **Newsletter feature** | Email (`content/distribution/email.md`) | Episode summary + key takeaway |
| **YouTube video** | YouTube (`content/distribution/youtube/`) | Record video version or add static image |
| **Transcript** | Blog/SEO | Full transcript as long-form SEO content |

### Audiogram Production

**For short-form distribution**:

1. Extract 30-60s audio clip (best quote or insight)
2. Add waveform visualization or static image
3. Add captions (80%+ watch without sound on social)
4. Format 9:16 for TikTok/Reels/Shorts
5. Format 1:1 for X and LinkedIn

## Analytics and Growth

### Key Metrics

| Metric | Target | Action if Below |
|--------|--------|----------------|
| **Downloads per episode** | Growing month-over-month | Improve titles, promote more |
| **Listen-through rate** | 60%+ | Improve content structure, tighter editing |
| **Subscriber growth** | 5%+ month-over-month | Cross-promote, guest appearances |
| **Reviews** | 4.5+ stars | Ask for reviews in CTA, improve quality |
| **Website traffic from show notes** | Growing | Improve SEO, add more links |

### Growth Strategies

1. **Guest appearances** on other podcasts (fastest growth lever)
2. **Cross-promotion** with complementary shows
3. **Audiogram clips** on social media
4. **SEO-optimized show notes** for organic discovery
5. **Email newsletter** featuring episodes
6. **YouTube** video versions for discoverability
7. **Community building** (Discord, Slack, or forum)

## Related Agents and Tools

**Content Pipeline**:

- `content/research.md` - Audience research and niche validation
- `content/story.md` - Hook formulas and narrative design
- `content/production/audio.md` - Voice pipeline and audio production
- `content/production/writing.md` - Script writing
- `content/optimization.md` - A/B testing and analytics loops

**Distribution Channels**:

- `content/distribution/youtube/` - Long-form YouTube content
- `content/distribution/short-form.md` - TikTok, Reels, Shorts
- `content/distribution/social.md` - X, LinkedIn, Reddit
- `content/distribution/blog.md` - SEO-optimized articles
- `content/distribution/email.md` - Newsletters and sequences

**Tools**:

- `tools/voice/speech-to-speech.md` - Voice cloning and transformation
- `content/production/audio.md` - Audio production pipeline
- `youtube-helper.sh` - YouTube upload for video versions
