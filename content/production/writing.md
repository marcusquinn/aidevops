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

Generate scripts, copy, and captions optimized for different content formats and distribution channels. Covers long-form scripts, short-form scripts, blog posts, social media copy, and caption/subtitle optimization.

## When to Use

Read this subagent when you need to:

- Write long-form video scripts with scene-by-scene B-roll directions
- Create short-form scripts optimized for 60-second constraint
- Generate blog post content with SEO structure
- Write platform-specific social media copy
- Optimize captions and subtitles for accessibility and engagement
- Understand dialogue pacing for AI video generation

## Long-Form Script Structure

Long-form scripts (5+ minutes) require detailed scene breakdowns with visual directions.

### Format Template

```markdown
## [Video Title]

**Target length**: [X minutes]
**Format**: Long-form
**Platform**: [YouTube/Vimeo/etc.]

---

### Scene 1: [Scene Name] ([timestamp range])

**DIALOGUE**:
[Speaker dialogue with delivery notes]

**B-ROLL**:
- [Visual description 1]
- [Visual description 2]
- [Visual description 3]

**CAMERA**:
[Camera movement/angle notes]

**AUDIO**:
[Background music/SFX notes]

---

### Scene 2: [Scene Name] ([timestamp range])

[Repeat structure]

---

## Production Notes

**Key moments**: [List critical scenes that need special attention]
**Transitions**: [Notes on how scenes connect]
**Visual style**: [Overall aesthetic direction]
```

### Scene-by-Scene Breakdown

Each scene should specify:

| Element | Description |
|---------|-------------|
| **Dialogue** | Exact words spoken, with delivery notes (tone, pace, emphasis) |
| **B-roll** | Visual content shown while dialogue plays (3-5 specific shots) |
| **Camera** | Camera movement (static, pan, zoom, tracking) and angle |
| **Audio** | Background music cues, sound effects, ambient sound |
| **Duration** | Target length for the scene (helps with pacing) |

### B-Roll Direction Guidelines

Be specific with B-roll directions:

**Vague**: "Show the product"
**Specific**: "Close-up of hands unboxing the product, slow motion, natural lighting from left"

**Vague**: "City scenes"
**Specific**: "Wide shot of downtown skyline at golden hour, camera slowly panning right"

**Vague**: "Person working"
**Specific**: "Over-shoulder shot of person typing on laptop, shallow depth of field, focus on hands"

### Dialogue Pacing Rules

For AI video generation (Sora 2, Veo 3.1):

- **8-second chunks**: Break dialogue into 8-second segments maximum
- **More words = faster delivery**: AI models speed up delivery to fit words into video duration
- **Pause markers**: Use `[pause]` or `[beat]` to indicate natural breaks
- **Emphasis markers**: Use `*emphasis*` or `**strong emphasis**` for delivery cues

**Example**:

```text
WRONG:
"In this video I'm going to show you the three most important things you need to know about AI video generation and by the end you'll be able to create professional-quality videos in minutes."

RIGHT:
"In this video, I'm going to show you the three most important things about AI video generation."
[pause]
"By the end, you'll be creating professional-quality videos in minutes."
```

## Short-Form Script Structure

Short-form scripts (15-60 seconds) for TikTok, Reels, Shorts require hook-first structure with rapid pacing.

### Format Template

```markdown
## [Video Title]

**Target length**: [X seconds]
**Format**: Short-form
**Platform**: [TikTok/Reels/Shorts]
**Aspect ratio**: 9:16

---

### [0-3s] HOOK

**VISUAL**: [Opening shot - must be attention-grabbing]
**TEXT OVERLAY**: [On-screen text]
**DIALOGUE**: [First words - must stop the scroll]

---

### [3-15s] SETUP

**VISUAL**: [Scene description]
**TEXT OVERLAY**: [Supporting text]
**DIALOGUE**: [Context/problem statement]

---

### [15-45s] PAYOFF

**VISUAL**: [Main content scenes]
**TEXT OVERLAY**: [Key points as text]
**DIALOGUE**: [Solution/answer/reveal]

---

### [45-60s] CTA

**VISUAL**: [Closing shot]
**TEXT OVERLAY**: [Call to action]
**DIALOGUE**: [Final hook/CTA]

---

## Production Notes

**Hook type**: [Bold claim/Question/Story/etc.]
**Pacing**: [1-3 second cuts]
**Music**: [Trending sound or original]
```

