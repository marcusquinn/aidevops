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

## Title Generation

### CTR Signal Checklist

| Signal | Example | Why It Works |
|--------|---------|-------------|
| **Number** | "7 Tools That..." | Sets expectations, implies structure |
| **Brackets** | "... [Full Guide]" | Adds context, increases CTR 33% |
| **Power word** | "Insane", "Secret", "Ultimate" | Triggers emotional response |
| **Question** | "Why Does...?" | Creates curiosity gap |
| **Year** | "... in 2026" | Signals freshness |
| **Negative** | "Stop Doing...", "Never..." | Loss aversion |
| **How-to** | "How to..." | Clear value proposition |
| **Comparison** | "X vs Y" | Implies a verdict |
| **Personal** | "I Tried...", "My..." | Authenticity signal |
| **Specificity** | "$5", "30 Days", "100K" | Concrete > vague |

### Workflow

```bash
# Get competitor titles for the same topic
youtube-helper.sh search "topic" video 20

# Get title, tags, views from a specific video
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const v = JSON.parse(d).items?.[0];
    console.log('Title:', v?.snippet?.title);
    console.log('Tags:', (v?.snippet?.tags || []).join(', '));
    console.log('Views:', v?.statistics?.viewCount);
});
"
```

### Title Prompt Pattern

> Topic: [topic] | Primary keyword: [keyword] | Voice: [casual/formal/authoritative]
> Competitor titles: [title1 (views)], [title2 (views)], [title3 (views)]
>
> Generate 10 titles that: (1) include primary keyword naturally, (2) use 2+ CTR signals, (3) are 50-70 characters, (4) don't duplicate competitor angles, (5) match channel voice. Note which CTR signals each uses.

### A/B Testing Pairs

| Option A | Option B | Variable |
|----------|----------|----------|
| "How to X" (how-to) | "I Tried X for 30 Days" (personal + number) | Format |
| "X vs Y: Which is Better?" (comparison) | "Why X is Better Than Y" (contrarian) | Framing |
| "The Ultimate Guide to X" (power word) | "X Explained in 5 Minutes" (specificity) | Depth signal |

## Tag Generation

Tags have diminishing SEO value but help with spelling corrections, related topic association, and competitor matching.

| Category | Count | Example |
|----------|-------|---------|
| **Primary keyword** | 1-2 | "youtube seo", "youtube seo 2026" |
| **Long-tail variations** | 5-8 | "how to rank youtube videos", "youtube search optimization" |
| **Competitor channels** | 2-3 | "vidiq", "tubebuddy" (if relevant) |
| **Broad niche** | 2-3 | "youtube tips", "grow youtube channel" |
| **Misspellings** | 1-2 | "youtube seo" → "youtub seo" |

Extract competitor tags using the same `youtube-helper.sh video VIDEO_ID json` pattern — parse `snippet.tags` array.

## Description Template

```text
[First 2 lines: compelling summary with primary keyword — shows in search results]

[TIMESTAMPS/CHAPTERS]
00:00 - Introduction
01:30 - [Section 1]
04:00 - [Section 2]

[RESOURCES MENTIONED]
- [Resource 1]: [link]
- [Resource 2]: [link]

[ABOUT THIS VIDEO]
[2-3 sentences with secondary keywords]

[CONNECT]
- Subscribe: [link]
- [Social 1]: [link]
- [Social 2]: [link]

[HASHTAGS]
#keyword1 #keyword2 #keyword3
```

### Description SEO Rules

1. **First 150 characters** show in search results and suggested videos — include primary keyword
2. **Timestamps** improve watch time (viewers jump to sections instead of leaving)
3. **3 hashtags max** — YouTube shows the first 3 above the title
4. **Links in first 3 lines** get more clicks (visible without expanding)
5. Include **secondary keywords** naturally in body text

## Hook Generation

> Video topic: [topic] | Audience: [audience] | Length: [X min] | Key value: [what viewer learns]
>
> Generate 5 hooks (15-30 seconds spoken each):
> 1. Bold claim  2. Question  3. Story  4. Result  5. Curiosity gap
>
> For each: spoken text, [VISUAL] cue, why it works for this topic.

## Thumbnail Analysis

### Analysis Workflow

```bash
# Get thumbnail URL
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const thumbs = JSON.parse(d).items?.[0]?.snippet?.thumbnails;
    console.log(thumbs?.maxres?.url || thumbs?.high?.url || thumbs?.default?.url);
});
"
```

Analyze with `tools/vision/image-understanding.md`:

> Analyze this YouTube thumbnail for: (1) text overlay (words, font, color), (2) face presence/expression, (3) color palette and contrast, (4) composition (rule of thirds, focal point), (5) emotional trigger, (6) readability at small size (mobile).

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

## Pre-Publish Checklist

| Element | Check |
|---------|-------|
| **Title** | 50-70 chars, primary keyword, 2+ CTR signals |
| **Description** | Keyword in first 150 chars, timestamps, links |
| **Tags** | 15-30 tags across all categories |
| **Thumbnail** | High contrast, readable small, emotional trigger |
| **Hook** | First 5 seconds stop the scroll |
| **Chapters** | Timestamps match content |
| **Cards** | End screen + info cards configured |
| **Hashtags** | 3 relevant hashtags in description |
| **Category** | Correct YouTube category selected |
| **Language** | Correct language and caption settings |

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

- `script-writer.md` — Scripts feed into metadata generation
- `topic-research.md` — Keywords feed into title/tag optimization
- `seo/keyword-research.md` — Deep keyword volume data
- `seo/meta-creator.md` — General meta title/description patterns
- `tools/vision/image-understanding.md` — Thumbnail analysis
- `tools/vision/image-generation.md` — Thumbnail generation
