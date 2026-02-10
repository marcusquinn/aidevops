---
description: Set up YouTube channel profile, competitors, and API authentication
agent: YouTube
mode: subagent
---

Configure your YouTube channel, competitors, and API access for research workflows.

Arguments: $ARGUMENTS

## Usage

```text
/youtube setup                          # Interactive guided setup
/youtube setup auth                     # Test API authentication only
/youtube setup channel @myhandle        # Store your channel profile
/youtube setup competitor @handle       # Add a competitor
/youtube setup competitors              # List stored competitors
/youtube setup status                   # Show full configuration status
```

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the setup mode:

| Argument | Action |
|----------|--------|
| (none) | Run full interactive setup |
| `auth` | Test YouTube Data API authentication |
| `channel @handle` | Store channel profile in memory |
| `competitor @handle` | Add a competitor to memory |
| `competitors` | List all stored competitors |
| `status` | Show configuration status |

### Step 2: Route to Action

**For `auth` or no arguments (start with auth test):**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh auth-test
```

If auth fails, guide the user:

1. They need a Google Cloud service account with YouTube Data API v3 enabled
2. Store the key file: `cp <key.json> ~/.config/aidevops/keys/evergreen-je-sa.json && chmod 600 ~/.config/aidevops/keys/evergreen-je-sa.json`
3. Add to credentials: `aidevops secret set GCP_SA_KEY_FILE`

**For `channel @handle`:**

```bash
# Verify the channel exists
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle

# Store in memory
~/.aidevops/agents/scripts/memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "My channel: @handle. Niche: [ask user]. Target audience: [ask user]. Channel voice: [ask user]."
```

**For `competitor @handle`:**

```bash
# Verify the channel exists and get stats
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle

# Store in memory
~/.aidevops/agents/scripts/memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @handle - [subscriber count] subs, [video count] videos. Focus: [brief description]."
```

**For `competitors`:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "Competitor"
```

**For `status`:**

```bash
# Check auth
~/.aidevops/agents/scripts/youtube-helper.sh auth-test

# Check quota
~/.aidevops/agents/scripts/youtube-helper.sh quota

# Recall channel config
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "My channel"

# Recall competitors
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "Competitor"
```

### Step 3: Interactive Setup (no arguments)

When no arguments are provided, run the full guided setup:

1. **Test authentication** -- run `youtube-helper.sh auth-test`
2. **Ask for channel handle** -- verify with `youtube-helper.sh channel @handle`
3. **Ask for niche/topic** -- what the channel covers
4. **Ask for target audience** -- who watches
5. **Ask for channel voice** -- casual/formal, humor level, expertise positioning
6. **Store channel profile** in memory namespace `youtube`
7. **Ask for 3-5 competitors** -- verify each with `youtube-helper.sh channel @handle`
8. **Store each competitor** in memory namespace `youtube`
9. **Run initial comparison** -- `youtube-helper.sh competitors @me @comp1 @comp2 @comp3`
10. **Show summary** of stored configuration

Present each step with numbered options:

```text
YouTube Setup - Step 1/5: Authentication

Testing YouTube Data API access...
[OK] Authentication successful (service account: sa@project.iam.gserviceaccount.com)

1. Continue to channel setup
2. Reconfigure authentication
```

### Step 4: Report Configuration

After setup, display:

```text
YouTube Configuration:
  Channel:      @handle ([subscriber count] subscribers)
  Niche:        [niche description]
  Audience:     [audience description]
  Voice:        [voice description]
  Competitors:  @comp1, @comp2, @comp3
  API Status:   Authenticated
  Quota Today:  [X] / 10,000 units

Ready to use:
  /youtube research    -- Find topic opportunities
  /youtube script      -- Generate video scripts
```

## Prerequisites

- YouTube Data API v3 service account key
- `youtube-helper.sh` accessible at `~/.aidevops/agents/scripts/`
- `memory-helper.sh` for cross-session persistence

## Related

- `youtube.md` -- Main YouTube agent
- `youtube/pipeline.md` -- Automated pipeline setup
- `youtube-helper.sh` -- YouTube Data API wrapper
