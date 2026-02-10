---
description: "YouTube automated research pipeline - cron-driven competitor monitoring and content generation"
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

# YouTube Automated Pipeline

Cron-driven autonomous pipeline for YouTube competitor research and content generation. Each phase runs as an isolated worker with fresh context, storing results in memory. Solves the "context filling up" problem by decomposing research into independent tasks.

## When to Use

Read this subagent when the user wants to:

- Set up automated daily/weekly competitor monitoring
- Run the full research-to-script pipeline autonomously
- Configure cron jobs for YouTube research
- Understand how the pipeline phases connect
- Debug or monitor pipeline execution

## Architecture

```text
Cron Trigger (daily/weekly)
    |
    v
Supervisor Pulse
    |
    +-- Worker 1: Channel Intel Scan
    |   Input:  competitor list from memory
    |   Output: channel stats, new videos, outliers -> memory
    |   Quota:  ~50 units per run
    |
    +-- Worker 2: Topic Research
    |   Input:  competitor data from memory + keyword seeds
    |   Output: content gaps, trending topics -> memory
    |   Quota:  ~200 units (includes search)
    |
    +-- Worker 3: Script Generation
    |   Input:  top 3 opportunities from memory
    |   Output: draft scripts -> workspace files
    |   Quota:  0 units (AI generation only)
    |
    +-- Worker 4: Optimization
    |   Input:  draft scripts from workspace
    |   Output: titles, tags, descriptions, thumbnail briefs -> workspace
    |   Quota:  ~10 units (competitor tag lookup)
    |
    +-- Worker 5: Thumbnail A/B Testing
    |   Input:  video metadata + briefs from workspace
    |   Output: 5-10 scored thumbnail variants per video -> workspace
    |   Quota:  ~100 units (competitor thumbnail search)
    |   Cost:   ~$0.40-0.80/video (DALL-E 3 generation)
    |
    +-- Notification
        Output: summary email/mailbox message
```

### Why This Solves Context Overflow

| Problem | Solution |
|---------|----------|
| Browser screenshots fill context | API-first: YouTube Data API + yt-dlp, no browser needed |
| Single session accumulates too much data | Each worker has fresh context, does one job, exits |
| Research state lost between sessions | Memory persists in SQLite across all sessions |
| Manual intervention required | Cron triggers supervisor, supervisor dispatches workers |
| Can't run overnight | Workers are headless Claude sessions, no UI needed |

## Setup

### Step 1: Store Channel Configuration

```bash
# Store your channel
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "My channel: @myhandle
   Niche: [your niche description]
   Target audience: [audience description]
   Channel voice: [voice description]
   Content focus: [what topics you cover]"

# Store competitors (one entry per competitor for easy updates)
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor1 - [brief description of their content]"

memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor2 - [brief description of their content]"

memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor3 - [brief description of their content]"
```

### Step 2: Create Pipeline Tasks

Add tasks to TODO.md for the supervisor:

```markdown
- [ ] yt-intel YouTube channel intel scan @runner #youtube ~30m
- [ ] yt-research YouTube topic research @runner #youtube ~45m blocked-by:yt-intel
- [ ] yt-scripts YouTube script generation @runner #youtube ~30m blocked-by:yt-research
- [ ] yt-optimize YouTube metadata optimization @runner #youtube ~20m blocked-by:yt-scripts
- [ ] yt-thumbnails YouTube thumbnail A/B testing @runner #youtube ~30m blocked-by:yt-optimize
```

### Step 3: Create Supervisor Batch

```bash
# Add tasks to supervisor
supervisor-helper.sh add yt-intel --repo "$(pwd)" \
  --description "Scan competitor channels for new videos and outliers"

supervisor-helper.sh add yt-research --repo "$(pwd)" \
  --description "Analyze content gaps and trending topics from intel data"

supervisor-helper.sh add yt-scripts --repo "$(pwd)" \
  --description "Generate draft scripts for top 3 topic opportunities"

supervisor-helper.sh add yt-optimize --repo "$(pwd)" \
  --description "Generate titles, tags, descriptions for draft scripts"

supervisor-helper.sh add yt-thumbnails --repo "$(pwd)" \
  --description "Generate and score thumbnail variants for draft videos"

# Create batch with sequential execution (dependencies)
supervisor-helper.sh batch "youtube-daily" \
  --concurrency 1 \
  --tasks "yt-intel,yt-research,yt-scripts,yt-optimize,yt-thumbnails"
```

