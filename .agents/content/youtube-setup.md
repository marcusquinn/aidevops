---
description: Configure YouTube channel and competitor tracking for research and content strategy
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Configure YouTube channel settings, competitor tracking, and niche definition for ongoing research.

Arguments: $ARGUMENTS

## Steps

### 1. Test API Access

```bash
~/.aidevops/agents/scripts/youtube-helper.sh auth-test
```

If authentication fails, guide the user to set up their service account key.

### 2. Gather Channel Information

Collect from $ARGUMENTS or ask interactively:

1. **Channel handle** (e.g., @myhandle)
2. **Niche/topic** (e.g., "AI coding tools", "productivity software")
3. **Competitor channels** (3-5 handles, e.g., @competitor1 @competitor2)

### 3. Validate Channels

For each channel (yours + competitors):

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle
```

Verify the channel exists and display basic stats (subscribers, videos, total views).

### 4. Store Configuration

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"
```

Store individual competitor profiles:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type CODEBASE_PATTERN \
  --namespace youtube \
  "Competitor @handle: [subscribers] subs, [videos] videos, [avg_views] avg views/video"
```

### 5. Run Competitor Comparison

```bash
~/.aidevops/agents/scripts/youtube-helper.sh competitors @myhandle @comp1 @comp2 @comp3
```

Highlight: views/video ratio, views/subscriber ratio, subscriber gap.

### 6. Offer Next Steps

Confirm setup complete and suggest:

1. `/youtube research @competitor` — analyze content strategy
2. `/youtube research trending` — find trending topics in niche
3. `content/distribution-youtube-pipeline.md` — set up automated monitoring
4. `/youtube script "topic"` — generate first script

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
