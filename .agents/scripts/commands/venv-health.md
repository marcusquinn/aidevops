---
description: Run lightweight Python venv health checks across managed projects
agent: Build+
mode: subagent
---

Run Python venv smoke tests across all repos registered in repos.json.

Arguments: $ARGUMENTS

## Quick Output (Default)

```bash
~/.aidevops/agents/scripts/venv-health-check-helper.sh scan $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Commands

| Command | Description |
|---------|-------------|
| `/venv-health` | Scan all managed repos, show all results |
| `/venv-health --quiet` | Only show broken or warning venvs |
| `/venv-health --json` | Machine-readable JSON output |
| `/venv-health --path DIR` | Scan a specific directory |

## Arguments

| Argument | Description |
|----------|-------------|
| (none) | Scan all repos in repos.json |
| `--quiet`, `-q` | Only report broken/warning venvs |
| `--json`, `-j` | JSON output for programmatic use |
| `--path DIR`, `-p DIR` | Scan a specific directory instead of repos.json |

## Checks Performed

| Check | What it catches | Severity |
|-------|----------------|----------|
| `pip check` | Broken dependency requirements, missing packages, version conflicts | Error |
| Stale editable installs | `.pth` files pointing to deleted paths (e.g., pruned git worktrees) | Error |
| Missing requirements file | Venvs with no `requirements.txt`, `pyproject.toml`, `setup.py`, `setup.cfg`, or `Pipfile` | Warning |

## Venv Discovery

Looks for `.venv/pyvenv.cfg` (PEP 405 marker) up to 3 levels deep in each repo
registered in `~/.config/aidevops/repos.json`. Deduplicates by realpath.

## Automatic Checks

The venv health check runs automatically once per day via `auto-update-helper.sh`
when the user is idle. Results are logged to `~/.aidevops/logs/auto-update.log`.

To disable automatic checks:

```bash
aidevops config set updates.venv_health_check false
```

To change the check interval (default: 24h):

```bash
aidevops config set updates.venv_health_hours 12
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All venvs healthy (or no venvs found) |
| 1 | One or more venvs have issues |
| 2 | Usage error |

## Examples

```text
User: /venv-health
AI: [Runs venv-health-check-helper.sh scan and displays results]

User: /venv-health --quiet
AI: [Shows only broken/warning venvs]

User: /venv-health --json
AI: {"summary":{"total":3,"healthy":2,"warnings":0,"broken":1},"venvs":[...]}

User: /venv-health --path ~/Git/myproject
AI: [Scans ~/Git/myproject for venvs]
```

## Related

- `scripts/secret-hygiene-helper.sh` — Python `.pth` file IoC audit (supply chain)
- `scripts/tool-version-check.sh` — Global tool version checks (npm, brew, pip)
- `scripts/auto-update-helper.sh` — Periodic freshness checks (skills, tools, venvs)