### 60-Second Constraint

Short-form scripts must respect platform limits:

| Platform | Max Length | Optimal Length | Notes |
|----------|-----------|----------------|-------|
| TikTok | 10 minutes | 15-60 seconds | Algorithm favors <60s |
| Instagram Reels | 90 seconds | 15-30 seconds | Completion rate critical |
| YouTube Shorts | 60 seconds | 30-60 seconds | Hard 60s limit |
| Twitter/X | 2:20 | 30-60 seconds | Attention span drops after 30s |

### Hook-First Structure

The first 3 seconds determine 80% of retention. Hook formulas:

1. **Bold Claim**: "This $5 tool beats every $500 alternative"
2. **Question**: "Why do 90% of creators fail?"
3. **Story Drop**: "Three months ago, I had 47 views. Last week: 2 million."
4. **Contrarian**: "Everything you know about [topic] is wrong"
5. **Result**: "0 to 100K subscribers in 6 months. Here's how."
6. **Problem-Agitate**: "Your thumbnails are costing you views. The fix isn't what you think."
7. **Curiosity Gap**: "There's one setting 95% of creators never touch"

### Pacing for Short-Form

- **1-3 second cuts**: Change visual every 1-3 seconds to maintain attention
- **Text overlays**: Reinforce key points (many watch without sound)
- **Pattern interrupts**: Visual change, text pop, zoom, or transition every 5-7 seconds
- **No dead air**: Every second must deliver value or entertainment

## Blog Post SEO Structure

Blog posts require SEO optimization while maintaining readability.

### Standard Structure

```markdown
# [Primary Keyword in Title]

**Meta description**: [150-160 characters with primary keyword]
**Target keyword**: [primary keyword]
**Secondary keywords**: [keyword 2], [keyword 3], [keyword 4]

---

## Introduction (100-150 words)

- Hook with the problem or question
- Promise what the reader will learn
- Include primary keyword in first 100 words

---

## [H2: Secondary Keyword Topic 1]

### [H3: Specific Point]

[Content with keyword density 1-2%]

**Key takeaway**: [Summary box or callout]

---

## [H2: Secondary Keyword Topic 2]

### [H3: Specific Point]

[Content]

---

## [H2: Secondary Keyword Topic 3]

[Content]

---

## Conclusion

- Summarize key points
- Restate primary keyword
- Clear CTA (comment, share, subscribe, download)

---

## FAQ (Optional but recommended for SEO)

**Q: [Question with long-tail keyword]**
A: [Answer]

**Q: [Question with long-tail keyword]**
A: [Answer]
```

### SEO Writing Rules

| Element | Guideline |
|---------|-----------|
| **Title** | 50-60 characters, primary keyword at start |
| **Meta description** | 150-160 characters, primary keyword + CTA |
| **Keyword density** | 1-2% (natural, not stuffed) |
| **Headings** | H2/H3 with secondary keywords |
| **Internal links** | 3-5 links to related content |
| **External links** | 2-3 authoritative sources |
| **Images** | Alt text with keywords, compressed for speed |
| **Word count** | 1500-2500 words for competitive keywords |

**Reference**: See `seo/` subagents for detailed SEO optimization workflows.

## Social Media Copy Patterns

Each platform has distinct voice, format, and engagement patterns.

### X (Twitter) Thread Structure

```text
1/ [Hook tweet - bold claim or question]

2/ [Context - why this matters]

3/ [Point 1 with supporting detail]

4/ [Point 2 with supporting detail]

5/ [Point 3 with supporting detail]

6/ [Conclusion + CTA]

[Optional: 7/ [Link to full article/video]]
```

**X Writing Rules**:
- **Concise**: Every word must earn its place
- **Line breaks**: Use line breaks for readability (not wall of text)
- **Hooks**: First tweet determines thread performance
- **Numbers**: "3 ways" performs better than "some ways"
- **CTA**: Ask for engagement (reply, retweet, follow)

### LinkedIn Article Structure

```markdown
[Hook paragraph - personal story or bold claim]

[Context paragraph - why this matters professionally]

**Key insight 1**
[Explanation with professional example]

**Key insight 2**
[Explanation with professional example]

**Key insight 3**
[Explanation with professional example]

[Conclusion paragraph - actionable takeaway]

[CTA - comment with your experience, connect, share]

---
#hashtag1 #hashtag2 #hashtag3 (3-5 hashtags max)
```

