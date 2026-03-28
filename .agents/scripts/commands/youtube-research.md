---
description: Research YouTube competitors, trending topics, and content opportunities
agent: Build+
mode: subagent
---

Analyze YouTube competitors, find trending topics, and identify content gaps in your niche.

Target: $ARGUMENTS

## Workflow

### Step 1: Determine Research Type

Parse $ARGUMENTS:

| Argument | Mode |
|----------|------|
| `@handle` | Competitor analysis |
| `trending` / `trends` | Trending topics in niche |
| `gaps` / `opportunities` | Content gap analysis |
| `video VIDEO_ID` | Analyze specific video |
| `--all` | Full research cycle (all competitors) |
| No args | Interactive (ask user) |

### Step 2: Load Configuration

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "channel"
```

Retrieve the user's channel, niche, and competitor list from setup.

### Step 3: Execute Research

#### Mode A: Competitor Analysis (`@competitor`)

1. **Get channel overview and recent videos:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @competitor
~/.aidevops/agents/scripts/youtube-helper.sh videos @competitor 50
```

2. **Identify outliers** — videos with 3x+ channel average views. These are proven winners.

3. **Get transcripts of top 3 outliers:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

4. **Analyze patterns:** common topics, title patterns (length, keywords, hooks), video length, upload frequency.

5. **Store findings:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube-topics \
  "Competitor @handle outliers: [topic1], [topic2], [topic3]. Common pattern: [insight]"
```

#### Mode B: Trending Topics (`trending`)

1. **Search trending videos in niche:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh trending "niche topic" 20
```

2. **Cluster by topic:** group by keywords/themes, identify rising topics, note view counts and engagement.

3. **Cross-reference with competitors:** which trending topics have they NOT covered? Which are oversaturated?

4. **Store opportunities:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube-topics \
  "Trending opportunity: [topic]. Competitors haven't covered: [gap]. Search volume: [estimate]"
```

#### Mode C: Content Gap Analysis (`gaps`)

1. **Compare your videos vs competitors:** topics covered/not covered, unique angles.

2. **Keyword clustering:** extract common keywords from competitor titles, group into topic clusters, rank by frequency and avg views.

3. **Opportunity scoring:**
   - High views + low competition = high opportunity
   - High views + high competition = proven topic, need unique angle
   - Low views + low competition = risky, validate demand first

#### Mode D: Video Analysis (`video VIDEO_ID`)

1. **Get video details and transcript:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh video VIDEO_ID
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

2. **Analyze structure:** hook (first 30s), intro (problem setup), body (solution/content), CTA.

3. **Extract reusable patterns:** title formula, hook formula, content structure, pacing (words/minute).

### Step 4: Present Findings

Format as structured report:

```text
YouTube Research: {target}

Summary:
- {key insight 1-3}

Outlier Videos (3x+ avg views):
1. {title} - {views} views ({ratio}x avg)

Common Patterns:
- Topics: {clusters} | Title style: {pattern}
- Video length: {avg} | Upload frequency: {freq}

Content Opportunities:
1. {opportunity} - {reasoning}

Next Steps:
1. /youtube script "{topic}"
2. /youtube research @handle
3. /youtube research video VIDEO_ID
```

### Step 5: Offer Follow-up Actions

Generate script for top opportunity, research another competitor, set up monitoring (pipeline.md), or export findings.

## Options

| Command | Purpose |
|---------|---------|
| `/youtube research @competitor` | Analyze competitor channel |
| `/youtube research trending` | Find trending topics in niche |
| `/youtube research gaps` | Content gap analysis |
| `/youtube research video VIDEO_ID` | Analyze specific video |
| `/youtube research --all` | Full research cycle (all competitors) |

## Example: Competitor Analysis

```text
User: /youtube research @fireship

Channel: Fireship | 3.2M subs | 245 videos | Avg: 1.8M views

Outlier Videos (3x+ avg = 5.4M+):
1. "100+ JavaScript Concepts you Need to Know" - 12.4M (6.8x)
2. "I built the same app 10 times" - 8.9M (4.8x)
3. "JavaScript Pro Tips - Code This, NOT That" - 7.2M (3.9x)

Patterns: comparison videos, "X concepts" lists, code quality tips
Titles: numbers + actionable promise | Length: 8-12 min | Freq: 2-3/week
Hook: contrarian statement -> immediate value promise

Opportunities:
1. "100+ Python Concepts you Need to Know" - proven format, untapped niche
2. "I built the same AI app 10 times" - trending topic + proven format

Next: /youtube script "100+ Python Concepts you Need to Know"
```

## Related

- `content/distribution-youtube.md` - Main YouTube agent
- `content/distribution-youtube-channel-intel.md` - Deep competitor profiling
- `content/distribution-youtube-topic-research.md` - Advanced topic research
- `/youtube setup` - Configure tracking
- `/youtube script` - Generate scripts from research
- `youtube-helper.sh` - YouTube Data API wrapper
