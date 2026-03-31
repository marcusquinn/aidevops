---
description: Run lightweight Python venv health checks across managed projects
agent: Build+
mode: subagent
---

Run Python venv smoke tests across managed repos.

Arguments: $ARGUMENTS

## Quick Output

```bash
~/.aidevops/agents/scripts/venv-health-check-helper.sh scan $ARGUMENTS
```

Display the helper output directly; formatting is built in.

## Arguments

| Argument | Description |
|----------|-------------|
| (none) | Scan all repos in `~/.config/aidevops/repos.json` |
| `--quiet`, `-q` | Only report broken/warning venvs |
| `--json`, `-j` | JSON output for programmatic use |
| `--path DIR`, `-p DIR` | Scan a specific directory instead of repos.json |

## Common Invocations

| Command | Purpose |
|---------|---------|
| `/venv-health` | Scan all managed repos |
| `/venv-health --quiet` | Show only warnings and errors |
| `/venv-health --json` | Return machine-readable output |
| `/venv-health --path DIR` | Scan one directory |

## Checks Performed

| Check | What it catches | Severity |
|-------|----------------|----------|
| `pip check` | Broken dependency requirements, missing packages, version conflicts | Error |
| Stale editable installs | `.pth` files pointing to deleted paths (e.g., pruned git worktrees) | Error |
| Missing requirements file | Venvs with no `requirements.txt`, `pyproject.toml`, `setup.py`, `setup.cfg`, or `Pipfile` | Warning |

## Venv Discovery

Looks for `.venv/pyvenv.cfg` (PEP 405 marker) up to 3 levels deep in each registered repo. Deduplicates by realpath.

## Automatic Checks

Runs daily via `auto-update-helper.sh` when the user is idle. Results go to `~/.aidevops/logs/auto-update.log`.

Disable automatic checks:

```bash
aidevops config set updates.venv_health_check false
```

Change the interval (default: 24h):

```bash
aidevops config set updates.venv_health_hours 12
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All venvs healthy (or no venvs found) |
| 1 | One or more venvs have issues |
| 2 | Usage error |

## Output Expectations

- Default: show all detected venvs
- `--quiet`: show only warnings and errors
- `--json`: return JSON like `{"summary":{"total":3,"healthy":2,"warnings":0,"broken":1},"venvs":[...]}`
- `--path`: scan the supplied directory instead of the managed repo list

## Related

- `scripts/secret-hygiene-helper.sh` — Python `.pth` file IoC audit (supply chain)
- `scripts/tool-version-check.sh` — Global tool version checks (npm, brew, pip)
- `scripts/auto-update-helper.sh` — Periodic freshness checks (skills, tools, venvs)
