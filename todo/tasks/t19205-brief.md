## Origin

- Created: 2026-11-20, interactive aidevops throughput session.
- Evidence: the `review-bot-gate.yml` outage (merged 05:29Z by #39427, fixed 15:14Z by #39460) blocked every aidevops merge for ~9.5 h. It was first reported by an interactive session at 14:50Z (#39458); no automated issue was filed.

## What

Give the systemic CI failure miner (`sh.aidevops.routine-gh-failure-miner` / `aidevops-gh-failure-miner`) the same pulse-dependency escape hatch that stats-wrapper (t2418, GH#20016) and complexity-scan (GH#24841) already have. Non-interactive setup (`aidevops update`) currently reinstalls the miner only if it is still installed, so an install that lost it once never gets it back.

## Why

- On the maintainer runner the miner last ran 2026-04-08 (`~/.aidevops/logs/routine-gh-failure-miner.log` mtime); its plist is absent while the supervisor pulse, stats-wrapper and every other pulse-owned scheduler are installed.
- Until then it filed `Systemic CI failure: <workflow> (N events)` auto-dispatch issues hourly (threshold 2).
- Today both default-branch push runs of `review-bot-gate.yml` (05:29Z, 05:43Z) failed and stayed the newest runs, which meets the miner's selection rule (`select_current_workflow_failures_json`) and threshold.
- Pulse's per-PR zero-job remediation (`pulse-merge-rest-state.sh` `_pmrs_rerun_zero_job_run`) only logged `rerun request failed ... no further automatic reruns` on five PRs.

## Tier

tier:standard — one helper function plus one call-site change, following an existing in-file pattern.

## How (Approach)

### Files Scope

- `.agents/scripts/setup/_runtime_helpers.sh`
- `setup.sh`
- `.agents/scripts/gh-failure-miner-helper.sh`
- `TODO.md`
- `todo/tasks/t19205-brief.md`

### Implementation Steps

1. In `.agents/scripts/setup/_runtime_helpers.sh`, add `_should_setup_noninteractive_failure_miner`, modelled on `_should_setup_noninteractive_stats_wrapper` / `_should_setup_noninteractive_complexity_scan`: return 0 when the miner is installed on any backend, else when `_should_setup_noninteractive_supervisor_pulse` returns 0.
2. In `setup.sh` non-interactive scheduler block, replace the generic `_should_setup_noninteractive_scheduler "Failure miner" ...` call with the new helper.
3. `setup_failure_miner` (`.agents/scripts/setup/modules/schedulers.sh`) already installs only when `PULSE_ENABLED` is `true` and uninstalls otherwise, so no change is needed there.
4. Discovered during verification: a dry run over the outage window found no cluster. `emit_workflow_run_events` read one unfiltered page of 100 runs, but aidevops had 2,500 runs in 11 h, so the page covered ~25 minutes. Add `fetch_repo_level_runs_json`, which queries only the events `select_current_workflow_failures_json` keeps (`push` with `branch=<default>`, `schedule`, `workflow_dispatch`, `issues`, `pull_request_target`), server-side, merged and de-duplicated by run ID.

### Verification

- `shellcheck setup.sh .agents/scripts/setup/_runtime_helpers.sh .agents/scripts/gh-failure-miner-helper.sh`
- `bash .agents/scripts/tests/test-gh-failure-miner-signature-noise.sh` (GH#39228 selection assertions unchanged)
- `gh-failure-miner-helper.sh collect --repos marcusquinn/aidevops --since-hours 11` lists the failed default-branch `review-bot-gate.yml` push runs.
- `setup.sh --non-interactive` on a pulse host without the miner plist installs `sh.aidevops.routine-gh-failure-miner` (`launchctl list | rg gh-failure-miner`).

## Acceptance Criteria

- [ ] Non-interactive setup installs the miner on a pulse-enabled host where it is absent.
- [ ] Hosts with pulse disabled still do not get the miner.
- [ ] Failed default-branch push runs older than the newest 100 repository runs are mined.
- [ ] ShellCheck clean.
