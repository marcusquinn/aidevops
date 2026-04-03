---
description: Create and query calendar events from agent sessions (macOS + Linux)
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

# Calendar

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/calendar-helper.sh [command] [args]`
- **macOS backend**: `osascript` via Calendar.app (no install needed)
- **Linux backend**: `khal` + `vdirsyncer` (CalDAV)
- **Setup**: `calendar-helper.sh setup`
- **Related**: `tools/productivity/apple-reminders.md` (tasks/reminders, not events), `tools/productivity/notes.md`

<!-- AI-CONTEXT-END -->

## Field Coverage

| Calendar field | macOS | Linux | Notes |
|---|---|---|---|
| Title/summary | osascript | khal | core |
| Start date/time | osascript | khal | core |
| End date/time | osascript | khal | core |
| Location | osascript | khal `--location` | core |
| Notes/description | osascript | khal `:: desc` | core |
| URL | osascript | khal `--url` | core |
| Calendar selection | osascript | khal `-a` | core |
| All-day event | osascript | khal (date only) | core |
| Recurrence | not yet | khal `--repeat` | Linux only |
| Alarms | not yet | khal `--alarms` | Linux only |
| Categories/tags | not yet | khal `--categories` | Linux only |
| Invitees/attendees | not available | not available | no CLI support |
| Travel time | not available | N/A | macOS-only UI |
| Availability | not available | not available | no CLI support |

## When Agents Should Create Events

Create a calendar event when:

- User explicitly asks ("schedule a meeting", "add to my calendar")
- A routine produces a time-bound commitment (meeting, deadline, appointment)
- Coordinating availability across people or projects
- A reminder isn't sufficient -- the event blocks time on the calendar

Do NOT create events for:

- Tasks/reminders with no specific time block (use `reminders-helper.sh`)
- Things tracked in TODO.md / GitHub issues
- Tentative plans the user hasn't confirmed

## Usage

### View events

```bash
calendar-helper.sh show today
calendar-helper.sh show tomorrow
calendar-helper.sh show week --calendar Work
calendar-helper.sh show 2026-04-10..2026-04-15
```

### Create an event

```bash
# Timed event
calendar-helper.sh add "Team standup" \
  --start "2026-04-05 09:00" --end "2026-04-05 09:30" --calendar Work

# All-day event
calendar-helper.sh add "Company holiday" --start "2026-04-10" --allday

# With location, notes, URL
calendar-helper.sh add "Client dinner" \
  --start "2026-04-05 19:00" --end "2026-04-05 21:00" \
  --location "The Restaurant, High St" \
  --notes "Reservation for 4" \
  --url "https://restaurant.example.com"
```

### Search and list calendars

```bash
calendar-helper.sh calendars
calendar-helper.sh search "standup" --calendar Work
```

## Setup

### macOS (one-time)

```bash
calendar-helper.sh setup
# No install needed. May need: System Settings > Privacy & Security > Calendars
```

All accounts from System Settings > Internet Accounts appear automatically.

### Linux (one-time)

```bash
calendar-helper.sh setup
# Requires: khal + vdirsyncer with CalDAV config
# See caldav-calendar-skill.md for vdirsyncer configuration
```

## Integration with Other Agents

```bash
# From any agent with bash access:
~/.aidevops/agents/scripts/calendar-helper.sh add "Sprint review" \
  --start "2026-04-05 14:00" --end "2026-04-05 15:00" \
  --calendar Work --notes "Demo new features"
```

Check availability before scheduling:

```bash
calendar-helper.sh show "2026-04-05" --calendar Work
```
