---
description: "Writing production - scripts, copy, captions for multi-channel content"
mode: subagent
model: sonnet
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

# Writing Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Production-ready writing for scripts, copy, and captions across all content formats
- **Scope**: Long-form scripts, short-form scripts, blog posts, social copy, captions/subtitles
- **Integration**: Bridges story.md (narrative design) → production (execution) → distribution (platform adaptation)

**When to Use**: Read this when you need to produce actual written content from story frameworks and narrative designs.

**Key Principles**:
- Hook-first structure (first 3-8 seconds determine success)
- Platform-native formatting (each channel has unique conventions)
- Dialogue pacing (8-second chunks for AI video, word count = delivery speed)
- Caption optimization (readability, timing, accessibility)
- SEO integration (references seo/ for search-optimized content)

<!-- AI-CONTEXT-END -->

## Long-Form Script Structure

For YouTube videos, podcasts, webinars, and educational content (5+ minutes).

### Scene-by-Scene Format

```markdown
## [Video Title]

**Target length**: [X minutes / Y words]
**Framework**: [from content/story.md]
**Primary keyword**: [from content/research.md]

---

### [00:00] HOOK (0-30 seconds)

**Script**:
[Hook text using one of the 7 hook formulas from story.md]

**Delivery notes**:
- Pace: [fast/medium/slow]
- Tone: [urgent/conversational/authoritative]
- Emphasis: [key words to stress]

**B-roll directions**:
- [Visual description for 0-10s]
- [Visual description for 10-20s]
- [Visual description for 20-30s]

---

### [00:30] INTRO (30-60 seconds)

**Script**:
[Context + roadmap + stakes]

**Delivery notes**:
[Pacing and tone guidance]

**B-roll directions**:
[Visual descriptions with timestamps]

---

### [01:00] Section 1: [Title]

**Script**:
[Content for this section]

**Pattern interrupt** (at 2:30):
[Curiosity gap / story pivot / direct address]

**B-roll directions**:
[Visual descriptions]

---

[... continue sections ...]

---

### [XX:XX] CTA (final 30 seconds)

**Script**:
[Specific, content-related CTA - not generic]

**Delivery notes**:
[Tone: grateful, inviting, specific]

**B-roll directions**:
[End screen elements, subscribe animation]
```

### Dialogue Pacing Rules

**8-second chunk rule** (for AI video generation):

- 8 seconds = 12-15 words = 20-25 syllables
- More words = faster delivery (AI models speed up to fit)
- Fewer words = slower, more deliberate pacing
- Use punctuation for natural pauses (comma = 0.3s, period = 0.5s, ellipsis = 0.8s)

**Example pacing**:

```text
SLOW (8 words in 8 seconds):
"This changes everything. Let me show you why."

MEDIUM (12 words in 8 seconds):
"This changes everything about how we approach content creation. Here's why."

FAST (18 words in 8 seconds):
"This completely changes everything about how we approach content creation, and I'm going to show you exactly why in the next 60 seconds."
```

### B-Roll Direction Format

Be specific enough for video editors or AI video generation:

```text
[00:15-00:22] CLOSE-UP: Hands typing on keyboard, shallow depth of field, 
warm lighting from left, camera slowly pushes in. Product logo visible 
on laptop lid.

[00:22-00:30] WIDE SHOT: Full workspace overview, overhead angle, 
organized desk with notebook, coffee cup, plant in background. 
Natural window light.

[00:30-00:38] SCREEN RECORDING: Dashboard interface, cursor highlights 
key metrics, smooth zoom to specific data point. Clean, professional UI.
```

**References**: For AI video generation, see `tools/video/video-prompt-design.md` for detailed prompt structure.

## Short-Form Script Structure

For TikTok, Reels, Shorts, and social video (15-90 seconds).

### Hook-First Constraint

Short-form lives or dies in the first 3 seconds. Structure:

