# t2402: fleet-health-based auto-override for DISPATCH_CLAIM_IGNORE_RUNNERS via supervisor dashboards

## Session origin

- Date: 2026-04-19
- Context: Long-term systemic replacement for t2400 (tactical manual override, shipped in PR #19965). Retires the manual config for the common case.
- Sibling tasks: t2400 (login-gated tactical override, shipped), t2401 (version-gated filter, planned).

## What — parent decomposition

Extend the pulse supervisor dashboards (#10944 marcusquinn, #14335 alex-solovyev, #2632 code-audit) with per-runner 24h and 7d worker success-rate fields, then add a new `fleet-health-helper.sh` that polls those dashboards, computes the fleet average, and auto-populates `DISPATCH_CLAIM_IGNORE_RUNNERS` when a peer runner is substantially below average. Retires the manual config for the common case while preserving the override for edge cases.

**Parent status — decomposes into:**

- (a) **Dashboard stat fields** — extend the supervisor-dashboard update script to emit machine-parseable `success_rate_24h` and `success_rate_7d` fields.
- (b) **`fleet-health-helper.sh` implementation** — `snapshot` / `poll` / `suggest-ignore` / `auto-update` subcommands.
- (c) **Pulse cycle wire-in** — `pulse-wrapper.sh` invokes `auto-update` at cycle start.
- (d) **Documentation** — new section in `reference/cross-runner-coordination.md`.
- (e) **Dashboard refresh fix** — #10944 has been stale since 2026-04-08; refresh trigger needs investigation as part of (a).

## Why

t2400 ships a tactical login-based override. It requires operator awareness and manual sunset. Two ongoing costs:

1. **Detection latency.** By the time alex-solovyev's degradation was spotted 2026-04-19, marcusquinn's runner had sat at `dispatched=0` for most of a day.
2. **Sunset toil.** Stale entries linger in the manual list when peers recover — no one remembers to remove them.

Supervisor dashboards exist as the natural substrate for per-runner stats. Wiring success-rate metrics back into the override filter closes the loop.

## How

### 1. Dashboard extension — success-rate fields

Extend the supervisor dashboard update script (location TBD — likely `pulse-supervisor-dashboard.sh` or similar in `pulse-*.sh` cluster) to include:

- `success_rate_24h`: `merged_prs / (merged_prs + closed_unmerged_prs + killed_workers)` over last 24h.
- `success_rate_7d`: same metric, 7d window.
- `fleet_avg_success_rate_24h` / `..._7d`: computed by reading all registered dashboards.
- `last_pulse_ts`: already present (currently shows stale data — needs refresh-trigger investigation).

Data sources:
- Merged PRs: `gh search prs --author "<login>" --merged` over the window.
- Closed-unmerged PRs with `origin:worker` label.
- Watchdog kills: `~/.aidevops/logs/pulse.log` grep `[worker-activity-watchdog]` over window.

### 2. `fleet-health-helper.sh`

New script `.agents/scripts/fleet-health-helper.sh` modeled on the structure of `dispatch-claim-helper.sh` (shebang, set -euo, source shared-constants, subcommand dispatcher, per-function `local var="$1"` pattern, explicit returns).

Subcommands:
- `snapshot` — compute current success-rate for the local runner, write to `~/.aidevops/logs/fleet-health-self.json` with timestamp.
- `poll` — read all supervisor dashboard issues (dashboards known to the runner; probably a new entry in `repos.json` or a standalone config mapping `login -> issue_number`), extract last-published success-rate for each peer, compute fleet average.
- `suggest-ignore` — compare each peer's rate to fleet average; emit a suggested `DISPATCH_CLAIM_IGNORE_RUNNERS` list containing peers >N% below average (threshold configurable via `FLEET_IGNORE_THRESHOLD_PCT`, default 50).
- `auto-update` — if `FLEET_AUTO_OVERRIDE_ENABLED=true`, apply the suggested list into `~/.config/aidevops/dispatch-override.conf` with an audit timestamp header.

### 3. Pulse cycle wire-in

- `pulse-wrapper.sh` calls `fleet-health-helper.sh auto-update` at cycle start.
- Emit log line when ignore list changes: `[fleet-health] Added LOGIN to ignore list (rate 12% vs fleet avg 78%, threshold 50%)` — or the symmetrical `Removed LOGIN` line when a peer recovers.
- Audit: every change writes to `~/.aidevops/logs/fleet-health-audit.log` (timestamped, human-readable).

### 4. Safety floors

- **Minimum sample size**: peer must have ≥5 worker runs in window; otherwise treat as "insufficient data" (no filter applied).
- **Fleet size**: if only one runner is registered, disable auto-override entirely (no fleet average to compare against).
- **Emergency opt-out**: `FLEET_AUTO_OVERRIDE_ENABLED=false` in `~/.config/aidevops/dispatch-override.conf` forces back to manual mode.
- **Manual-list preservation**: logins already present in `DISPATCH_CLAIM_IGNORE_RUNNERS` are NEVER auto-removed. Auto-update APPENDS to, not replaces, the existing list.
- **Rate-limit hysteresis**: don't flap — require a peer to cross the threshold in the same direction for two consecutive polls before changing the list.

## Acceptance criteria

- [ ] Supervisor dashboards refresh reliably (fix the 11-day-stale #10944 case).
- [ ] Dashboard body includes `success_rate_24h` / `success_rate_7d` fields, parseable by helpers.
- [ ] `fleet-health-helper.sh snapshot/poll/suggest-ignore/auto-update` all work standalone.
- [ ] Auto-update with `FLEET_AUTO_OVERRIDE_ENABLED=true` populates `DISPATCH_CLAIM_IGNORE_RUNNERS` and emits audit log.
- [ ] Manual entries preserved when auto-update runs.
- [ ] Minimum sample size floor: peers with <5 runs NOT added to ignore list.
- [ ] Hysteresis: two consecutive polls required for threshold crossings.
- [ ] Test harness: simulated dashboard JSON → correct suggested list.
- [ ] `reference/cross-runner-coordination.md` documents the loop.
- [ ] Shellcheck + complexity gate clean.

## Files to modify / create

- NEW: `.agents/scripts/fleet-health-helper.sh`
- NEW: `.agents/scripts/tests/test-fleet-health-helper.sh`
- EDIT: supervisor dashboard update script (TBD location — likely in `pulse-*.sh` cluster).
- EDIT: `.agents/scripts/pulse-wrapper.sh` — invoke `auto-update` at cycle start.
- EDIT: `.agents/configs/dispatch-override.conf.txt` — document `FLEET_AUTO_OVERRIDE_ENABLED`, `FLEET_IGNORE_THRESHOLD_PCT`.
- EDIT: `.agents/reference/cross-runner-coordination.md` — document the fleet-health loop.

## Reference patterns

- Dashboard write: find existing supervisor dashboard logic (`grep -rn "supervisor.*dashboard\|pinned.*issue" ~/.aidevops/agents/scripts/`).
- Override config loader: mirror `dispatch-claim-helper.sh:57-80` pattern.
- jq-based filter: reuse from `_apply_ignore_filter` (dispatch-claim-helper.sh).
- Subcommand dispatcher: mirror `dispatch-claim-helper.sh` structure.

## Blocked by

- Prefer to land AFTER t2401 (version-gated filter) — together they form the full dispatch governance layer. Not a hard blocker.

## Context

- #10944 — marcusquinn supervisor dashboard (stale since 2026-04-08; refresh needs fixing as part of step (a)).
- #14335 — alex-solovyev supervisor dashboard.
- #2632 — code-audit supervisor dashboard (or similar role).
- #19967 (t2400): the manual override this retires.
- #19968 (t2401): version-field extension that this combines with.
