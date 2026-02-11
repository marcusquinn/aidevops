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

# YouTube Topic Research

Find video topics that have proven demand but low competition. Combines YouTube search data, competitor content analysis, keyword research, and trend detection to surface opportunities.

## When to Use

Read this subagent when the user wants to:

- Find video topic ideas for their niche
- Identify content gaps (topics competitors haven't covered)
- Detect rising trends before they peak
- Cluster keywords into video topic groups
- Generate unique angles on proven topics
- Validate whether a topic idea has enough search demand

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

The most reliable way to find topics: compare what competitors cover vs what's missing.

### Step 1: Extract Competitor Topic Maps

For each competitor, get their video titles and cluster by topic:

```bash
# Get all video titles from a competitor
youtube-helper.sh videos @competitor 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > /tmp/competitor_titles.txt
```

Repeat for 3-5 competitors. Then use the AI to cluster titles into topic groups:

**Prompt pattern**:
> Here are [N] video titles from [competitor]. Group them into topic clusters.
> For each cluster, note: topic name, video count, and whether views trend up or down.

### Step 2: Map Your Own Coverage

```bash
youtube-helper.sh videos @yourchannel 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > /tmp/my_titles.txt
```

### Step 3: Identify Gaps

Compare the topic maps. Gaps are topics that:
1. Multiple competitors cover (proven demand)
2. You haven't covered yet
3. Have outlier videos in competitor channels (high engagement)

**Prompt pattern**:
> Compare these topic clusters from my channel vs competitors.
> Identify topics where: (a) 2+ competitors have videos, (b) I have zero coverage,
> (c) at least one competitor video is an outlier (3x+ their median views).

### Step 4: Store Findings

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: [topic]. Covered by @comp1 (X views), @comp2 (Y views). \
   My coverage: none. Angle opportunity: [description]."
```

## Workflow: Trend Detection

Find topics gaining momentum before they saturate.

### Method 1: YouTube Search Volume Signals

```bash
# Search for your niche topic — look at publish dates
youtube-helper.sh search "your niche topic 2026" video 20

# If most results are recent (last 30 days), the topic is trending
# If results are old, the topic may be saturated
```

### Method 2: DataForSEO YouTube SERP

If DataForSEO is configured, use the YouTube SERP endpoint:

```bash
# Check keyword-research-helper for YouTube-specific data
keyword-research-helper.sh volume "topic keyword" --engine youtube
```

DataForSEO's `serp/youtube/organic/live` endpoint returns:
- Video rankings for a keyword on YouTube search
- Estimated search volume
- Competition level
- Related keywords

### Method 3: Competitor Upload Velocity

If multiple competitors suddenly start covering a topic, it's trending:

```bash
# Get recent videos from multiple competitors
for ch in @comp1 @comp2 @comp3; do
    echo "=== $ch ==="
    youtube-helper.sh videos "$ch" 20 | head -15
    echo ""
done
```

Look for the same topic appearing across multiple channels within the same 2-week window.

### Method 4: Google Trends via Serper

```bash
# Use Serper to check Google Trends signals
# (requires serper.md configuration)
```

**Prompt pattern**:
> Search Google Trends for "[topic]" and tell me if interest is rising,
> stable, or declining over the past 12 months.

## Workflow: Keyword Clustering for YouTube

Group related keywords into video topics. One video should target one keyword cluster.

### Step 1: Seed Keywords

Start with 5-10 broad keywords in your niche:

```bash
# Search YouTube for each seed keyword
for kw in "keyword1" "keyword2" "keyword3"; do
    echo "=== $kw ==="
    youtube-helper.sh search "$kw" video 10
    echo ""
done
```

### Step 2: Extract Related Terms

From search results, extract:
- Video titles (contain natural keyword variations)
- Tags from top-performing videos
- Description keywords

```bash
# Get tags from top videos
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const tags = JSON.parse(d).items?.[0]?.snippet?.tags || [];
    tags.forEach(t => console.log(t));
});
"
```

### Step 3: Cluster with AI

**Prompt pattern**:
> Here are [N] keywords related to [niche]. Group them into clusters where
> each cluster represents one video topic. For each cluster:
> 1. Primary keyword (highest volume)
> 2. Supporting keywords (2-5)
> 3. Suggested video title
> 4. Estimated competition (low/medium/high based on existing video count)

### Step 4: Validate with Search Volume

If DataForSEO is available:

```bash
keyword-research-helper.sh volume "primary keyword" --engine youtube
```

## Workflow: Angle Generation

The same topic can be covered from many angles. Find the unique take that hasn't been done.

### Step 1: Analyze Existing Coverage

```bash
# Search for the topic
youtube-helper.sh search "topic" video 20

# Get transcripts of top 3 videos to understand their angle
youtube-helper.sh transcript VIDEO_ID_1
youtube-helper.sh transcript VIDEO_ID_2
youtube-helper.sh transcript VIDEO_ID_3
```

### Step 2: Identify Angle Patterns

Common YouTube angle types:

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

### Step 3: Generate Unique Angles

**Prompt pattern**:
> Topic: [topic]
> Existing angles found in top 10 videos: [list angles]
> My channel's voice: [description from memory]
> My audience: [description from memory]
>
> Generate 5 unique angles for this topic that:
> 1. Haven't been covered by the top 10 videos
> 2. Match my channel voice
> 3. Would appeal to my specific audience
> 4. Have a clear hook for the first 30 seconds

## Output Format

When reporting topic research, use this structure:

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

# Store a failed topic idea (so we don't revisit it)
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
