---
description: Create and search notes from agent sessions (macOS + Linux/Windows)
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

# Notes

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/notes-helper.sh [command] [args]`
- **macOS backend**: `osascript` via Notes.app (no install needed)
- **Linux/Windows backend**: `nb` (CLI notebook, `brew install nb`)
- **Setup**: `notes-helper.sh setup`
- **Related**: `tools/productivity/apple-reminders.md`, `tools/productivity/calendar.md`, `tools/productivity/contacts.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Field | macOS | Linux/Windows | Notes |
|---|---|---|---|
| Title | osascript | nb | core |
| Body/content | osascript (HTML) | nb (Markdown) | core |
| Folder/notebook | osascript | nb notebooks | core |
| Search (title+body) | osascript | nb search | core |
| Modification date | osascript | filesystem | core |
| Tags | not available | nb `--tags` | Linux only |
| Attachments | not available | nb `--content` file | limited |
| Sync | iCloud (automatic) | git remote (manual) | platform-specific |

## When to Create Notes

Create when:
- User explicitly asks ("save this as a note", "make a note of...")
- A session produces reference material worth preserving (research summaries, decision records)
- Capturing meeting notes, brainstorming output, or project documentation
- Storing information that doesn't fit TODO.md or GitHub issues (personal reference, ideas, drafts)

Do NOT create for:
- Actionable tasks (use `reminders-helper.sh` or TODO.md)
- Calendar events (use `calendar-helper.sh`)
- Contact information (use `contacts-helper.sh`)
- Code documentation (use in-repo docs)
- Temporary scratch work (use agent workspace)

## Folder Selection

Ask user if unclear. Common mappings:
- **Notes** (default): General-purpose notes
- **Work**: Meeting notes, project references, decision records
- **Personal**: Ideas, reading notes, personal reference
- **Research**: Investigation summaries, technical findings

## Usage

### Create

```bash
# Simple note
notes-helper.sh add "Project ideas" --body "Feature X, integration Y"

# With folder
notes-helper.sh add "Sprint retrospective" --body "What went well: ..." --folder Work

# Title only (empty body)
notes-helper.sh add "Read later: distributed systems paper"
```

### View and search

```bash
notes-helper.sh folders                          # List folders/notebooks
notes-helper.sh show today                       # Notes modified today
notes-helper.sh show week --folder Work          # This week's work notes
notes-helper.sh view "Sprint retrospective"      # View specific note
notes-helper.sh search "distributed systems"     # Full-text search
notes-helper.sh search "API" --folder Work       # Search within folder
```

### Manage

```bash
notes-helper.sh delete "Old draft"               # Delete a note
notes-helper.sh sync                             # Sync (nb only; macOS is automatic)
```

## Setup

### macOS (one-time)

```bash
notes-helper.sh setup
# No install needed. May need: System Settings > Privacy & Security > Automation
```

All accounts from System Settings > Internet Accounts appear as folders automatically.

### Linux/Windows (one-time)

```bash
notes-helper.sh setup
# Requires: nb (brew install nb)
# Optional: configure git remote for sync (nb remote set <url>)
```

## Integration

Agents call helper directly:

```bash
~/.aidevops/agents/scripts/notes-helper.sh add "Research: ${topic}" \
  --body "${summary}" --folder Work
```

## Cross-tool Workflow

```bash
# 1. Save research findings as a note
notes-helper.sh add "API comparison" --body "${findings}" --folder Work
# 2. Create a reminder to follow up
reminders-helper.sh add "Review API comparison note" --due "next Monday" --list Work
# 3. Block time to discuss
calendar-helper.sh add "API review meeting" --start "2026-04-07 14:00" --end "2026-04-07 15:00"
```

## Platform Differences

| Capability | macOS (Notes.app) | Linux/Windows (nb) |
|---|---|---|
| Format | Rich text (HTML) | Markdown |
| Sync | iCloud (automatic) | Git remote (manual) |
| Offline | yes | yes |
| Encryption | per-note lock | not built-in |
| CLI install | none needed | `brew install nb` |
| Search speed | slower (AppleScript) | fast (ripgrep) |

## Accounts

- **macOS**: All Internet Accounts (iCloud, Google, etc.) appear as separate folders.
- **Linux/Windows**: Notebooks are directories. Use `nb notebooks add <name>` to create. Optional git remote for sync.
