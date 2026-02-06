---
description: "Sync and query CalDAV calendars (iCloud, Google, Fastmail, Nextcloud, etc.) using vdirsyncer + khal"
mode: subagent
imported_from: clawdhub
clawdhub_slug: "caldav-calendar"
clawdhub_version: "1.0.1"
---
# CalDAV Calendar (vdirsyncer + khal)

vdirsyncer syncs CalDAV calendars to local .ics files. khal reads and writes them.

**Sync First** — Always sync before querying or after making changes: `vdirsyncer sync`

## View Events

```bash
khal list                        # Today
khal list today 7d               # Next 7 days
khal list tomorrow               # Tomorrow
khal list 2026-01-15 2026-01-20  # Date range
khal list -a Work today          # Specific calendar
```

## Search

```bash
khal search "meeting"
khal search "dentist" --format "{start-date} {title}"
```

## Create Events

```bash
khal new 2026-01-15 10:00 11:00 "Meeting title"
khal new 2026-01-15 "All day event"
khal new tomorrow 14:00 15:30 "Call" -a Work
khal new 2026-01-15 10:00 11:00 "With notes" :: Description goes here
```

## Edit Events

Interactive (requires TTY):
- `s` — edit summary
- `d` — description
- `t` — datetime
- `l` — location
- `D` — delete
- `n` — skip
- `q` — quit

## Output Formats

Placeholders: `{title}`, `{description}`, `{start}`, `{end}`, `{start-date}`, `{start-time}`, `{end-date}`, `{end-time}`, `{location}`, `{calendar}`, `{uid}`

## Caching

Remove stale cache: `rm ~/.local/share/khal/khal.db`

## Initial Setup

1. Configure vdirsyncer (`~/.config/vdirsyncer/config`) — supports iCloud, Google, Fastmail, Nextcloud
2. Configure khal (`~/.config/khal/config`)
3. Run: `vdirsyncer discover && vdirsyncer sync`
