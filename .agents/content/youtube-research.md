---
description: Research YouTube competitors, trending topics, and content opportunities
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze YouTube competitors, find trending topics, and identify content gaps in your niche.

Target: $ARGUMENTS

## Workflow

### Step 1: Determine Research Type

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

### Step 3: Execute Research

#### Mode A: Competitor Analysis (`@competitor`)

1. Get channel overview and recent videos:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @competitor
~/.aidevops/agents/scripts/youtube-helper.sh videos @competitor 50
```

2. **Identify outliers** — videos with 3x+ channel average views.
3. Get transcripts of top 3 outliers: `youtube-helper.sh transcript VIDEO_ID`
4. **Analyze patterns:** topics, title style (length, keywords, hooks), video length, upload frequency.
5. Store findings:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION --namespace youtube-topics \
  "Competitor @handle outliers: [topic1], [topic2], [topic3]. Pattern: [insight]"
```

#### Mode B: Trending Topics (`trending`)

1. Search trending videos: `youtube-helper.sh trending "niche topic" 20`
2. **Cluster by topic:** group by keywords/themes, identify rising topics, note view counts.
3. **Cross-reference with competitors:** which trending topics haven't they covered? Which are oversaturated?
4. Store opportunities:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION --namespace youtube-topics \
  "Trending opportunity: [topic]. Gap: [competitors haven't covered]. Volume: [estimate]"
```

#### Mode C: Content Gap Analysis (`gaps`)

1. Compare your videos vs competitors: topics covered/not covered, unique angles.
2. **Keyword clustering:** extract common keywords from competitor titles, group into clusters, rank by frequency and avg views.
3. **Opportunity scoring:** High views + low competition = high opportunity. High views + high competition = proven topic, need unique angle. Low views + low competition = risky, validate demand first.

#### Mode D: Video Analysis (`video VIDEO_ID`)

1. Get details and transcript:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh video VIDEO_ID
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

2. **Analyze structure:** hook (first 30s), intro (problem setup), body (solution/content), CTA.
3. **Extract reusable patterns:** title formula, hook formula, content structure, pacing (words/minute).

### Step 4: Present Findings

```text
YouTube Research: {target}
Summary: {key insight 1-3}
Outlier Videos (3x+ avg): {title} - {views} ({ratio}x avg)
Patterns: Topics: {clusters} | Titles: {pattern} | Length: {avg} | Freq: {freq}
Opportunities: {opportunity} - {reasoning}
Next: /youtube script "{topic}" | /youtube research @handle | /youtube research video VIDEO_ID
```

## Related

- `content/distribution-youtube.md` - Main YouTube agent
- `content/distribution-youtube-channel-intel.md` - Deep competitor profiling
- `content/distribution-youtube-topic-research.md` - Advanced topic research
- `/youtube setup` - Configure tracking
- `/youtube script` - Generate scripts from research
- `youtube-helper.sh` - YouTube Data API wrapper
