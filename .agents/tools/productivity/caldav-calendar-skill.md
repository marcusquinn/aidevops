---
name: caldav-calendar
description: "Sync and query CalDAV calendars (iCloud, Google, Fastmail, Nextcloud, etc.) using vdirsyncer + khal"
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# CalDAV Calendar (vdirsyncer + khal)

**For reminders/tasks** (not events): see `tools/productivity/apple-reminders.md`.

**Sync first** — always sync before querying or after changes: `vdirsyncer sync`

## Initial Setup

1. Configure vdirsyncer (`~/.config/vdirsyncer/config`) — supports iCloud, Google, Fastmail, Nextcloud
2. Configure khal (`~/.config/khal/config`)
3. Run: `vdirsyncer discover && vdirsyncer sync`

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

`khal edit` — interactive (requires TTY): `s` summary, `d` description, `t` datetime, `l` location, `D` delete, `n` skip, `q` quit

## Output Formats

Placeholders: `{title}`, `{description}`, `{start}`, `{end}`, `{start-date}`, `{start-time}`, `{end-date}`, `{end-time}`, `{location}`, `{calendar}`, `{uid}`

## Caching

Remove stale cache: `rm ~/.local/share/khal/khal.db`