```markdown
## [Short-Form Title]

**Platform**: [TikTok/Reels/Shorts/LinkedIn]
**Duration**: [15s/30s/60s/90s]
**Aspect ratio**: 9:16 (vertical)

---

### [0-3s] HOOK

**Visual**: [What's on screen - must be pattern interrupt]
**Text overlay**: [Large, readable text - 3-6 words max]
**Voiceover**: [Hook line - 6-12 words]

---

### [3-15s] BODY

**Visual**: [Scene description]
**Text overlay**: [Key point 1]
**Voiceover**: [Explanation - 15-25 words]

[Cut]

**Visual**: [Scene description]
**Text overlay**: [Key point 2]
**Voiceover**: [Explanation - 15-25 words]

[Cut]

**Visual**: [Scene description]
**Text overlay**: [Key point 3]
**Voiceover**: [Explanation - 15-25 words]

---

### [15-18s] CTA

**Visual**: [Face to camera or product shot]
**Text overlay**: [CTA - "Follow for more" / "Link in bio" / "Save this"]
**Voiceover**: [CTA line - 5-8 words]
```

### Short-Form Pacing

**1-3 second cuts** (fast retention):

- Each scene = 1 distinct point
- Cut before viewer's attention wanes
- Visual variety every 2-3 seconds (angle change, zoom, B-roll insert)
- Text overlays sync with voiceover (appear on key words)

**Platform-specific timing**:

| Platform | Optimal Length | Cut Frequency |
|----------|---------------|---------------|
| TikTok | 15-30s | 1-2s cuts |
| Instagram Reels | 30-60s | 2-3s cuts |
| YouTube Shorts | 30-60s | 2-3s cuts |
| LinkedIn | 60-90s | 3-5s cuts |

## Blog Post SEO Structure

For search-optimized written content. **References**: `seo/` for detailed SEO strategy.

### Standard Blog Format

```markdown
# [H1: Primary Keyword + Benefit]

**Meta description** (150-160 chars):
[Compelling summary with primary keyword, includes CTA]

---

## Introduction (100-150 words)

[Hook paragraph - problem or question]

[Context paragraph - why this matters]

[Roadmap paragraph - what this post covers]

**Primary keyword density**: 1-2% (natural placement)

---

## [H2: Secondary Keyword + Specific Topic]

[Content paragraph 1 - 100-150 words]

[Content paragraph 2 - 100-150 words]

### [H3: Long-tail Keyword Variation]

[Detailed explanation - 150-200 words]

**Internal link**: [Link to related content on your site]
**External link**: [Link to authoritative source]

---

## [H2: Secondary Keyword + Specific Topic]

[Content continues...]

---

## Conclusion (100-150 words)

[Summary of key points]

[Actionable next step]

[CTA - newsletter signup, related content, product link]

---

## FAQ Section (optional, great for featured snippets)

### [Question with long-tail keyword]?

[Concise answer - 40-60 words]

### [Question with long-tail keyword]?

[Concise answer - 40-60 words]
```

### SEO Writing Rules

1. **Keyword placement**:
   - H1: Primary keyword near the beginning
   - First paragraph: Primary keyword in first 100 words
   - H2s: Secondary keywords and variations
   - H3s: Long-tail keyword variations
   - Conclusion: Primary keyword once

2. **Readability**:
   - Paragraphs: 2-4 sentences max
   - Sentences: 15-20 words average
   - Subheadings: Every 200-300 words
   - Lists and tables: Break up text walls

3. **Internal linking**:
   - 3-5 internal links per 1000 words
   - Descriptive anchor text (not "click here")
   - Link to pillar content and related posts

4. **External linking**:
   - 1-2 authoritative external links per 1000 words
   - Link to studies, data sources, tools
   - Opens in new tab (user experience)

**References**: See `seo/content-optimization.md` for detailed SEO guidelines.

## Social Media Copy Patterns

Platform-native copy for X (Twitter), LinkedIn, Reddit, Facebook, Instagram.

### X (Twitter) Thread Structure

**Character limit**: 280 per tweet

