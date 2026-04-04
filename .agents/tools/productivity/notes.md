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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Notes

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/notes-helper.sh [command] [args]`
- **macOS**: `osascript` via Notes.app — no install needed; `notes-helper.sh setup` for Automation permission
- **Linux/Windows**: `nb` CLI — `brew install nb`; `notes-helper.sh setup`; optional `nb remote set <url>` for git sync
- **Folders**: Notes (default), Work, Personal, Research — ask user if unclear
- **Related**: `tools/productivity/apple-reminders.md`, `tools/productivity/calendar.md`, `tools/productivity/contacts.md`

<!-- AI-CONTEXT-END -->

## When to Create Notes

**Create**: user asks explicitly; session produces reference material (research summaries, decision records); meeting notes, brainstorming, project docs; info that doesn't fit TODO.md or GitHub issues.

**Do NOT create**: actionable tasks (`reminders-helper.sh`/TODO.md); calendar events (`calendar-helper.sh`); contact info (`contacts-helper.sh`); code docs (in-repo); temporary scratch work (agent workspace).

## Usage

```bash
# Create
notes-helper.sh add "Project ideas" --body "Feature X, integration Y"
notes-helper.sh add "Sprint retrospective" --body "What went well: ..." --folder Work
notes-helper.sh add "Read later: distributed systems paper"   # title only

# View and search
notes-helper.sh folders                          # List folders/notebooks
notes-helper.sh show today                       # Notes modified today
notes-helper.sh show week --folder Work          # This week's work notes
notes-helper.sh view "Sprint retrospective"      # View specific note
notes-helper.sh search "distributed systems"     # Full-text search
notes-helper.sh search "API" --folder Work       # Search within folder

# Manage
notes-helper.sh delete "Old draft"
notes-helper.sh sync                             # nb only; macOS is automatic
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
