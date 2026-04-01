---
description: Create and manage reminders from agent sessions (macOS + Linux)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Reminders

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/reminders-helper.sh [command] [args]`
- **macOS backend**: `remindctl` (`brew install steipete/tap/remindctl`) + osascript for flag
- **Linux backend**: `todoman` + `vdirsyncer` (`pipx install todoman vdirsyncer`)
- **Setup**: `reminders-helper.sh setup` (install + authorize/configure)
- **Related**: `tools/productivity/caldav-calendar-skill.md` (calendar events, not tasks)

<!-- AI-CONTEXT-END -->

## Field Coverage

| Reminders field | macOS | Linux | Flag |
|---|---|---|---|
| Title | `--title` | `--title` | core |
| Notes | `--notes` | `--notes` | core |
| URL | `--url` (in notes) | `--url` (in notes) | workaround |
| Date + Time | `--due` | `--due` | core |
| List | `--list` | `--list` | core |
| Tags | warn only | `--tags` | Linux only |
| Flag | `--flag` (osascript) | `--flag` (in notes) | macOS native |
| Priority | `--priority` | `--priority` | core |
| Location | warn only | `--location` | Linux only |
| When Messaging | not available | N/A | iOS-only trigger |
| Assign Reminder | not available | N/A | no CLI support |
| Add Image | not available | N/A | no CLI support |

URL is prepended to notes as a clickable line (no CLI exposes the native URL field).
Flag uses osascript post-creation on macOS; prepended as `[FLAGGED]` in notes on Linux.

## When Agents Should Create Reminders

Create a reminder when:

- User explicitly asks ("remind me to...", "set a reminder for...")
- A task has a deadline the user needs to act on outside the dev session
- A routine/mission produces a follow-up that requires human action
- Waiting on an external dependency with a check-back date
- User needs to do something in the physical world (calls, meetings, purchases)

Do NOT create reminders for:

- Things tracked in TODO.md / GitHub issues (that's the task system)
- Automated checks (use launchd/cron instead)
- Things the agent can do itself in a future session

## List Selection

Ask the user which list to use if unclear. Common patterns:

| Context | Likely list | Priority |
|---------|-------------|----------|
| Work tasks, deadlines | Work | medium-high |
| Personal errands | Personal / Reminders | low-medium |
| Shopping items | Shopping / Groceries | none-low |
| Health/medical | Personal | medium |
| Calls to make | Personal | medium |
| Bills/payments | Personal or Finance | high |

If the user has configured a default list mapping in their config, use it. Otherwise infer from context and confirm on first use.

## Usage

### Create a reminder

```bash
# Simple
reminders-helper.sh add "Buy milk" --list Shopping

# With due date, priority, and flag
reminders-helper.sh add "Review quarterly report" --list Work \
  --due "next Friday" --priority high --flag

# With notes and URL
reminders-helper.sh add "Read article on CalDAV" \
  --url "https://example.com/article" --notes "Found via RSS feed"

# With tags (Linux) and location (Linux)
reminders-helper.sh add "Pick up package" --list Personal \
  --location "Post Office" --tags "errands,urgent"

# Full example
reminders-helper.sh add "Call dentist" --list Personal \
  --due "Monday 9am" --priority medium --flag \
  --notes "Ask about cleaning schedule" --url "https://dentist.example.com"
```

### Other commands

```bash
reminders-helper.sh lists                          # List all lists
reminders-helper.sh show today                     # Today's reminders
reminders-helper.sh show overdue --list Work       # Overdue in Work
reminders-helper.sh show week                      # This week
reminders-helper.sh complete 1                     # Complete by index
reminders-helper.sh edit 2 --priority high         # Edit fields
reminders-helper.sh sync                           # CalDAV sync (Linux)
JSON_OUTPUT=true reminders-helper.sh show today    # JSON for agents
```

## Due Date Formats

macOS (`remindctl`) accepts natural language: `today`, `tomorrow`, `next Monday`, `in 2 hours`, `in 3 days`, `April 15`, `end of month`.

Linux (`todoman`) uses the configured date format (default `%Y-%m-%d`): `2026-04-15`.

## Setup

### macOS (one-time)

```bash
reminders-helper.sh setup
# Or manually:
# 1. brew install steipete/tap/remindctl
# 2. remindctl authorize
# 3. System Settings > Privacy & Security > Reminders > enable terminal app
```

All accounts from System Settings > Internet Accounts (iCloud, CalDAV, Google, etc.) appear automatically.

### Linux (one-time)

```bash
reminders-helper.sh setup
# Or manually:
# 1. pipx install todoman vdirsyncer
# 2. Configure ~/.config/vdirsyncer/config (CalDAV credentials)
# 3. Configure ~/.config/todoman/config.py (point to synced calendars)
# 4. vdirsyncer discover && vdirsyncer sync
```

See `reminders-helper.sh help` for example vdirsyncer/todoman configs.

## Integration with Routines and Missions

Other agents call the helper script directly:

```bash
# From any agent with bash access:
~/.aidevops/agents/scripts/reminders-helper.sh add "Follow up with client" \
  --list Work --due "in 3 days" --priority medium --flag \
  --notes "Re: proposal sent on $(date +%Y-%m-%d)"
```

### Routine integration

When a `/routine` produces a human-action follow-up:

```bash
reminders-helper.sh add "ACTION: ${follow_up_description}" \
  --list Work --due "${deadline}" --priority "${urgency}"
```

### Mission integration

When a mission identifies a time-sensitive human dependency:

```bash
reminders-helper.sh add "MISSION: ${mission_name} — ${action_needed}" \
  --list Work --due "${target_date}" --notes "Mission context: ${details}"
```

## Accounts

**macOS**: All accounts configured in System Settings > Internet Accounts are accessible. List name is the selector -- no account specification needed. If two accounts share a list name, rename one to disambiguate.

**Linux**: Each CalDAV account needs a `[pair]` + `[storage]` block in `~/.config/vdirsyncer/config`. After `vdirsyncer discover && vdirsyncer sync`, all lists appear as directories under the todoman path.