**LinkedIn Writing Rules**:
- **Professional tone**: Casual but credible
- **Personal stories**: Vulnerability and authenticity perform well
- **Actionable**: Readers want takeaways they can use
- **Formatting**: Bold key points, use line breaks
- **Length**: 1200-2000 characters optimal (longer than X, shorter than blog)

### Reddit Native Copy

Reddit requires community-native tone and genuine value.

```markdown
**[Title: Specific, honest, no clickbait]**

[Opening: Acknowledge the community, establish credibility]

[Body: Detailed, helpful content with specifics]

**TL;DR**: [One-sentence summary]

---

[Optional: Edit to respond to top comments]
```

**Reddit Writing Rules**:
- **No self-promotion**: Lead with value, not links
- **Community-first**: Reference subreddit culture and rules
- **Detailed**: Reddit rewards depth over brevity
- **Honest**: Clickbait gets downvoted instantly
- **TL;DR**: Always include for long posts
- **Engage**: Reply to comments authentically

### Platform Comparison

| Platform | Tone | Length | Format | Engagement Driver |
|----------|------|--------|--------|-------------------|
| **X** | Concise, punchy | 280 chars/tweet | Thread or single | Controversy, insight, humor |
| **LinkedIn** | Professional, personal | 1200-2000 chars | Article-style | Career value, vulnerability |
| **Reddit** | Community-native, detailed | 500-2000 words | Long-form post | Genuine help, specificity |
| **Instagram** | Visual-first, casual | 125-150 chars | Caption + image | Emotion, aspiration |
| **Facebook** | Conversational, warm | 100-250 chars | Status + link | Community, relatability |

## Caption and Subtitle Optimization

Captions serve accessibility, SEO, and engagement.

### Caption Best Practices

**For Accessibility**:
- **Speaker identification**: `[Marcus]:` when multiple speakers
- **Sound effects**: `[upbeat music]`, `[door slams]`, `[laughter]`
- **Tone indicators**: `[sarcastically]`, `[whispers]`, `[excited]`
- **Timing**: Sync to speech rhythm, not just word boundaries

**For Engagement**:
- **Keyword-rich**: Include searchable terms naturally
- **Readable**: 1-2 lines on screen at once (not wall of text)
- **Emphasis**: Use CAPS or *italics* sparingly for key words
- **Emoji**: Use strategically for visual breaks (not excessive)

### Subtitle Formatting

```text
WRONG (too long, hard to read):
"In this video I'm going to show you the three most important things you need to know about AI video generation."

RIGHT (chunked for readability):
"In this video, I'm going to show you
the three most important things
you need to know about AI video generation."

BETTER (synced to natural speech pauses):
"In this video,"
"I'm going to show you the three most important things"
"you need to know about AI video generation."
```

### Platform-Specific Caption Rules

| Platform | Caption Style | Notes |
|----------|--------------|-------|
| **YouTube** | Full transcript | Auto-captions available, manual review recommended |
| **TikTok** | Auto-captions + text overlays | Auto-captions are accurate, add text for emphasis |
| **Instagram** | Manual captions | No auto-captions, use apps like Captions or CapCut |
| **LinkedIn** | Full transcript | Professional audience expects accuracy |
| **Facebook** | Auto-captions | Auto-captions available, quality varies |

### Caption File Formats

- **SRT** (SubRip): Most universal, supported everywhere
- **VTT** (WebVTT): Web standard, supports styling
- **SCC** (Scenarist): Broadcast standard, less common for web

**SRT Format Example**:

```srt
1
00:00:00,000 --> 00:00:03,000
In this video, I'm going to show you

2
00:00:03,000 --> 00:00:06,000
the three most important things
you need to know about AI video generation.
```

## Dialogue Pacing for AI Video

AI video models (Sora 2, Veo 3.1) have specific pacing requirements.

### 8-Second Chunk Rule

AI models generate video in segments. Keep dialogue chunks to 8 seconds maximum:

**Why**: Longer chunks cause:
- Faster delivery (AI speeds up speech to fit)
- Unnatural pacing
- Lip-sync issues
- Reduced emotional range

**Example**:

```text
WRONG (20 seconds):
"In today's video I'm going to walk you through the complete process of setting up your first AI video generation workflow from start to finish including all the tools you'll need and the exact prompts I use to get professional results every single time."

RIGHT (3 chunks, ~7 seconds each):
Chunk 1: "In today's video, I'm walking you through AI video generation from start to finish."
Chunk 2: "I'll show you the exact tools I use and the prompts that get professional results."
Chunk 3: "Let's dive in."
```

