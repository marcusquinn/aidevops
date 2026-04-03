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
- **Related**: `tools/productivity/caldav-calendar-skill.md` (calendar events), `tools/productivity/notes.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Field | macOS | Linux |
|---|---|---|
| Title, Notes, Due, List, Priority | core | core |
| URL | prepended to notes | prepended to notes |
| Flag | `--flag` (osascript) | prepended to notes |
| Tags | warn (unsupported) | `--tags` |
| Location | warn (unsupported) | `--location` |

## When to Create Reminders

**Create:** user asks ("remind me to..."), deadline requiring action outside dev session, routine/mission follow-up needing human action, waiting on external dependency, physical world actions (calls, meetings, purchases).

**Do NOT create:** items in `TODO.md`/GitHub issues (use task system), automated checks (use launchd/cron), future agent-executable tasks.

## List Selection

Ask user if unclear. Common mappings: **Work** (tasks, deadlines), **Personal/Reminders** (errands, health, calls, bills), **Shopping/Groceries** (shopping items), **Finance** (bills/payments). Use default list mapping from config if available.

## Usage

```bash
# Create — simple
reminders-helper.sh add "Buy milk" --list Shopping

# Create — full options
reminders-helper.sh add "Review report" --list Work \
  --due "next Friday" --priority high --flag \
  --notes "Context: ${details}" --url "https://example.com"

# Create — Linux only (tags, location)
reminders-helper.sh add "Pick up package" --list Personal \
  --location "Post Office" --tags "errands,urgent"

# Manage
reminders-helper.sh lists                          # list all lists
reminders-helper.sh show today                     # today's reminders
reminders-helper.sh show overdue --list Work       # overdue in list
reminders-helper.sh complete 1                     # complete by index
reminders-helper.sh edit 2 --priority high         # edit fields
reminders-helper.sh sync                           # CalDAV sync (Linux)
JSON_OUTPUT=true reminders-helper.sh show today    # JSON for agents
```

## Due Date Formats

- **macOS**: Natural language (`today`, `tomorrow`, `next Monday`, `in 2 hours`, `April 15`).
- **Linux**: ISO-style (`2026-04-15`) or configured format.

## Setup

Run `reminders-helper.sh setup` — installs platform dependencies and guides authorization.

- **macOS**: Requires Reminders permission in System Settings > Privacy & Security.
- **Linux**: Requires `vdirsyncer/config` + `todoman/config.py`; run `vdirsyncer discover && vdirsyncer sync` after setup.

## Accounts

- **macOS**: All Internet Accounts (iCloud, Google, etc.) accessible via list name.
- **Linux**: Requires `[pair]` + `[storage]` in `vdirsyncer/config`. Lists appear as directories.
