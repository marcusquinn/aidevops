---
description: Scaffold a private routines repo with TODO.md, routine descriptions, and tracking issues
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Scaffold a private git repo for routine definitions. Always private — routine definitions may contain client names, schedules, and sensitive operational details.

Arguments: $ARGUMENTS

## Usage

```bash
aidevops init-routines                  # Personal: <username>/aidevops-routines
aidevops init-routines --org <name>     # Org: <org>/aidevops-routines (private)
aidevops init-routines --local          # Local-only, local_only: true in repos.json
aidevops init-routines --dry-run        # Preview without changes

# Or via the helper directly:
~/.aidevops/agents/scripts/init-routines-helper.sh [--org <name>] [--local] [--dry-run]
```

## What it creates

```
~/Git/aidevops-routines/
├── TODO.md              # Routine definitions (core r901+ seeded, user r001-r899)
├── routines/
│   ├── core/            # Framework-managed routine descriptions
│   │   ├── r901.md      # Supervisor pulse
│   │   ├── r902.md      # Auto-update
│   │   └── ...          # 12 core routines total
│   └── custom/          # User routine descriptions (survives updates)
│       └── README.md
├── .gitignore
└── .github/
    └── ISSUE_TEMPLATE/
        └── routine.md   # Template for routine tracking issues
```

For repos with a GitHub remote, a tracking issue is created for each core routine via `routine-log-helper.sh` (idempotent — skipped if already exists).

Registered in `~/.config/aidevops/repos.json` with `pulse: true, priority: "tooling"`.

## Core routines seeded

| ID | Routine | Schedule |
|----|---------|----------|
| r901 | Supervisor pulse | Every 2 min |
| r902 | Auto-update | Every 10 min |
| r903 | Process guard | Every 30 sec |
| r904 | Worker watchdog | Every 2 min |
| r905 | Memory pressure monitor | Every 60 sec |
| r906 | Repo sync | Daily @19:00 |
| r907 | Contribution watch | Hourly |
| r908 | Profile README update | Hourly |
| r909 | Screen time snapshot | Every 6 hours |
| r910 | Skills sync | Every 5 min |
| r911 | OAuth token refresh | Every 30 min |
| r912 | Dashboard server | Persistent |

Each routine has a description file in `routines/core/<id>.md` covering what it does, what to check, and how to verify it's working.

## Custom routine descriptions

Create `routines/custom/<id>.md` for your own routines. Custom descriptions override core descriptions when both exist for the same ID. Use `~/.aidevops/agents/templates/routine-description-template.md` as a starting point.

## After setup

Add your own routines to `~/Git/aidevops-routines/TODO.md` under `## User Routines`. Use IDs r001-r899 (core routines use r901+). See `.agents/reference/routines.md` for field specification.

## Related

- `/routine` — design and schedule a recurring routine
- `.agents/reference/routines.md` — routine field reference
- `.agents/templates/routine-description-template.md` — description template
- `~/.config/aidevops/repos.json` — repo registration
