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

# Contacts

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/contacts-helper.sh [command] [args]`
- **macOS backend**: `osascript` via Contacts.app (JXA for reads, AppleScript for writes)
- **Linux backend**: `khard` + `vdirsyncer` (CardDAV)
- **Setup**: `contacts-helper.sh setup`
- **Related**: `tools/productivity/calendar.md`, `tools/productivity/apple-reminders.md`, `tools/productivity/notes.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Field | macOS | Linux | Notes |
|---|---|---|---|
| First/Last name, Organization, Job title, Email, Phone, Notes | osascript | khard | full read/write |
| Postal addresses, URLs/websites, Birthday | osascript (read) | khard | read-only on macOS |
| Social profiles | limited | khard | Linux has better support |
| Photos, Relationships | — | — | no CLI support |

## When to Use Contacts

**Look up** when: user needs email/phone/address for a person, composing email, creating a calendar event with someone, or a workflow needs to reach someone.

**Create** when: user explicitly asks, a new business relationship is established, or an agent workflow discovers contact info the user should keep. Always require user confirmation — contacts sync to all devices.

**Do NOT create** for temporary interactions or info already in a CRM.

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

## Setup

```bash
contacts-helper.sh setup
```

- **macOS**: no install needed. Grant access: System Settings > Privacy & Security > Contacts. All accounts from Internet Accounts appear automatically.
- **Linux**: requires `khard` + `vdirsyncer`. Example `~/.config/khard/khard.conf`:

```ini
[addressbooks]
[[contacts]]
path = ~/.local/share/contacts/
```

## Cross-tool Workflow

```bash
# 1. Look up contact
contacts-helper.sh show "Andrew"
# 2. Create a reminder to call them
reminders-helper.sh add "Call Andrew" --due tomorrow --priority medium
# 3. Block calendar time for the call
calendar-helper.sh add "Call with Andrew" --start "2026-04-05 10:00" --end "2026-04-05 10:30"
```
