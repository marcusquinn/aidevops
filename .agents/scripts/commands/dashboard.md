---
description: Mission progress dashboard — status, milestones, budget burn rate, workers, blockers
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Display the mission progress dashboard with real-time status.

Arguments: $ARGUMENTS

## Quick Output (Default)

```bash
~/.aidevops/agents/scripts/mission-dashboard-helper.sh status $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Arguments

| Argument | Description |
|----------|-------------|
| (none) | Full CLI dashboard for all missions |
| `summary` | Compact one-line-per-mission overview |
| `json` | Machine-readable JSON output |
| `browser` | Generate HTML dashboard and open in browser |
| `--mission ID`, `-m ID` | Filter by mission ID or title substring |
| `--verbose`, `-v` | Include worker details and blockers |
| `--pending-review` | Show issues awaiting maintainer decision |

## Data Sources

1. **Mission state** — `todo/missions/*/mission.md` and `~/.aidevops/missions/*/mission.md`
2. **Budget** — `~/.aidevops/.agent-workspace/cost-log.tsv` (burn rate, daily spend)
3. **Observability** — `~/.aidevops/.agent-workspace/observability/metrics.jsonl` (token/cost)
4. **Workers** — `ps` for active worker count
5. **GitHub blockers** — `gh issue list --label status:blocked` (verbose mode)
6. **GitHub review** — `gh issue list --label needs-maintainer-review` (pending review)

## Pending Review View

`--pending-review` shows all `needs-maintainer-review` issues across pulse-enabled repos (simplification-debt, feature requests, etc.).

```bash
for slug in $(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .slug' ~/.config/aidevops/repos.json); do
  gh issue list --repo "$slug" --label "needs-maintainer-review" --state open \
    --json number,title,labels,assignees,createdAt \
    --jq '.[] | "\(.number)\t\(.title)\t\(.labels | map(.name) | join(","))\t\(.assignees | map(.login) | join(","))\t\(.createdAt)"'
done
```

Output: tab-separated (number, title, labels, assignees, ISO timestamp). The agent groups by repo, converts timestamps to relative times, and aligns columns at display time.

Actions for each item:
- **Approve:** `gh issue edit <N> --repo <slug> --remove-label needs-maintainer-review --add-label auto-dispatch`
- **Decline:** `gh issue close <N> --repo <slug> -c "Declined: <reason>"`

## Browser View

Generates a self-contained HTML file (dark theme, progress bars, status badges, budget cards) at `~/.aidevops/.agent-workspace/tmp/mission-dashboard.html` and opens in the default browser.

## Pulse Integration

```bash
~/.aidevops/agents/scripts/mission-dashboard-helper.sh json                          # Programmatic
~/.aidevops/agents/scripts/mission-dashboard-helper.sh browser --mission m-20260227  # HTML snapshot
```

## Related

- `scripts/commands/mission.md` — Create missions
- `scripts/commands/pulse.md` — Supervisor dispatch (mission-aware)
- `workflows/mission-orchestrator.md` — Mission execution engine
- `scripts/observability-helper.sh` — Token/cost tracking
- `scripts/budget-tracker-helper.sh` — Cost log and burn rate