### Step 4: Install Cron

```bash
# Install supervisor cron pulse (checks every 2 minutes)
supervisor-helper.sh cron install

# Or add a specific YouTube pipeline cron job
cron-helper.sh add "youtube-pipeline" \
  --schedule "0 6 * * *" \
  --command "supervisor-helper.sh pulse --batch youtube-daily"
```

This runs the pipeline every day at 6 AM.

## Worker Instructions

Each worker receives specific instructions via the supervisor. Here are the prompts:

### Worker 1: Channel Intel

```text
You are a YouTube research worker. Your task is to scan competitor channels.

1. Recall competitor list: memory-helper.sh recall --namespace youtube "Competitor"
2. For each competitor:
   a. Run: youtube-helper.sh channel @handle json
   b. Run: youtube-helper.sh videos @handle 20 json
   c. Calculate: median views, outlier threshold (3x median)
   d. Identify new videos since last scan
   e. Flag any outlier videos
3. Store findings: memory-helper.sh store --namespace youtube
   "Intel scan [date]: @handle - [new videos count], [outlier count], [notable findings]"
4. Report via mailbox: mail-helper.sh send --type status_report
   "YouTube intel scan complete. [summary]"
```

### Worker 2: Topic Research

```text
You are a YouTube research worker. Your task is to find content opportunities.

1. Recall intel data: memory-helper.sh recall --namespace youtube "Intel scan"
2. Recall my channel topics: memory-helper.sh recall --namespace youtube "My channel"
3. Extract topic clusters from competitor videos (group by title keywords)
4. Identify gaps: topics competitors cover that I don't
5. Check for trending signals: topics multiple competitors covered recently
6. For top 5 opportunities:
   a. Run: youtube-helper.sh search "[topic]" video 10
   b. Assess competition level
   c. Suggest unique angle
7. Store findings: memory-helper.sh store --namespace youtube-topics
   "Opportunity [date]: [topic] - [demand signal], [competition], [suggested angle]"
8. Report via mailbox with ranked opportunity list
```

### Worker 3: Script Generation

```text
You are a YouTube script writer. Your task is to draft scripts for top opportunities.

1. Recall opportunities: memory-helper.sh recall --namespace youtube-topics "Opportunity"
2. Recall channel voice: memory-helper.sh recall --namespace youtube "Channel voice"
3. Select top 3 opportunities by demand/competition ratio
4. For each opportunity:
   a. Get competitor transcript if available: youtube-helper.sh transcript VIDEO_ID
   b. Choose storytelling framework based on content type
   c. Generate full script with hooks, pattern interrupts, CTA
   d. Save to workspace: ~/.aidevops/.agent-workspace/work/youtube/scripts/
5. Store script metadata in memory
6. Report via mailbox with script summaries
```

### Worker 4: Optimization

```text
You are a YouTube metadata optimizer. Your task is to generate titles, tags, and descriptions.

1. Read draft scripts from: ~/.aidevops/.agent-workspace/work/youtube/scripts/
2. For each script:
   a. Generate 5 title options with CTR signals
   b. Generate 20-30 tags across all categories
   c. Write SEO-optimized description with timestamps
   d. Create thumbnail brief
   e. Save alongside script file
3. Store successful patterns in memory
4. Report via mailbox with final deliverables summary
```

### Worker 5: Thumbnail A/B Testing

