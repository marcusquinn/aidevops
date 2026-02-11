---
description: Configure YouTube channel and competitor tracking for research and content strategy
agent: Build+
mode: subagent
---

Configure YouTube channel settings, competitor tracking, and niche definition for ongoing research.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Test YouTube API Access

```bash
~/.aidevops/agents/scripts/youtube-helper.sh auth-test
```

If authentication fails, guide the user to set up their service account key.

### Step 2: Gather Channel Information

Prompt the user for:

1. **Your channel handle** (e.g., @myhandle)
2. **Niche/topic** (e.g., "AI coding tools", "productivity software")
3. **Competitor channels** (3-5 handles, e.g., @competitor1 @competitor2)

If the user provides these in $ARGUMENTS, parse them. Otherwise, ask interactively.

### Step 3: Validate Channels

For each channel (yours + competitors):

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle
```

Verify the channel exists and display basic stats (subscribers, videos, total views).

### Step 4: Store Configuration in Memory

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"
```

Also store individual competitor profiles:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type CODEBASE_PATTERN \
  --namespace youtube \
  "Competitor @handle: [subscribers] subs, [videos] videos, [avg_views] avg views/video"
```

### Step 5: Run Initial Competitor Comparison

```bash
~/.aidevops/agents/scripts/youtube-helper.sh competitors @myhandle @comp1 @comp2 @comp3
```

Display the comparison table and highlight key insights:
- Who has the highest views/video ratio?
- Who has the best views/subscriber ratio?
- What's the subscriber gap between you and competitors?

### Step 6: Offer Next Steps

```text
Setup complete! Next steps:

1. Run /youtube research @competitor to analyze their content strategy
2. Run /youtube research trending to find trending topics in your niche
3. Set up automated monitoring with content/distribution/youtube/pipeline.md
4. Generate your first script with /youtube script "topic"

Your configuration is stored in memory and will persist across sessions.
```

## Options

| Command | Purpose |
|---------|---------|
| `/youtube setup` | Interactive setup (prompts for all info) |
| `/youtube setup @myhandle "niche" @comp1 @comp2` | Quick setup with args |
| `/youtube setup --reconfigure` | Update existing configuration |
| `/youtube setup --show` | Display current configuration |

## Examples

**Interactive setup:**

```text
User: /youtube setup
AI: Let's configure your YouTube research setup.

    Testing YouTube API access...
    ✓ Authentication successful

    What's your YouTube channel handle? (e.g., @myhandle)
User: @techreviews
AI: Great! What's your niche or main topic?
User: AI coding tools and productivity software
AI: Perfect. Now list 3-5 competitor channels (space-separated):
User: @fireship @ThePrimeagen @CodeReport
AI: Validating channels...

    ✓ @techreviews - 12.5K subscribers, 87 videos
    ✓ @fireship - 3.2M subscribers, 245 videos
    ✓ @ThePrimeagen - 890K subscribers, 1,234 videos
    ✓ @CodeReport - 156K subscribers, 312 videos

    Competitor Comparison:

    Channel          | Subscribers  | Total Views     | Videos | Views/Video
    -----------------|--------------|-----------------|--------|-------------
    @fireship        |    3,200,000 |     450,000,000 |    245 |   1,836,735
    @ThePrimeagen    |      890,000 |     120,000,000 |  1,234 |      97,246
    @CodeReport      |      156,000 |      28,000,000 |    312 |      89,744
    @techreviews     |       12,500 |       1,200,000 |     87 |      13,793

    Key Insights:
    - @fireship has exceptional views/video ratio (1.8M avg)
    - You're averaging 13.8K views/video vs competitors' 89K-1.8M
    - Subscriber gap: 143.5K to reach @CodeReport's level

    Configuration saved to memory (namespace: youtube)

    Next steps:
    1. /youtube research @fireship - Analyze their top-performing content
    2. /youtube research trending - Find trending topics in your niche
    3. /youtube script "topic" - Generate your first script
```

**Quick setup with arguments:**

```text
User: /youtube setup @techreviews "AI coding tools" @fireship @ThePrimeagen
AI: Setting up YouTube research for @techreviews...

    ✓ Channel validated: @techreviews (12.5K subs)
    ✓ Niche: AI coding tools
    ✓ Competitors: @fireship, @ThePrimeagen

    Configuration saved. Run /youtube research to start analyzing competitors.
```

**Show current configuration:**

```text
User: /youtube setup --show
AI: Current YouTube Configuration:

    Your Channel: @techreviews
    Niche: AI coding tools and productivity software
    Competitors:
      - @fireship (3.2M subs, 1.8M avg views/video)
      - @ThePrimeagen (890K subs, 97K avg views/video)
      - @CodeReport (156K subs, 90K avg views/video)

    Last updated: 2026-02-10

    Run /youtube setup --reconfigure to update.
```

## Related

- `content/distribution/youtube/youtube.md` - Main YouTube agent
- `content/distribution/youtube/channel-intel.md` - Competitor analysis
- `content/distribution/youtube/pipeline.md` - Automated monitoring
- `youtube-helper.sh` - YouTube Data API wrapper
- `memory-helper.sh` - Cross-session persistence
