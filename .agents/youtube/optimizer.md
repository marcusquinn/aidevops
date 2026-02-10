---
description: "YouTube optimizer - titles, tags, descriptions, hooks, and thumbnail analysis"
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

# YouTube Optimizer

Generate and optimize YouTube video metadata: titles, tags, descriptions, hooks, and thumbnail briefs. Uses CTR signals, keyword data, and competitor analysis to maximize discoverability and click-through rate.

## When to Use

Read this subagent when the user wants to:

- Generate title options for a video
- Create SEO-optimized tags
- Write a YouTube description with timestamps and links
- Generate hook variations for the first 30 seconds
- Analyze or brief a thumbnail design
- Optimize existing metadata for better performance

## Title Generation

### CTR Signal Checklist

High-performing YouTube titles use these signals:

| Signal | Example | Why It Works |
|--------|---------|-------------|
| **Number** | "7 Tools That..." | Sets expectations, implies structure |
| **Brackets** | "... [Full Guide]" | Adds context, increases CTR 33% |
| **Power word** | "Insane", "Secret", "Ultimate" | Triggers emotional response |
| **Question** | "Why Does...?" | Creates curiosity gap |
| **Year** | "... in 2026" | Signals freshness |
| **Negative** | "Stop Doing...", "Never..." | Loss aversion is powerful |
| **How-to** | "How to..." | Clear value proposition |
| **Comparison** | "X vs Y" | Implies a verdict/answer |
| **Personal** | "I Tried...", "My..." | Authenticity signal |
| **Specificity** | "$5", "30 Days", "100K" | Concrete > vague |

### Title Generation Workflow

```bash
# Get competitor titles for the same topic
youtube-helper.sh search "topic" video 20

# Get tags from top-performing videos
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const v = JSON.parse(d).items?.[0];
    console.log('Title:', v?.snippet?.title);
    console.log('Tags:', (v?.snippet?.tags || []).join(', '));
    console.log('Views:', v?.statistics?.viewCount);
});
"
```

**Prompt pattern for title generation**:

> Topic: [topic]
> Primary keyword: [keyword]
> Channel voice: [casual/formal/authoritative]
> Competitor titles for this topic:
> - [title 1] ([views] views)
> - [title 2] ([views] views)
> - [title 3] ([views] views)
>
> Generate 10 title options that:
> 1. Include the primary keyword naturally
> 2. Use at least 2 CTR signals from the checklist
> 3. Are 50-70 characters (optimal for display)
> 4. Don't duplicate competitor angles
> 5. Match my channel voice
>
> For each title, note which CTR signals it uses.

### Title A/B Testing Framework

Generate titles in pairs for mental A/B testing:

| Pair | Option A | Option B | Difference |
|------|----------|----------|------------|
| 1 | "How to X" (how-to) | "I Tried X for 30 Days" (personal + number) | Format |
| 2 | "X vs Y: Which is Better?" (comparison) | "Why X is Better Than Y" (contrarian) | Framing |
| 3 | "The Ultimate Guide to X" (power word) | "X Explained in 5 Minutes" (specificity) | Depth signal |

## Tag Generation

### Tag Strategy

YouTube tags have diminishing SEO value but still help with:
- Spelling corrections (common misspellings of your topic)
- Related topic association
- Competitor tag matching

### Tag Categories

Generate tags in these categories:

| Category | Count | Example |
|----------|-------|---------|
| **Primary keyword** | 1-2 | "youtube seo", "youtube seo 2026" |
| **Long-tail variations** | 5-8 | "how to rank youtube videos", "youtube search optimization" |
| **Competitor channel names** | 2-3 | "vidiq", "tubebuddy" (if relevant) |
| **Broad niche** | 2-3 | "youtube tips", "grow youtube channel" |
| **Misspellings** | 1-2 | "youtube seo" → "youtub seo" |

### Tag Extraction from Competitors

```bash
# Get tags from a competitor's top video
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const tags = JSON.parse(d).items?.[0]?.snippet?.tags || [];
    tags.forEach(t => console.log(t));
});
"
```

## Description Generation

### Description Template

```text
[First 2 lines: compelling summary with primary keyword — this shows in search results]

[Blank line]

[TIMESTAMPS/CHAPTERS]
00:00 - Introduction
01:30 - [Section 1]
04:00 - [Section 2]
...

[Blank line]

[RESOURCES MENTIONED]
- [Resource 1]: [link]
- [Resource 2]: [link]

[Blank line]

[ABOUT THIS VIDEO]
[2-3 sentences expanding on the topic with secondary keywords]

[Blank line]

[CONNECT]
- Subscribe: [link]
- [Social 1]: [link]
- [Social 2]: [link]

[Blank line]

[HASHTAGS]
#keyword1 #keyword2 #keyword3
```

