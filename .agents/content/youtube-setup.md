---
description: Configure YouTube channel and competitor tracking for research and content strategy
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Configure YouTube channel settings, competitor tracking, and niche definition for ongoing research.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Test YouTube API Access

```bash
~/.aidevops/agents/scripts/youtube-helper.sh auth-test
```

On failure, guide user to set up their service account key.

### Step 2: Gather Channel Information

Parse from $ARGUMENTS if provided, otherwise prompt interactively for:
- **Channel handle** (e.g., @myhandle)
- **Niche/topic** (e.g., "AI coding tools", "productivity software")
- **Competitor channels** (3-5 handles, e.g., @competitor1 @competitor2)

### Step 3: Validate Channels

For each channel (yours + competitors), verify existence and display stats (subscribers, videos, total views):

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle
```

### Step 4: Store Configuration in Memory

Store channel config:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"
```

Store each competitor profile:

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

Display comparison table highlighting: views/video ratio, views/subscriber ratio, subscriber gap.

### Step 6: Offer Next Steps

```text
Setup complete! Next steps:

1. Run /youtube research @competitor to analyze their content strategy
2. Run /youtube research trending to find trending topics in your niche
3. Set up automated monitoring with content/distribution-youtube-pipeline.md
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

## Related

- `content/distribution-youtube.md` - Main YouTube agent
- `content/distribution-youtube-channel-intel.md` - Competitor analysis
- `content/distribution-youtube-pipeline.md` - Automated monitoring
- `youtube-helper.sh` - YouTube Data API wrapper
- `memory-helper.sh` - Cross-session persistence
