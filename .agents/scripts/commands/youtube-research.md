---
description: Research YouTube competitors, trending topics, and content opportunities
agent: Build+
mode: subagent
---

Analyze YouTube competitors, find trending topics, and identify content gaps in your niche.

Target: $ARGUMENTS

## Workflow

### Step 1: Determine Research Type

Parse $ARGUMENTS to identify the research mode:

- `@handle` → Competitor analysis
- `trending` or `trends` → Trending topics in niche
- `gaps` or `opportunities` → Content gap analysis
- `video VIDEO_ID` → Analyze specific video
- No args → Interactive mode (ask user what to research)

### Step 2: Load Configuration

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "channel"
```

Retrieve the user's channel, niche, and competitor list from setup.

### Step 3: Execute Research

#### Mode A: Competitor Analysis (`@competitor`)

1. **Get channel overview:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @competitor
```

2. **List recent videos (last 50):**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh videos @competitor 50
```

3. **Identify outliers** (videos with 3x+ channel average views):

   - Calculate average views/video from channel stats
   - Flag videos with views > 3x average
   - These are the "proven winners" to study

4. **Get transcripts of top 3 outliers:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

5. **Analyze patterns:**

   - Common topics in outliers
   - Title patterns (length, keywords, hooks)
   - Video length patterns
   - Upload frequency

6. **Store findings in memory:**

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

2. **Cluster by topic:**

   - Group videos by common keywords/themes
   - Identify rising topics (multiple recent videos)
   - Note view counts and engagement rates

3. **Cross-reference with competitors:**

   - Which trending topics have your competitors NOT covered?
   - Which topics are oversaturated?

4. **Store opportunities:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube-topics \
  "Trending opportunity: [topic]. Competitors haven't covered: [gap]. Search volume: [estimate]"
```

#### Mode C: Content Gap Analysis (`gaps`)