```markdown
1/ [HOOK TWEET]
Bold claim or question that stops the scroll.
No hashtags in first tweet (algorithm penalty).

2/ [CONTEXT]
Why this matters. Set up the problem or opportunity.

3/ [POINT 1]
First key insight. One idea per tweet.

4/ [POINT 2]
Second key insight. Use line breaks for readability.

5/ [POINT 3]
Third key insight. Visual variety (quote, stat, example).

6/ [PROOF]
Data, screenshot, or testimonial. Show, don't just tell.

7/ [SYNTHESIS]
What this means. Connect the dots.

8/ [CTA]
Specific action: "Retweet if this helped" / "Follow for more on [topic]"
Optional: Link to full content (blog, video, product)

---

**Thread best practices**:
- First tweet: No links, no hashtags (maximize reach)
- Line breaks: Double space for readability
- Visuals: 1-2 images or videos in thread (not every tweet)
- Hashtags: Max 1-2, only in final tweet
- Mentions: Tag relevant accounts in replies, not main thread
```

### LinkedIn Article/Post Structure

**Character limit**: 3000 (but 150-200 words is optimal for feed visibility)

```markdown
[HOOK PARAGRAPH]
Start with a story, question, or contrarian statement.
Professional tone but conversational.

[CONTEXT PARAGRAPH]
Why this matters in a business context.
Connect to reader's professional pain points.

[KEY INSIGHT 1]
→ Use bullet points or arrows for scannability
→ One idea per line
→ Professional but not corporate-speak

[KEY INSIGHT 2]
→ Data or examples
→ Specific, actionable
→ Relevant to target audience

[SYNTHESIS PARAGRAPH]
What this means for your career/business/industry.

[CTA]
What do you think? [Specific question to drive comments]
Or: [Link to full article/resource]

---

**LinkedIn best practices**:
- First 2 lines: Hook (visible before "see more")
- Paragraphs: 1-2 sentences max
- Emojis: Minimal, professional context only
- Hashtags: 3-5 relevant, at the end
- Mentions: Tag people/companies when relevant
- Visuals: Document carousels perform best
```

### Reddit Native Post Structure

**Subreddit-specific**: Always read subreddit rules and top posts first.

```markdown
# [Title: Specific, Descriptive, No Clickbait]

[CONTEXT PARAGRAPH]
Why you're posting this. Establish credibility without bragging.
"I've been working on [topic] for [time] and wanted to share..."

[MAIN CONTENT]
Use Reddit markdown:
- **Bold** for emphasis
- *Italics* for quotes or secondary emphasis
- `Code blocks` for technical content
- > Blockquotes for highlighting

Break into sections with headers:

## Section 1: [Descriptive Title]

[Content - be thorough, Reddit rewards depth]

## Section 2: [Descriptive Title]

[Content - include examples, data, screenshots]

## TL;DR (at the end, not the beginning)

[2-3 sentence summary of key points]

---

**Reddit best practices**:
- Tone: Community-native, not promotional
- Length: Longer posts perform better (500-1000 words common)
- Formatting: Use all markdown features for readability
- Links: Explain why you're linking, don't just drop URLs
- Self-promotion: Follow 10:1 rule (10 helpful posts per 1 promotional)
- Engagement: Reply to every comment in first 2 hours
```

### Instagram Caption Structure

**Character limit**: 2200 (but first 125 chars are critical - visible before "more")

```markdown
[HOOK LINE - First 125 characters]
This must work standalone. Stop the scroll. Make them tap "more".

[CONTEXT PARAGRAPH]
Expand on the hook. Why this matters.

[MAIN CONTENT]
Use line breaks for readability.

One idea per paragraph.

Emojis for visual breaks 👇

But don't overdo it.

[CTA]
Specific action: "Save this for later" / "Tag someone who needs this" / "Link in bio for full guide"

.
.
.
[Hashtags - 20-30, mix of sizes]
#PrimaryKeyword #SecondaryKeyword #NicheHashtag #BroadHashtag
[Continue hashtags...]

---

**Instagram best practices**:
- First line: Hook that works without image context
- Line breaks: Use periods or dashes on separate lines for spacing
- Hashtags: At the end, after line breaks (cleaner look)
- CTA: One clear action, not multiple asks
- Length: 150-300 words is optimal (long enough for value, short enough to read)
```

