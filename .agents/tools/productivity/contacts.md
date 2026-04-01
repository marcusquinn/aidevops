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
- **Related**: `tools/productivity/calendar.md`, `tools/productivity/apple-reminders.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Contacts field | macOS | Linux | Notes |
|---|---|---|---|
| First/Last name | osascript | khard | core |
| Organization | osascript | khard | core |
| Job title | osascript | khard | core |
| Email addresses | osascript | khard | core |
| Phone numbers | osascript | khard | core |
| Postal addresses | osascript (read) | khard | read on macOS, full on Linux |
| Notes | osascript | khard | core |
| URLs/websites | osascript (read) | khard | read on macOS, full on Linux |
| Birthday | osascript (read) | khard | read on macOS, full on Linux |
| Social profiles | limited | khard | Linux has better support |
| Photos | not available | not available | no CLI support |
| Relationships | not available | not available | no CLI support |

## When Agents Should Use Contacts

Look up a contact when:

- User mentions a person by name and needs their email/phone/address
- Composing an email and need the recipient's address
- Creating a calendar event with a person (look up their details)
- A workflow needs to reach someone (outreach, follow-up)

Create a contact when:

- User explicitly asks ("save this contact", "add them to my contacts")
- A new business relationship is established and user wants it recorded
- An agent workflow discovers contact info the user should keep

Do NOT create contacts for:

- Temporary or one-off interactions
- Information already in a CRM (use the CRM instead)
- Without user confirmation (contacts sync to all devices)

## Usage

### Search and look up

```bash
# Search by name
contacts-helper.sh search "John"

# Full details for a contact
contacts-helper.sh show "John Smith"

# Quick email lookup
contacts-helper.sh email "Smith"

# Quick phone lookup
contacts-helper.sh phone "Smith"
```

### Create a contact

```bash
# Basic contact
contacts-helper.sh add --first John --last Smith --email john@example.com

# Full contact
contacts-helper.sh add --first Jane --last Doe \
  --org "Acme Corp" --title "CTO" \
  --email jane@acme.com --phone "+44123456789" \
  --notes "Met at DevOps conference 2026"
```

### List addressbooks

```bash
contacts-helper.sh books
```

## Setup

### macOS (one-time)

```bash
contacts-helper.sh setup
# No install needed. May need: System Settings > Privacy & Security > Contacts
```

All accounts from System Settings > Internet Accounts appear automatically.

### Linux (one-time)

```bash
contacts-helper.sh setup
# Requires: khard + vdirsyncer with CardDAV config
```

Example `~/.config/khard/khard.conf`:

```ini
[addressbooks]
[[contacts]]
path = ~/.local/share/contacts/
```

## Integration with Other Agents

```bash
# Look up a contact's email for outreach:
~/.aidevops/agents/scripts/contacts-helper.sh email "Client Name"

# Create a contact after a business interaction:
~/.aidevops/agents/scripts/contacts-helper.sh add \
  --first "New" --last "Client" \
  --org "Their Company" --email "client@company.com" \
  --notes "Referred by existing client, interested in consulting"
```

### Cross-tool workflow

```bash
# 1. Look up contact
contacts-helper.sh show "Andrew"
# 2. Create a reminder to call them
reminders-helper.sh add "Call Andrew" --due tomorrow --priority medium
# 3. Block calendar time for the call
calendar-helper.sh add "Call with Andrew" --start "2026-04-05 10:00" --end "2026-04-05 10:30"
```
