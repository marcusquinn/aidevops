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
- **macOS**: `remindctl` (`brew install steipete/tap/remindctl`) + osascript for flag
- **Linux**: `todoman` + `vdirsyncer` (`pipx install todoman vdirsyncer`)
- **Setup**: `reminders-helper.sh setup`
- **Related**: `tools/productivity/caldav-calendar-skill.md` (calendar events)

<!-- AI-CONTEXT-END -->

## Field Coverage

| Field | macOS | Linux | Flag |
|---|---|---|---|
| Title | `--title` | `--title` | core |
| Notes | `--notes` | `--notes` | core |
| URL | `--url` (notes) | `--url` (notes) | workaround |
| Due | `--due` | `--due` | core |
| List | `--list` | `--list` | core |
| Tags | warn | `--tags` | Linux only |
| Flag | `--flag` (osascript) | `--flag` (notes) | macOS native |
| Priority | `--priority` | `--priority` | core |
| Location | warn | `--location` | Linux only |

URL/Flag: prepended to notes if native CLI support missing.

## When to Create Reminders

Create when:
- User explicitly asks ("remind me to...", "set a reminder for...")
- Task has a deadline requiring action outside dev session
- Routine/mission produces follow-up requiring human action
- Waiting on external dependency with check-back date
- Physical world actions (calls, meetings, purchases)

Do NOT create for:
- Items in `TODO.md` / GitHub issues (use task system)
- Automated checks (use launchd/cron)
- Future agent-executable tasks

## List Selection

Ask user if unclear. Common mappings:
- **Work**: Work tasks, deadlines (medium-high)
- **Personal/Reminders**: Errands, health, calls, bills (low-high)
- **Shopping/Groceries**: Shopping items (none-low)
- **Finance**: Bills/payments (high)

Use default list mapping from config if available.

## Usage

### Create

```bash
# Simple
reminders-helper.sh add "Buy milk" --list Shopping

# Full: due, priority, flag, notes, URL
reminders-helper.sh add "Review report" --list Work \
  --due "next Friday" --priority high --flag \
  --notes "Found via RSS" --url "https://example.com"

# Linux only: tags, location
reminders-helper.sh add "Pick up package" --list Personal \
  --location "Post Office" --tags "errands,urgent"
```

### Manage

```bash
reminders-helper.sh lists                          # List all lists
reminders-helper.sh show today                     # Today's reminders
reminders-helper.sh show overdue --list Work       # Overdue in Work
reminders-helper.sh complete 1                     # Complete by index
reminders-helper.sh edit 2 --priority high         # Edit fields
reminders-helper.sh sync                           # CalDAV sync (Linux)
JSON_OUTPUT=true reminders-helper.sh show today    # JSON for agents
```

## Due Date Formats

- **macOS**: Natural language (`today`, `tomorrow`, `next Monday`, `in 2 hours`, `April 15`).
- **Linux**: ISO-style (`2026-04-15`) or configured format.

## Setup

### macOS

```bash
reminders-helper.sh setup
# Manual: brew install steipete/tap/remindctl && remindctl authorize
# Enable in System Settings > Privacy & Security > Reminders
```

### Linux

```bash
reminders-helper.sh setup
# Manual: pipx install todoman vdirsyncer
# Config: ~/.config/vdirsyncer/config + ~/.config/todoman/config.py
# Sync: vdirsyncer discover && vdirsyncer sync
```

## Integration

Agents call helper directly:

```bash
~/.aidevops/agents/scripts/reminders-helper.sh add "Follow up" \
  --list Work --due "in 3 days" --notes "Context: ${details}"
```

### Routine/Mission

```bash
# Routine follow-up
reminders-helper.sh add "ACTION: ${desc}" --list Work --due "${deadline}"

# Mission dependency
reminders-helper.sh add "MISSION: ${name} — ${action}" --notes "${details}"
```

## Accounts

- **macOS**: All Internet Accounts (iCloud, Google, etc.) accessible via list name.
- **Linux**: Requires `[pair]` + `[storage]` in `vdirsyncer/config`. Lists appear as directories.