## Caption/Subtitle Optimization

For video captions, subtitles, and accessibility.

### Readability Rules

**Character limits per line**:

- **Optimal**: 32-42 characters per line
- **Maximum**: 68 characters per line (readability drops after this)
- **Lines on screen**: 1-2 lines max at a time

**Timing**:

- **Minimum duration**: 1 second per caption
- **Reading speed**: 17-20 characters per second (average adult)
- **Sync**: Caption appears 0.1s before audio, disappears 0.1s after

### Caption Format Examples

**Single-line captions** (short-form video):

```text
[00:00:00.000 --> 00:00:02.500]
This changes everything.

[00:00:02.500 --> 00:00:05.000]
Let me show you why.

[00:00:05.000 --> 00:00:08.500]
Most people get this completely wrong.
```

**Two-line captions** (long-form video):

```text
[00:00:00.000 --> 00:00:03.500]
This changes everything about
how we approach content creation.

[00:00:03.500 --> 00:00:07.000]
And I'm going to show you exactly why
in the next 60 seconds.
```

### Accessibility Best Practices

**Required elements**:

- Speaker identification: `[SPEAKER NAME]: Dialogue`
- Sound effects: `[SOUND: Door slams]`
- Music cues: `[MUSIC: Upbeat electronic]`
- Tone indicators: `[Sarcastic]`, `[Whispers]`, `[Shouting]`
- Non-speech sounds: `[Laughter]`, `[Applause]`, `[Sighs]`

**Example with full accessibility**:

```text
[00:00:00.000 --> 00:00:02.500]
[MUSIC: Upbeat intro]

[00:00:02.500 --> 00:00:05.000]
SARAH: This changes everything.

[00:00:05.000 --> 00:00:07.500]
[Excited] Let me show you why.

[00:00:07.500 --> 00:00:10.000]
[SOUND: Keyboard typing]

[00:00:10.000 --> 00:00:13.500]
Most people get this completely wrong.
```

### Platform-Specific Caption Styles

| Platform | Style | Characteristics |
|----------|-------|----------------|
| **TikTok** | Auto-captions | Large, bold, center-screen, word-by-word highlight |
| **Instagram Reels** | Manual overlays | Text stickers, animated, colorful, positioned creatively |
| **YouTube** | Standard subtitles | Bottom-center, white text on black background, professional |
| **LinkedIn** | Professional captions | Clean, minimal, high contrast, corporate-friendly |
| **Accessibility (SRT)** | Full descriptive | Speaker IDs, sound effects, tone indicators |

### Caption Generation Workflow

```bash
# 1. Extract audio from video
ffmpeg -i video.mp4 -vn -acodec pcm_s16le audio.wav

# 2. Generate transcript (use speech-to-text tool)
# See tools/voice/speech-to-speech.md for voice pipeline

# 3. Format as captions with timing
# Manual: Use caption editor (YouTube Studio, Descript, etc.)
# Automated: Use AI caption tools with manual review

# 4. Optimize for readability
# - Break at natural pauses
# - Keep lines balanced (similar length)
# - Sync with speaker's cadence

# 5. Add accessibility elements
# - Speaker IDs
# - Sound effects
# - Tone indicators

# 6. Export in platform format
# - SRT for YouTube, Vimeo
# - VTT for web players
# - Burned-in for TikTok, Reels
```

## Workflow: From Story to Script

Integration with `content/story.md` narrative frameworks.

### Step 1: Gather Story Elements

From `content/story.md`, you have:

