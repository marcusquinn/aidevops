---
description: Search and manage contacts from agent sessions (macOS + Linux)
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

# Contacts

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/contacts-helper.sh [command] [args]`
- **macOS**: `osascript` via Contacts.app (JXA reads, AppleScript writes) — grant access: System Settings > Privacy & Security > Contacts
- **Linux**: `khard` + `vdirsyncer` (CardDAV) — run `contacts-helper.sh setup`; config: `~/.config/khard/khard.conf`
- **Related**: `tools/productivity/calendar.md`, `tools/productivity/apple-reminders.md`, `tools/productivity/notes.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Field | macOS | Linux |
|---|---|---|
| Name, Org, Job title, Email, Phone, Notes | read/write | read/write |
| Postal addresses, URLs, Birthday | read-only | read/write |
| Social profiles | limited | full |
| Photos, Relationships | — | — |

## When to Use

**Look up**: user needs email/phone/address, composing email, creating a calendar event, or a workflow needs to reach someone.

**Create**: user explicitly asks, new business relationship established, or agent discovers contact info to keep. Always require user confirmation — contacts sync to all devices. Do NOT create for temporary interactions or info already in a CRM.

## Usage

```bash
# Search / look up
contacts-helper.sh search "John"
contacts-helper.sh show "John Smith"
contacts-helper.sh email "Smith"
contacts-helper.sh phone "Smith"
contacts-helper.sh books

# Create
contacts-helper.sh add --first John --last Smith --email john@example.com
contacts-helper.sh add --first Jane --last Doe \
  --org "Acme Corp" --title "CTO" \
  --email jane@acme.com --phone "+44123456789" \
  --notes "Met at DevOps conference 2026"
```

## Cross-tool Workflow

```bash
contacts-helper.sh show "Andrew"
reminders-helper.sh add "Call Andrew" --due tomorrow --priority medium
calendar-helper.sh add "Call with Andrew" --start "tomorrow 10:00" --end "tomorrow 10:30"
```
