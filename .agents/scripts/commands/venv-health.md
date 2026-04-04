---
description: Run lightweight Python venv health checks across managed projects
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run Python venv smoke tests across managed repos. Arguments: $ARGUMENTS

```bash
~/.aidevops/agents/scripts/venv-health-check-helper.sh scan $ARGUMENTS
```

## Modes

| Invocation | Result |
|------------|--------|
| `/venv-health` | Scan all repos in `~/.config/aidevops/repos.json` |
| `/venv-health --quiet` | Show only warnings and errors |
| `/venv-health --json` | Return JSON like `{"summary":{"total":3,"healthy":2,"warnings":0,"broken":1},"venvs":[...]}` |
| `/venv-health --path DIR` | Scan one directory instead of the managed repo list |

## Checks Performed

| Check | What it catches | Severity |
|-------|----------------|----------|
| `pip check` | Broken dependency requirements, missing packages, version conflicts | Error |
| Stale editable installs | `.pth` files pointing to deleted paths (e.g., pruned git worktrees) | Error |
| Missing requirements file | Venvs with no `requirements.txt`, `pyproject.toml`, `setup.py`, `setup.cfg`, or `Pipfile` | Warning |

Discovery: looks for `.venv/pyvenv.cfg` (PEP 405 marker) up to 3 levels deep in each registered repo, deduplicated by realpath.

## Automatic Checks

Runs daily via `auto-update-helper.sh` when idle. Results: `~/.aidevops/logs/auto-update.log`.

| Config key | Default | Effect |
|------------|---------|--------|
| `updates.venv_health_check` | `true` | Set `false` to disable |
| `updates.venv_health_hours` | `24` | Check interval in hours |

```bash
aidevops config set updates.venv_health_check false
aidevops config set updates.venv_health_hours 12
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All venvs healthy (or no venvs found) |
| 1 | One or more venvs have issues |
| 2 | Usage error |

## Related

- `scripts/secret-hygiene-helper.sh` — Python `.pth` file IoC audit (supply chain)
- `scripts/tool-version-check.sh` — Global tool version checks (npm, brew, pip)
- `scripts/auto-update-helper.sh` — Periodic freshness checks (skills, tools, venvs)