### More Words = Faster Delivery

AI models fit dialogue into the video duration by adjusting speech speed:

- **Sparse dialogue**: Slow, deliberate delivery
- **Dense dialogue**: Fast, rushed delivery

**Control pacing by word count**:

| Words per 8s | Delivery Speed | Use Case |
|--------------|----------------|----------|
| 10-15 words | Slow, dramatic | Emotional moments, emphasis |
| 15-25 words | Natural | Standard dialogue |
| 25-35 words | Fast | Energetic, exciting content |
| 35+ words | Rushed | Avoid (sounds unnatural) |

### Pause and Emphasis Markers

Use markers to control AI delivery:

```text
[pause] - 0.5-1 second pause
[beat] - 1-2 second pause
[long pause] - 2-3 second pause

*emphasis* - slight emphasis
**strong emphasis** - strong emphasis
***dramatic emphasis*** - dramatic emphasis

[whisper] - quiet delivery
[excited] - energetic delivery
[serious] - somber tone
```

**Example**:

```text
"This is the most important thing you need to know."
[pause]
"**Everything** else is secondary."
[beat]
"Let me show you why."
```

## Composing with Other Tools

| Tool | Integration |
|------|-------------|
| `content/story.md` | Story frameworks and hooks feed into script structure |
| `content/production/audio.md` | Voice pipeline and emotional cues for dialogue delivery |
| `content/production/video.md` | Video generation from completed scripts |
| `youtube/script-writer.md` | YouTube-specific script patterns (references this file) |
| `seo/` | SEO optimization for blog post structure |
| `tools/social-media/` | Platform-specific posting and formatting |

## Workflow: Generate Multi-Format Copy

Given one core message, generate copy for all distribution channels:

### Step 1: Define Core Message

```bash
# Store the core message in memory
memory-helper.sh store --namespace content \
  "Core message: [one-sentence summary of the key insight]"
```

### Step 2: Generate Long-Form Script

Use long-form structure (above) to create detailed video script with B-roll directions.

### Step 3: Extract Short-Form Variants

From the long-form script, extract:
- **Hook** → Short-form opening (3 seconds)
- **Key insight 1** → Short-form middle (15 seconds)
- **Conclusion** → Short-form CTA (5 seconds)

### Step 4: Adapt for Blog

Transform script into blog post:
- **Hook** → Introduction paragraph
- **Scene 1-3** → H2 sections with details
- **Conclusion** → Conclusion paragraph + FAQ

### Step 5: Create Social Copy

From blog post, extract:
- **Title + intro** → X thread hook
- **H2 sections** → X thread points 2-4
- **Conclusion** → X thread final tweet
- **Expand intro** → LinkedIn article opening
- **Add personal story** → LinkedIn vulnerability
- **Add detail** → Reddit long-form post

### Step 6: Generate Captions

From video script dialogue, create:
- **SRT file** for YouTube
- **Text overlays** for TikTok/Reels
- **Accessibility captions** with sound effects and tone

## Memory Integration

```bash
# Store successful copy patterns
memory-helper.sh store --type SUCCESS_PATTERN --namespace content-writing \
  "Script structure for [topic] using [format]. \
   Hook: [type], Length: [X seconds/minutes], Platform: [platform]. \
   Performance: [engagement metrics if available]."

# Store platform voice profiles
memory-helper.sh store --type WORKING_SOLUTION --namespace social-media \
  "Platform: [X/LinkedIn/Reddit]. Voice: [tone description]. \
   Optimal length: [X chars]. Engagement drivers: [list]."

# Recall voice for new copy
memory-helper.sh recall --namespace content-writing "script structure"
memory-helper.sh recall --namespace social-media "LinkedIn voice"
```

## Related

- `content/story.md` — Narrative design, hooks, angles, frameworks
- `content/production/audio.md` — Voice pipeline, emotional cues
- `content/production/video.md` — Video generation from scripts
- `content/distribution/youtube/` — YouTube-specific workflows
- `content/distribution/short-form.md` — TikTok/Reels/Shorts optimization
- `content/distribution/social.md` — Social media copy patterns
- `content/distribution/blog.md` — Blog post SEO structure
- `seo/` — SEO optimization workflows
- `tools/social-media/` — Platform-specific posting tools
