---
description: Mission progress dashboard — show mission status, milestone progress, feature completion, budget burn rate, active workers, and blockers
agent: Build+
mode: subagent
---

Display the mission progress dashboard with real-time status.

Arguments: $ARGUMENTS

## Quick Output (Default)

Run the helper script for instant output:

```bash
~/.aidevops/agents/scripts/mission-dashboard-helper.sh status $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Commands

| Command | Description |
|---------|-------------|
| `/dashboard` | Full CLI dashboard with progress bars |
| `/dashboard --verbose` | Include active worker details and blockers |
| `/dashboard summary` | Compact one-line-per-mission overview |
| `/dashboard json` | Machine-readable JSON output |
| `/dashboard browser` | Generate HTML dashboard and open in browser |
| `/dashboard --mission ID` | Filter to a specific mission |

## Arguments

| Argument | Description |
|----------|-------------|
| (none) | Show full CLI dashboard for all missions |
| `summary` | Compact summary view |
| `json` | JSON output for programmatic use |
| `browser` | Generate and open HTML dashboard |
| `--mission ID`, `-m ID` | Filter by mission ID or title substring |
| `--verbose`, `-v` | Show worker details and blockers |

## Data Sources

The dashboard aggregates data from:

1. **Mission state files** — `todo/missions/*/mission.md` and `~/.aidevops/missions/*/mission.md`
2. **Budget tracker** — `~/.aidevops/.agent-workspace/cost-log.tsv` (burn rate, daily spend)
3. **Observability metrics** — `~/.aidevops/.agent-workspace/observability/metrics.jsonl` (token/cost tracking)
4. **Process table** — `ps` for active worker count
5. **GitHub** — `gh issue list --label status:blocked` for blockers (verbose mode)

## Browser View

The `browser` command generates a self-contained HTML file with:

- Dark theme matching GitHub's design language
- Progress bars for overall and per-milestone completion
- Status badges with color coding
- Budget burn rate cards
- Active worker count

The HTML file is written to `~/.aidevops/.agent-workspace/tmp/mission-dashboard.html` and opened in the default browser. It can also be served via Playwright for automated screenshots or monitoring.

## Integration with Pulse

The pulse supervisor can invoke the dashboard to generate status reports:

```bash
# Generate JSON for programmatic consumption
~/.aidevops/agents/scripts/mission-dashboard-helper.sh json

# Generate HTML snapshot for archival
~/.aidevops/agents/scripts/mission-dashboard-helper.sh browser --mission m-20260227
```

## Examples

```text
User: /dashboard
AI: [Runs mission-dashboard-helper.sh status and displays formatted output]

User: /dashboard --verbose
AI: [Shows full dashboard with worker PIDs, elapsed times, and blocked issues]

User: /dashboard json | jq '.missions[0].progress_pct'
AI: 45

User: /dashboard browser
AI: Dashboard generated and opened in browser.
```

## Related

- `scripts/commands/mission.md` — Create missions
- `scripts/commands/pulse.md` — Supervisor dispatch (mission-aware)
- `workflows/mission-orchestrator.md` — Mission execution engine
- `scripts/observability-helper.sh` — Token/cost tracking
- `scripts/budget-tracker-helper.sh` — Cost log and burn rate
