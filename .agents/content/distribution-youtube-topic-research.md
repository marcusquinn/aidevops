---
description: "YouTube topic research - content gaps, trend detection, keyword clustering, angle generation"
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# YouTube Topic Research

Find video topics with proven demand but low competition. Combines YouTube search data, competitor analysis, keyword research, and trend detection.

## Data Sources

| Source | What It Provides | Tool |
|--------|-----------------|------|
| YouTube Data API | Search results, video counts per topic | `youtube-helper.sh search` |
| Competitor videos | What topics are already covered | `youtube-helper.sh videos` |
| yt-dlp transcripts | Deep topic extraction from video content | `youtube-helper.sh transcript` |
| DataForSEO | YouTube SERP data, keyword volume, competition | `keyword-research-helper.sh` |
| Serper | Google Trends signals, web search context | `seo/serper.md` |
| Memory | Previous research, patterns, preferences | `memory-helper.sh` |

## Workflow: Content Gap Analysis

Compare what competitors cover vs what's missing. Run for 3-5 competitors.

### Step 1: Extract Competitor Topic Maps

```bash
youtube-helper.sh videos @competitor 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > /tmp/competitor_titles.txt
```

**Prompt**: "Group these [N] video titles from [competitor] into topic clusters. For each: topic name, video count, view trend (up/down)."

### Step 2: Map Your Coverage

```bash
youtube-helper.sh videos @yourchannel 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > /tmp/my_titles.txt
```

### Step 3: Identify Gaps

Gaps are topics where: (1) multiple competitors cover (proven demand), (2) you have zero coverage, (3) at least one competitor video is an outlier (3x+ their median views).

**Prompt**: "Compare my topic clusters vs competitors. Identify topics where 2+ competitors have videos, I have zero coverage, and at least one competitor video is an outlier (3x+ median views)."

### Step 4: Store Findings

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: [topic]. Covered by @comp1 (X views), @comp2 (Y views). \
   My coverage: none. Angle opportunity: [description]."
```

## Workflow: Trend Detection

Find topics gaining momentum before saturation.

### Method 1: YouTube Search Volume Signals

```bash
# Recent publish dates = trending; old results = saturated
youtube-helper.sh search "your niche topic 2026" video 20
```

### Method 2: DataForSEO YouTube SERP

```bash
keyword-research-helper.sh volume "topic keyword" --engine youtube
```

Returns: video rankings, estimated search volume, competition level, related keywords via `serp/youtube/organic/live` endpoint.

### Method 3: Competitor Upload Velocity

Multiple competitors suddenly covering a topic = trending signal. Look for the same topic across channels within a 2-week window.

```bash
for ch in @comp1 @comp2 @comp3; do
    echo "=== $ch ==="
    youtube-helper.sh videos "$ch" 20 | head -15
    echo ""
done
```

### Method 4: Google Trends via Serper

**Prompt**: "Search Google Trends for '[topic]' — is interest rising, stable, or declining over the past 12 months?" (requires `seo/serper.md` configuration)

## Workflow: Keyword Clustering

Group related keywords into video topics. One video = one keyword cluster.

### Step 1: Seed Keywords

Search YouTube for 5-10 broad niche keywords.

```bash
for kw in "keyword1" "keyword2" "keyword3"; do
    echo "=== $kw ==="
    youtube-helper.sh search "$kw" video 10
    echo ""
done
```

### Step 2: Extract Related Terms

From search results, extract video titles (natural keyword variations), tags, and description keywords.

```bash
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const tags = JSON.parse(d).items?.[0]?.snippet?.tags || [];
    tags.forEach(t => console.log(t));
});
"
```

### Step 3: Cluster with AI

**Prompt**: "Group these [N] keywords into clusters (one cluster = one video). For each: (1) primary keyword (highest volume), (2) supporting keywords (2-5), (3) suggested video title, (4) estimated competition (low/medium/high based on existing video count)."

### Step 4: Validate with Search Volume

```bash
keyword-research-helper.sh volume "primary keyword" --engine youtube
```

## Workflow: Angle Generation

Find the unique take that hasn't been done on a proven topic.

### Step 1: Analyze Existing Coverage

Get transcripts of top 3 videos to understand their angle.

```bash
youtube-helper.sh search "topic" video 20
youtube-helper.sh transcript VIDEO_ID_1
youtube-helper.sh transcript VIDEO_ID_2
youtube-helper.sh transcript VIDEO_ID_3
```

### Step 2: Angle Types Reference

| Angle Type | Example | When It Works |
|-----------|---------|---------------|
| **Contrarian** | "Why [popular opinion] is wrong" | Established topics with consensus |
| **Personal experience** | "I tried [thing] for 30 days" | Lifestyle, health, tech |
| **Comparison** | "[A] vs [B] — which is actually better?" | Products, tools, methods |
| **Deep dive** | "The science behind [thing]" | Topics with surface-level coverage |
| **Beginner-friendly** | "[Topic] explained in 5 minutes" | Complex topics |
| **Update** | "[Topic] in 2026 — what changed" | Evergreen topics with new developments |
| **Case study** | "How [person/company] did [thing]" | Business, strategy, marketing |
| **Mistakes** | "5 [topic] mistakes everyone makes" | How-to niches |
| **Hidden/secret** | "[Topic] features nobody talks about" | Tech, tools, platforms |
| **Cost breakdown** | "The real cost of [thing]" | Finance, lifestyle, business |
| **Question-framed** | "How does [X] actually work?" / "Is [X] worth it in 2026?" | Any topic — doubles as an LLM citation magnet. AI answer engines preferentially cite videos whose title/transcript literally answers a user question. Pair with a transcript page (`seo/transcript-seo.md`) for compounding returns. |

### Step 3: Generate Unique Angles

**Prompt**: "Topic: [topic]. Existing angles in top 10 videos: [list]. My channel voice: [from memory]. My audience: [from memory]. Generate 5 unique angles that: (1) aren't covered by top 10, (2) match my voice, (3) appeal to my audience, (4) have a clear hook for the first 30 seconds."

## Output Format

```markdown
## Topic Opportunity: [Topic Name]

**Demand signal**: [search volume, competitor coverage, trend direction]
**Competition**: [low/medium/high] — [X] existing videos, [Y] in last 30 days
**Gap type**: [uncovered / underserved / new angle needed]

### Existing Coverage
- @competitor1: "[title]" — [views] views, [angle used]
- @competitor2: "[title]" — [views] views, [angle used]

### Recommended Angle
**[Angle type]**: [description]
**Working title**: "[suggested title]"
**Hook**: [first 30 seconds concept]
**Why this works**: [reasoning based on gap + audience]

### Keywords to Target
- Primary: [keyword] ([volume])
- Supporting: [kw1], [kw2], [kw3]
```

## Memory Integration

```bash
# Store a validated topic opportunity
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Topic: [name]. Demand: [signal]. Competition: [level]. \
   Best angle: [type] — [description]. Keywords: [list]."

# Recall previous research
memory-helper.sh recall --namespace youtube-topics "content gap"

# Store a failed topic idea (avoid revisiting)
memory-helper.sh store --type FAILED_APPROACH --namespace youtube-topics \
  "Topic [name] rejected: [reason — e.g., too saturated, no search volume]"
```

## Related

- `channel-intel.md` — Competitor data feeds into gap analysis
- `script-writer.md` — Turn validated topics into scripts
- `optimizer.md` — Optimize titles/tags for chosen keywords
- `seo/keyword-research.md` — Deep keyword volume and competition data
- `seo/dataforseo.md` — YouTube SERP API for ranking data
- `seo/serper.md` — Google Trends and web search signals
