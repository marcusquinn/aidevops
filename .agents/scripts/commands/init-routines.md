---
description: Scaffold a private routines repo with TODO.md, routines/ dir, and issue template
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Scaffold a private git repo for routine definitions. Supports personal repos, per-org repos, and local-only (no remote).

Arguments: $ARGUMENTS

## Usage

```bash
aidevops init-routines                  # Personal: <username>/aidevops-routines
aidevops init-routines --org <name>     # Org: <org>/aidevops-routines
aidevops init-routines --local          # Local-only (no remote)
aidevops init-routines --dry-run        # Preview without changes
```

Or via the helper directly:

```bash
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

The repo is registered in `~/.config/aidevops/repos.json` with `pulse: true, priority: "tooling"`.

## Privacy

Always private — no flag to make public. Routine definitions may contain client names, internal schedules, and sensitive operational details.

## Flags

| Flag | Description |
|------|-------------|
| `--org <name>` | Create `<org>/aidevops-routines` (private) |
| `--local` | Local-only repo, `local_only: true` in repos.json |
| `--dry-run` | Preview without making changes |

## After setup

Add routines to `~/Git/aidevops-routines/TODO.md` under `## Routines`:

```markdown
## Routines

- [x] r001 Weekly SEO rankings export repeat:weekly(mon@09:00) ~30m run:custom/scripts/seo-export.sh
- [ ] r002 Monthly content calendar review repeat:monthly(1@09:00) ~15m agent:Content
```

See `.agents/reference/routines.md` for the full field specification.

## Related

- `/routine` — design and schedule a recurring routine
- `.agents/reference/routines.md` — routine field reference
- `~/.config/aidevops/repos.json` — repo registration
