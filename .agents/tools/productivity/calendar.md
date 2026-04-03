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
- **macOS**: `osascript` via Calendar.app — no install. Grant access: System Settings > Privacy & Security > Calendars.
- **Linux**: `khal` + `vdirsyncer` (CalDAV) — run `calendar-helper.sh setup`. See `caldav-calendar-skill.md`.
- **Related**: `tools/productivity/apple-reminders.md` (tasks/reminders), `tools/productivity/notes.md`

<!-- AI-CONTEXT-END -->

## When to Create Events

Create: user explicitly asks, routine produces a time-bound commitment, coordinating availability.

Skip: tasks/reminders with no time block (→ `reminders-helper.sh`), TODO.md/GitHub issues, unconfirmed tentative plans.

## Field Coverage

Both platforms: title, start/end, location, notes, URL, calendar, all-day. Linux-only: `--repeat`, `--alarms`, `--categories`. No CLI support for invitees, travel time, or availability.

## Usage

```bash
# View / search
calendar-helper.sh show today
calendar-helper.sh show week --calendar Work
calendar-helper.sh show 2026-04-10..2026-04-15
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
