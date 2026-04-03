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
notes-helper.sh add "Project ideas" --body "Feature X, integration Y"
notes-helper.sh add "Sprint retrospective" --body "What went well: ..." --folder Work
notes-helper.sh add "Read later: distributed systems paper"   # title only
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
notes-helper.sh delete "Old draft"
notes-helper.sh sync                             # nb only; macOS is automatic
```

### Agent integration

```bash
~/.aidevops/agents/scripts/notes-helper.sh add "Research: ${topic}" \
  --body "${summary}" --folder Work
```

## Setup

**macOS** (no install needed): `notes-helper.sh setup` — may need System Settings > Privacy & Security > Automation. All Internet Accounts appear as folders automatically.

**Linux/Windows**: `notes-helper.sh setup` — requires `nb` (`brew install nb`). Optional: `nb remote set <url>` for git sync.

## Cross-tool Workflow

```bash
notes-helper.sh add "API comparison" --body "${findings}" --folder Work
reminders-helper.sh add "Review API comparison note" --due "next Monday" --list Work
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
| Tags | not available | `--tags` flag |
| Attachments | not available | `--content` file (limited) |
