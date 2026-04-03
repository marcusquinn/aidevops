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

## When to Create Events

**Do** create a calendar event when:
- User explicitly asks ("schedule a meeting", "add to my calendar")
- A routine produces a time-bound commitment (meeting, deadline, appointment)
- Coordinating availability across people or projects

**Do NOT** create events for:
- Tasks/reminders with no specific time block → use `reminders-helper.sh`
- Things tracked in TODO.md / GitHub issues
- Tentative plans the user hasn't confirmed

## Field Coverage

Core fields (title, start/end, location, notes, URL, calendar, all-day) are supported on both platforms. Linux-only extras: recurrence (`--repeat`), alarms (`--alarms`), categories (`--categories`). Invitees, travel time, and availability have no CLI support on either platform.

## Usage

```bash
# View events
calendar-helper.sh show today
calendar-helper.sh show tomorrow
calendar-helper.sh show week --calendar Work
calendar-helper.sh show 2026-04-10..2026-04-15

# Check availability before scheduling
calendar-helper.sh show "2026-04-05" --calendar Work

# List calendars / search
calendar-helper.sh calendars
calendar-helper.sh search "standup" --calendar Work

# Create: timed event
calendar-helper.sh add "Team standup" \
  --start "2026-04-05 09:00" --end "2026-04-05 09:30" --calendar Work

# Create: all-day event
calendar-helper.sh add "Company holiday" --start "2026-04-10" --allday

# Create: with location, notes, URL
calendar-helper.sh add "Client dinner" \
  --start "2026-04-05 19:00" --end "2026-04-05 21:00" \
  --location "The Restaurant, High St" \
  --notes "Reservation for 4" \
  --url "https://restaurant.example.com"

# From another agent (use full path)
~/.aidevops/agents/scripts/calendar-helper.sh add "Sprint review" \
  --start "2026-04-05 14:00" --end "2026-04-05 15:00" \
  --calendar Work --notes "Demo new features"
```

## Setup

```bash
calendar-helper.sh setup
```

- **macOS**: No install needed. May need: System Settings > Privacy & Security > Calendars. All accounts from System Settings > Internet Accounts appear automatically.
- **Linux**: Requires `khal` + `vdirsyncer` with CalDAV config. See `caldav-calendar-skill.md` for vdirsyncer configuration.
