---
description: Research YouTube topics, competitors, and content opportunities
agent: YouTube
mode: subagent
---

Run YouTube research workflows -- competitor analysis, content gap detection, trend spotting, and topic validation.

Arguments: $ARGUMENTS

## Usage

```text
/youtube research                              # Full research cycle (intel + gaps + trends)
/youtube research competitors                  # Scan all stored competitors
/youtube research gaps                         # Content gap analysis
/youtube research trending "niche topic"       # Find trending videos in a niche
/youtube research topic "topic name"           # Validate a specific topic idea
/youtube research outliers @handle             # Find outlier videos for a channel
/youtube research recall                       # Show previous research findings
```

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the research mode:

| Argument | Action |
|----------|--------|
| (none) | Full research cycle |
| `competitors` | Competitor intel scan |
| `gaps` | Content gap analysis |
| `trending "topic"` | Trending video search |
| `topic "name"` | Single topic validation |
| `outliers @handle` | Outlier detection for a channel |
| `recall` | Show stored research findings |

### Step 2: Load Context

Before any research, recall stored configuration:

```bash
# Get channel profile
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "My channel"

# Get competitor list
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "Competitor"

# Get previous research (avoid duplicating work)
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics --recent
```

If no channel profile exists, prompt:

```text
No YouTube channel configured. Run /youtube setup first.
```

### Step 3: Route to Research Mode

**For `competitors` or full cycle:**

Read `youtube/channel-intel.md` for the full workflow, then for each stored competitor:

```bash
# Get channel stats
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle

# Get recent videos (last 50)
~/.aidevops/agents/scripts/youtube-helper.sh videos @handle 50

# Run comparison
~/.aidevops/agents/scripts/youtube-helper.sh competitors @me @comp1 @comp2 @comp3
```

Analyze the data to identify:

- New uploads since last scan
- Outlier videos (3x+ median views)
- Upload frequency changes
- New topic clusters

Store findings:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Intel scan [date]: @handle - [findings summary]"
```

**For `gaps`:**

Read `youtube/topic-research.md` for the full workflow:

1. Extract topic clusters from competitor video titles
2. Map your own coverage
3. Identify topics where 2+ competitors have videos but you have none
4. Filter by outlier presence (proven demand)
5. Rank by opportunity score (demand / competition)

Store each gap:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: [topic]. Covered by @comp1 ([views]), @comp2 ([views]). My coverage: none. Angle: [suggestion]."
```

**For `trending "topic"`:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh trending "topic" 20
```

Analyze results for:

- View velocity (views per day since publish)
- Channel diversity (many channels = broad trend, few = niche)
- Recency (all recent = rising trend, mixed = established)

**For `topic "name"`:**

Validate a specific topic idea:

```bash
# Check existing coverage
~/.aidevops/agents/scripts/youtube-helper.sh search "topic name" video 20

# Check competition level
~/.aidevops/agents/scripts/youtube-helper.sh search "topic name" video 50
```

Assess:

- How many videos exist on this exact topic?
- What are the view counts? (high = proven demand)
- How recent are the top results? (old = opportunity to update)
- What angles have been covered? (find the gap)

Report using the topic opportunity format from `youtube/topic-research.md`.

**For `outliers @handle`:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh videos @handle 200 json
```

Then calculate median views and identify videos at 3x+ threshold. For each outlier, note the title pattern, topic, and duration.

**For `recall`:**

```bash
# Recent intel
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "Intel scan" --recent

# Topic opportunities
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics "Opportunity" --recent

# Content gaps
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics "Content gap" --recent
```

### Step 4: Full Research Cycle (no arguments)

When no arguments are provided, run the complete cycle:

1. **Competitor scan** -- profile all stored competitors
2. **Outlier detection** -- find breakout videos across all competitors
3. **Content gap analysis** -- compare topic coverage
4. **Trend check** -- search for rising topics in the niche
5. **Rank opportunities** -- score by demand, competition, and fit

Present a ranked list:

```text
YouTube Research Results ([date]):

Top Opportunities:
1. [Topic] -- Demand: High, Competition: Low, Angle: [suggestion]
   Covered by: @comp1 (50K views), @comp2 (30K views)
   Your coverage: None

2. [Topic] -- Demand: Medium, Competition: Medium, Angle: [suggestion]
   Outlier: @comp3 "[title]" (200K views, 5x their median)
   Your coverage: 1 video (underperforming)

3. [Topic] -- Demand: Rising, Competition: Low, Angle: [suggestion]
   Trend signal: 4 new videos in last 2 weeks across 3 channels

Quota used: [X] / 10,000 units

Next steps:
  /youtube script "[topic]"    -- Generate a script for any topic above
  /youtube research recall     -- Review these findings later
```

### Step 5: Store and Report

After any research mode, store findings in memory and check quota:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh quota
```

## Quota Budget

| Research Mode | Estimated Cost |
|---------------|---------------|
| Single competitor scan | ~10 units |
| Full competitor scan (5 channels) | ~50 units |
| Content gap analysis | ~60 units (includes video enumeration) |
| Trending search | ~100 units (uses search endpoint) |
| Topic validation | ~100 units (uses search endpoint) |
| Full research cycle | ~300 units |

## Prerequisites

- YouTube channel configured via `/youtube setup`
- At least 1 competitor stored in memory
- YouTube Data API authentication working

## Related

- `youtube.md` -- Main YouTube agent
- `youtube/channel-intel.md` -- Detailed competitor profiling
- `youtube/topic-research.md` -- Content gap and trend workflows
- `youtube-helper.sh` -- YouTube Data API wrapper
- `youtube-script.md` -- Generate scripts from research findings