- Hook formula (which of the 7 types)
- Storytelling framework (AIDA, Three-Act, Hero's Journey, etc.)
- Angle (pain vs aspiration, contrarian, transformation)
- Key beats (story arc moments)

### Step 2: Choose Script Format

| Content Type | Script Format | Length |
|-------------|---------------|--------|
| YouTube video | Long-form scene-by-scene | 1000-2000 words |
| YouTube Short | Short-form hook-first | 100-150 words |
| TikTok | Short-form hook-first | 75-125 words |
| Blog post | SEO blog structure | 1500-2500 words |
| X thread | Thread structure | 200-400 words |
| LinkedIn post | Article structure | 150-300 words |

### Step 3: Write the Script

**Prompt pattern for AI-assisted writing**:

> Write a [format] script for the topic: [topic]
>
> **Story framework**: [from story.md]
> **Hook formula**: [from story.md]
> **Angle**: [from story.md]
> **Target audience**: [from research.md]
> **Platform**: [YouTube/TikTok/Blog/etc.]
> **Target length**: [X words]
>
> Requirements:
> 1. Hook must use [formula] format from story.md
> 2. Follow [framework] storytelling structure
> 3. Include [specific elements based on format]
> 4. Maintain [tone/voice] throughout
> 5. End with [specific CTA]
>
> Unique angle: [from research.md]
> Avoid these competitor angles: [from research.md]

### Step 4: Add Production Details

**For video scripts**:

- Add B-roll directions (scene-by-scene)
- Add delivery notes (pacing, tone, emphasis)
- Add pattern interrupts (every 2-3 minutes)
- Add visual cues (graphics, text overlays, transitions)

**For written content**:

- Add SEO elements (keywords, internal links, meta description)
- Add formatting (headings, lists, tables, blockquotes)
- Add visual breaks (images, infographics, embedded media)

**For captions**:

- Add timing (sync with audio)
- Add accessibility elements (speaker IDs, sound effects)
- Add platform-specific styling

### Step 5: Review Checklist

| Element | Check |
|---------|-------|
| **Hook** | Does it stop the scroll in first 3-8 seconds? |
| **Framework** | Does it follow the chosen storytelling structure? |
| **Pacing** | Are dialogue chunks appropriate for format (8s for video)? |
| **Platform** | Is it formatted for the target platform's conventions? |
| **CTA** | Is the CTA specific and content-related? |
| **Accessibility** | Are captions readable and accessible? |
| **SEO** (if applicable) | Are keywords naturally placed? |
| **B-roll** (if video) | Are visual directions specific enough? |

## Memory Integration

```bash
# Store successful script patterns
memory-helper.sh store --type SUCCESS_PATTERN --namespace content-writing \
  "Script for [topic] using [format]. Hook: [type]. Framework: [name]. \
   Performance: [metrics if available]."

# Store platform-specific voice
memory-helper.sh store --type WORKING_SOLUTION --namespace content-writing \
  "Platform: [name]. Tone: [description]. Length: [optimal]. \
   CTA style: [description]. Avoid: [list]."

# Recall patterns for new scripts
memory-helper.sh recall --namespace content-writing "script patterns"
```

## Composing with Other Tools

| Tool | Integration |
|------|-------------|
| `content/story.md` | Provides narrative frameworks and hooks for scripts |
| `content/research.md` | Provides audience insights and competitor angles |
| `content/production/audio.md` | Voice pipeline for script delivery |
| `content/production/video.md` | AI video generation from scripts |
| `content/distribution/youtube/` | YouTube-specific script optimization |
| `content/distribution/short-form.md` | Short-form platform adaptations |
| `content/distribution/social.md` | Social media copy variations |
| `content/distribution/blog.md` | Blog post SEO optimization |
| `seo/` | SEO strategy for written content |
| `tools/voice/speech-to-speech.md` | Voice cloning and delivery |
| `tools/video/video-prompt-design.md` | AI video prompt structure |

## Related

- `content/story.md` — Narrative design and hooks
- `content/research.md` — Audience research and angles
- `content/production/audio.md` — Voice pipeline
- `content/production/video.md` — AI video generation
- `content/distribution/` — Platform-specific distribution
- `seo/` — SEO optimization
- `youtube/script-writer.md` — YouTube-specific scripting (will migrate to content/distribution/youtube/)