1. **Compare your videos vs competitors:**

   - Topics you've covered vs topics they've covered
   - Identify gaps (topics they cover that you don't)
   - Identify unique angles (topics you cover that they don't)

2. **Keyword clustering:**

   - Extract common keywords from competitor titles
   - Group into topic clusters
   - Rank by frequency and avg views

3. **Opportunity scoring:**

   - High views + low competition = high opportunity
   - High views + high competition = proven topic, need unique angle
   - Low views + low competition = risky, validate demand first

#### Mode D: Video Analysis (`video VIDEO_ID`)

1. **Get video details:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh video VIDEO_ID
```

2. **Get transcript:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

3. **Analyze structure:**

   - Hook (first 30 seconds)
   - Intro (problem setup)
   - Body (solution/content)
   - CTA (call to action)

4. **Extract reusable patterns:**

   - Title formula
   - Hook formula
   - Content structure
   - Pacing (words/minute from transcript)

### Step 4: Present Findings

Format as a structured report:

```text
YouTube Research: {target}

Summary:
- {key insight 1}
- {key insight 2}
- {key insight 3}

Outlier Videos (3x+ avg views):
1. {title} - {views} views ({ratio}x avg)
2. {title} - {views} views ({ratio}x avg)
3. {title} - {views} views ({ratio}x avg)

Common Patterns:
- Topics: {topic clusters}
- Title style: {pattern}
- Video length: {avg duration}
- Upload frequency: {frequency}

Content Opportunities:
1. {opportunity 1} - {reasoning}
2. {opportunity 2} - {reasoning}
3. {opportunity 3} - {reasoning}

Next Steps:
1. Generate script for opportunity #1: /youtube script "{topic}"
2. Analyze another competitor: /youtube research @handle
3. Deep-dive on specific video: /youtube research video VIDEO_ID
```

### Step 5: Offer Follow-up Actions

- Generate script for top opportunity
- Research another competitor
- Set up automated monitoring (pipeline.md)
- Export findings to a report file

## Options

| Command | Purpose |
|---------|---------|
| `/youtube research @competitor` | Analyze competitor channel |
| `/youtube research trending` | Find trending topics in niche |
| `/youtube research gaps` | Content gap analysis |
| `/youtube research video VIDEO_ID` | Analyze specific video |
| `/youtube research --all` | Full research cycle (all competitors) |

## Examples

**Competitor analysis:**

```text
User: /youtube research @fireship
AI: Analyzing @fireship...

    Channel: Fireship
    Subscribers: 3.2M
    Videos: 245
    Avg views/video: 1,836,735
    
    Fetching recent videos...
    
    Outlier Videos (3x+ avg = 5.5M+ views):
    1. "100+ JavaScript Concepts you Need to Know" - 12.4M views (6.8x avg)
    2. "I built the same app 10 times" - 8.9M views (4.8x avg)
    3. "JavaScript Pro Tips - Code This, NOT That" - 7.2M views (3.9x avg)
    
    Common Patterns:
    - Topics: Comparison videos, "X concepts" lists, code quality tips
    - Title style: Numbers + actionable promise (e.g., "100+ concepts you NEED")
    - Video length: 8-12 minutes (sweet spot for retention)
    - Upload frequency: 2-3 videos/week
    
    Analyzing top video transcript...
    
    Hook Analysis ("100+ JavaScript Concepts"):
    - Opens with: "JavaScript is a language you can learn in 5 minutes..."
    - Pattern: Contrarian statement → immediate value promise
    - First 30s: Problem setup + content preview
    
    Content Opportunities:
    1. "100+ Python Concepts you Need to Know" - Proven format, untapped niche
    2. "I built the same AI app 10 times" - Trending topic (AI) + proven format
    3. "Python Pro Tips - Code This, NOT That" - Direct adaptation to your niche
    
    Findings stored in memory (namespace: youtube-topics)
    
    Next: /youtube script "100+ Python Concepts you Need to Know"
```

**Trending topics:**

```text
User: /youtube research trending
AI: Searching trending videos in "AI coding tools"...

    Trending Topics (last 30 days, sorted by views):
    
    Topic Cluster: "AI Coding Assistants"
    - "Cursor vs GitHub Copilot" - 890K views
    - "I replaced my developer with AI" - 650K views
    - "Best AI coding tools 2026" - 520K views
    
    Topic Cluster: "AI Code Review"
    - "AI found bugs in my code" - 340K views
    - "Automated code review with AI" - 280K views
    
    Topic Cluster: "AI Agents"
    - "Building AI agents that code" - 450K views
    - "AI agent writes entire app" - 380K views
    
    Gap Analysis:
    ✓ Your competitors HAVE covered: AI assistants, code generation
    ✗ Your competitors HAVEN'T covered: AI code review, AI agents (emerging)
    
    High-Opportunity Topics:
    1. "AI Code Review Tools Compared" - Rising trend, low competition
    2. "I built an AI agent that writes code" - Proven format + trending topic
    3. "AI found 10 bugs in production code" - Specific, relatable, shareable
    
    Stored 3 opportunities in memory.
    
    Next: /youtube script "AI Code Review Tools Compared"
```

**Video deep-dive:**

```text
User: /youtube research video dQw4w9WgXcQ
AI: Analyzing video dQw4w9WgXcQ...

    Title: "Never Gonna Give You Up"
    Channel: Rick Astley
    Views: 1.4B
    Published: 2009-10-25
    Duration: 3m33s
    
    Transcript Analysis:
    - Hook: Immediate music start (no intro)
    - Structure: Verse → Chorus → Verse → Chorus → Bridge → Chorus
    - Pacing: 120 words/minute (moderate)
    - Repetition: Chorus repeats 4 times (retention strategy)
    
    Title Formula:
    - Simple, direct, memorable
    - No clickbait, pure content promise
    
    Engagement:
    - Likes: 16M (1.1% of views)
    - Comments: 3.2M (0.2% of views)
    - High shareability (meme status)
    
    Reusable Patterns:
    1. Strong hook (no wasted time)
    2. Repetition for retention
    3. Memorable, quotable content
    
    This video is an outlier (meme status), but the structural patterns apply.
```

## Related

- `content/distribution/youtube/youtube.md` - Main YouTube agent
- `content/distribution/youtube/channel-intel.md` - Deep competitor profiling
- `content/distribution/youtube/topic-research.md` - Advanced topic research
- `/youtube setup` - Configure tracking
- `/youtube script` - Generate scripts from research
- `youtube-helper.sh` - YouTube Data API wrapper