### Description SEO Rules

1. **First 150 characters** are critical — they show in search results and suggested videos
2. Include the **primary keyword** in the first 2 lines
3. **Timestamps** improve watch time (viewers jump to relevant sections instead of leaving)
4. **3 hashtags maximum** — YouTube shows the first 3 above the title
5. Include **secondary keywords** naturally in the body text
6. **Links** in the first 3 lines get more clicks (they're visible without expanding)

## Hook Generation

Generate multiple hook options for the same video:

**Prompt pattern**:

> Video topic: [topic]
> Target audience: [audience]
> Video length: [X minutes]
> Key revelation/value: [what the viewer will learn]
>
> Generate 5 hook options (each 15-30 seconds when spoken):
> 1. Bold claim hook
> 2. Question hook
> 3. Story hook
> 4. Result hook
> 5. Curiosity gap hook
>
> For each, include:
> - The spoken text
> - [VISUAL] cue for what's on screen
> - Why this hook works for this specific topic

## Thumbnail Analysis

Use the vision tools to analyze competitor thumbnails and generate briefs.

### Thumbnail Analysis Workflow

```bash
# Get thumbnail URL from a video
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const thumbs = JSON.parse(d).items?.[0]?.snippet?.thumbnails;
    console.log(thumbs?.maxres?.url || thumbs?.high?.url || thumbs?.default?.url);
});
"
```

Then use `tools/vision/image-understanding.md` to analyze:

**Prompt pattern**:
> Analyze this YouTube thumbnail for:
> 1. Text overlay (what words, font size, color)
> 2. Face presence and expression
> 3. Color palette (dominant colors, contrast level)
> 4. Composition (rule of thirds, focal point)
> 5. Emotional trigger (curiosity, shock, excitement, fear)
> 6. Readability at small size (mobile search results)

### Thumbnail Brief Template

```markdown
## Thumbnail Brief: [Video Title]

**Concept**: [1-sentence description]
**Emotional trigger**: [curiosity / shock / excitement / FOMO]

**Layout**:
- Left side: [element]
- Right side: [element]
- Text overlay: "[text]" in [color] [font style]

**Face**: [expression — surprised / pointing / looking at object]
**Background**: [color/gradient/image]
**Key object**: [product/item/visual metaphor]

**Contrast check**: [high contrast between text and background]
**Mobile test**: [readable at 120x90px?]

**Reference thumbnails**: [links to similar successful thumbnails]
```

## Optimization Checklist

Before publishing, verify all metadata:

| Element | Check | Status |
|---------|-------|--------|
| **Title** | 50-70 chars, primary keyword, 2+ CTR signals | |
| **Description** | Keyword in first 150 chars, timestamps, links | |
| **Tags** | 15-30 tags across all categories | |
| **Thumbnail** | High contrast, readable at small size, emotional trigger | |
| **Hook** | First 5 seconds stop the scroll | |
| **Chapters** | Timestamps in description match content | |
| **Cards** | End screen + info cards configured | |
| **Hashtags** | 3 relevant hashtags in description | |
| **Category** | Correct YouTube category selected | |
| **Language** | Correct language and caption settings | |

## Memory Integration

```bash
# Store successful title patterns
memory-helper.sh store --type SUCCESS_PATTERN --namespace youtube-patterns \
  "Title pattern: [pattern]. Used for [topic]. CTR signals: [list]. \
   Result: [views/CTR if known]."

# Store thumbnail style preferences
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Thumbnail style: [description]. Colors: [palette]. \
   Text: [font/size preferences]. Face: [yes/no, expression type]."

# Recall patterns for new videos
memory-helper.sh recall --namespace youtube-patterns "title"
```

## Related

- `youtube/script-writer.md` — Scripts feed into metadata generation
- `youtube/topic-research.md` — Keywords feed into title/tag optimization
- `youtube/thumbnail-ab-testing.md` — Full thumbnail A/B testing pipeline
- `seo/keyword-research.md` — Deep keyword volume data
- `seo/meta-creator.md` — General meta title/description patterns
- `tools/vision/image-understanding.md` — Thumbnail analysis
- `tools/vision/image-generation.md` — Thumbnail generation
- `scripts/thumbnail-factory-helper.sh` — Thumbnail generation and scoring CLI