```text
You are a YouTube thumbnail production worker. Your task is to generate and score
thumbnail variants for videos in the production pipeline.

1. List draft videos: ls ~/.aidevops/.agent-workspace/work/youtube/scripts/
2. For each video with a script but no thumbnails:
   a. Generate brief: thumbnail-factory-helper.sh brief VIDEO_ID
   b. Generate 10 variants: thumbnail-factory-helper.sh generate VIDEO_ID 10
   c. Score each variant using vision AI with the generated scoring prompt
   d. Record scores: thumbnail-factory-helper.sh record-score <path> <scores>
   e. Flag variants scoring 7.5+ as ready for A/B testing
3. Download competitor thumbnails for context:
   thumbnail-factory-helper.sh competitors VIDEO_ID 5
4. Store winning patterns in memory:
   memory-helper.sh store --namespace youtube-patterns "Thumbnail: [pattern]"
5. Report via mailbox: mail-helper.sh send --type status_report
   "Thumbnail generation complete. [N] variants generated, [M] pass threshold."
```

## Monitoring

### Check Pipeline Status

```bash
# Supervisor dashboard
supervisor-helper.sh dashboard --batch youtube-daily

# Check worker status
supervisor-helper.sh status youtube-daily

# Check mailbox for reports
mail-helper.sh check

# Check quota usage
youtube-helper.sh quota
```

### View Results

```bash
# Recall latest intel
memory-helper.sh recall --namespace youtube "Intel scan" --recent

# Recall topic opportunities
memory-helper.sh recall --namespace youtube-topics "Opportunity" --recent

# List generated scripts
ls ~/.aidevops/.agent-workspace/work/youtube/scripts/

# Check patterns learned
memory-helper.sh recall --namespace youtube-patterns --recent
```

## Frequency Recommendations

| Pipeline | Frequency | Quota Budget | Best For |
|----------|-----------|-------------|----------|
| **Intel scan only** | Daily | ~50 units | Monitoring competitor uploads |
| **Full pipeline** | Weekly | ~400 units + ~$0.80 | Complete research + script + thumbnails |
| **Trending check** | 2x/week | ~200 units | Fast-moving niches |
| **Deep analysis** | Monthly | ~1000 units | Comprehensive competitor review |

With 10,000 daily quota units, you can run the full pipeline daily and still have 9,700 units for ad-hoc research.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Worker fails to start | Check `supervisor-helper.sh status` for error messages |
| Quota exceeded | Check `youtube-helper.sh quota`, reduce search calls |
| Memory not persisting | Verify `memory-helper.sh stats` shows entries |
| Stale competitor data | Run `youtube-helper.sh channel @handle` manually to verify API access |
| Cron not triggering | Check `cron-helper.sh list` and system cron logs |
| Worker context overflow | Reduce video count per competitor (50 instead of 200) |

## Workspace Structure

```text
~/.aidevops/.agent-workspace/work/youtube/
├── scripts/
│   ├── 2026-02-09-topic-name/
│   │   ├── script.md           # Full script
│   │   ├── titles.md           # Title options
│   │   ├── tags.txt            # Tag list
│   │   ├── description.md      # YouTube description
│   │   └── thumbnail-brief.md  # Thumbnail design brief
│   └── ...
├── thumbnails/
│   ├── VIDEO_ID/
│   │   ├── brief.md            # Design brief
│   │   ├── variants/           # Generated thumbnail images
│   │   └── competitors/        # Competitor thumbnails
│   └── style-library/          # Winning style templates
├── intel/
│   ├── latest-scan.json        # Most recent competitor scan
│   └── history/                # Historical scan data
└── reports/
    └── weekly-summary.md       # Pipeline summary reports
```

## Related

- `youtube.md` — Main YouTube agent
- `youtube/channel-intel.md` — Worker 1 detailed instructions
- `youtube/topic-research.md` — Worker 2 detailed instructions
- `youtube/script-writer.md` — Worker 3 detailed instructions
- `youtube/optimizer.md` — Worker 4 detailed instructions
- `youtube/thumbnail-ab-testing.md` — Worker 5 detailed instructions
- `tools/ai-assistants/headless-dispatch.md` — Supervisor architecture
- `tools/automation/cron-agent.md` — Cron job configuration
- `scripts/supervisor-helper.sh` — Supervisor CLI reference
- `scripts/thumbnail-factory-helper.sh` — Thumbnail generation and scoring CLI
