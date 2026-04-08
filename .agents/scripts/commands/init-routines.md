---
description: Scaffold a private routines repo with TODO.md, routines/ dir, and issue template
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
├── TODO.md              # Routine definitions with repeat: fields
├── routines/            # YAML specs for complex routines
│   └── .gitkeep
├── .gitignore
└── .github/
    └── ISSUE_TEMPLATE/
        └── routine.md   # Template for routine tracking issues
```

Registered in `~/.config/aidevops/repos.json` with `pulse: true, priority: "tooling"`.

## After setup

Add routines to `~/Git/aidevops-routines/TODO.md` under `## Routines`. See `.agents/reference/routines.md` for field specification and examples.

## Related

- `/routine` — design and schedule a recurring routine
- `.agents/reference/routines.md` — routine field reference
- `~/.config/aidevops/repos.json` — repo registration
