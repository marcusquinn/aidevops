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
- **macOS**: `remindctl` (`brew install steipete/tap/remindctl`) + osascript for flag; natural language dates (`today`, `next Monday`, `in 2 hours`)
- **Linux**: `todoman` + `vdirsyncer` (`pipx install todoman vdirsyncer`); ISO dates (`2026-04-15`)
- **Setup**: `reminders-helper.sh setup` — installs deps, guides auth (macOS: Privacy & Security; Linux: `vdirsyncer/config` + `todoman/config.py`)
- **Accounts**: macOS — all Internet Accounts via list name; Linux — `[pair]`+`[storage]` in `vdirsyncer/config`, lists as directories
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

**Create:** user asks, deadline needing human action outside dev session, waiting on external dependency, physical world actions (calls, meetings, purchases).

**Do NOT create:** items in `TODO.md`/GitHub issues (use task system), automated checks (use launchd/cron), future agent-executable tasks.

## List Selection

Ask user if unclear. Common mappings: **Work** (tasks, deadlines), **Personal/Reminders** (errands, health, calls, bills), **Shopping/Groceries** (shopping items), **Finance** (bills/payments).

## Usage

```bash
reminders-helper.sh add "Buy milk" --list Shopping
reminders-helper.sh add "Review report" --list Work \
  --due "next Friday" --priority high --flag \
  --notes "Context: ${details}" --url "https://example.com"
# Linux only: --location "Post Office" --tags "errands,urgent"

reminders-helper.sh lists                          # list all lists
reminders-helper.sh show today                     # today's reminders
reminders-helper.sh show overdue --list Work       # overdue in list
reminders-helper.sh complete 1                     # complete by index
reminders-helper.sh edit 2 --priority high         # edit fields
reminders-helper.sh sync                           # CalDAV sync (Linux)
JSON_OUTPUT=true reminders-helper.sh show today    # JSON for agents
```
