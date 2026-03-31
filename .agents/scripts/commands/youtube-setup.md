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
3. **Channel voice** (e.g., "data-driven, conversational, mildly contrarian")
4. **Target audience** (e.g., "indie founders evaluating AI tools")
5. **Competitor channels** (3-5 handles, e.g., @competitor1 @competitor2)

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

~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "Channel voice: [voice description]."

~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "Audience: [target audience]."
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
3. Set up automated monitoring with content/distribution-youtube-pipeline.md
4. Generate your first script with /youtube script "topic"

Your configuration is stored in memory and will persist across sessions.

The explicit `Channel voice` entry ensures `/youtube script` and the script-writer guide can reliably recall it via FTS5 full-text search. Phrase stored entries around likely search tokens such as `Channel voice` instead of relying on exact string equality.
```

## Options

| Command | Purpose |
|---------|---------|
| `/youtube setup` | Interactive setup (prompts for all info) |
| `/youtube setup @myhandle "niche" @comp1 @comp2` | Quick setup with args |
| `/youtube setup --reconfigure` | Update existing configuration |
| `/youtube setup --show` | Display current configuration |

## Related

- `content/distribution-youtube.md` - Main YouTube agent
- `content/distribution-youtube-channel-intel.md` - Competitor analysis
- `content/distribution-youtube-pipeline.md` - Automated monitoring
- `youtube-helper.sh` - YouTube Data API wrapper
- `memory-helper.sh` - Cross-session persistence
