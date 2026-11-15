<!-- aidevops:brief-schema=v2 -->

# t19026: fix(pulse): run the Pulse launchd jobs and their workers at normal priority, not launchd's throttled default

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent GH#38332)
- **Conversation context:** The user asked why simply starting interactive sessions and asking for a full-loop solves issues faster than Pulse and its workers. Scheduler priority is one measured cause.

## What

The macOS LaunchAgents that run the Pulse supervisor, the Pulse watchdog and the merge pass should set `ProcessType` to `Interactive`. Pulse and every worker it starts would then get the same scheduler and I/O treatment as an interactive terminal session (base priority 31), instead of launchd's throttled default (base priority 20).

## Why

`man launchd.plist`: "If left unspecified, the system will apply light resource limits to the job, throttling its CPU usage and I/O bandwidth." None of the three plists sets `ProcessType`. `launchctl print` reports `spawn type = daemon (3)` for both `com.aidevops.aidevops-supervisor-pulse` and `sh.aidevops.pulse-watchdog`.

Measured on the maintainer host on 2026-11-15, at load average 28–50 on 16 CPUs:

- `ps -o pri` gives 20 for every `pulse-wrapper.sh`, `headless-runtime-helper.sh` and `opencode run` worker process. Interactive OpenCode sessions and terminal shells run at 31.
- A/B test: two throwaway LaunchAgents ran the same fork-heavy benchmark (300 × `jq` + `git rev-parse`) at the same time. `ProcessType=Interactive` (pri 31) took 36.5 s. Unspecified (pri 20, today's Pulse setting) took 64.9 s, 1.78× slower. The probe agents were booted out afterwards.
- The same benchmark under `taskpolicy -c utility` (pri 20) was 2.0–2.3× slower than default QoS in two interactive runs (72.3 s vs 31.2 s, 60.5 s vs 31.1 s).
- `dispatch-stages.tsv` (Nov 14–15): `dedup.dedup_check` averages 96 s, `dedup.worker_launch_total` 221 s and `precreate.verify.reconcile_scan` 20–170 s per hour bucket. The same receipt scan takes 1.8 s from an interactive shell.

Every Pulse stage and every worker's model/tool loop pays this penalty all day. An interactive session started by the user does not. That accounts for part of the throughput gap the user sees.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Three plist generators and their structural tests. The change is mechanical, but it touches launchd installation paths, so the existing launchd setup suites must pass.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/setup/modules/schedulers-pulse.sh` — `_generate_pulse_plist_content` (supervisor pulse) and `_generate_pulse_watchdog_plist_content` (the watchdog revives Pulse, so revived Pulse inherits its spawn type): add `<key>ProcessType</key><string>Interactive</string>`, with a short comment citing the man page and this issue.
- `EDIT: .agents/scripts/setup/modules/schedulers-platform.sh` — `_install_pulse_merge_routine_launchd`: same key. The t3381 fix for the merge agent stuck in xpcproxy removed `Background`/`LowPriorityBackgroundIO`/`Nice`. Interactive applies no limits and keeps that fix intact.
- `EDIT: .agents/scripts/tests/test-pulse-merge-routine-standalone.sh` — test 10 still forbids `Background`, `LowPriorityBackgroundIO` and `Nice`, and now requires `ProcessType` `Interactive`.
- `EDIT: TODO.md` — task entry.

### Hazards and compatibility

- Linux cron/systemd paths are unchanged; they already run at normal priority.
- `Interactive` gives terminal-shell priority (31), not foreground-app priority (46–47), so the desktop UI stays responsive.
- Template-hash drift detection (`_schedulers_record_template_hash`) already regenerates installed plists after an update that changes `schedulers-pulse.sh`. `_launchd_install_if_changed` reloads the changed plists.

### Verification

```bash
shellcheck .agents/scripts/setup/modules/schedulers-pulse.sh .agents/scripts/setup/modules/schedulers-platform.sh
bash .agents/scripts/tests/test-pulse-merge-routine-standalone.sh
bash .agents/scripts/tests/test-pulse-launchd-setup.sh
bash .agents/scripts/tests/test-schedulers-pulse-interval.sh
bash .agents/scripts/tests/test-launchd-install-if-changed.sh
bash .agents/scripts/tests/test-pulse-defense-restart.sh
bash .agents/scripts/tests/test-plist-env-overrides.sh
# After deploy (setup.sh --non-interactive): launchctl print gui/$(id -u)/com.aidevops.aidevops-supervisor-pulse shows spawn type = interactive (4);
# ps -o pri for pulse-wrapper.sh and new opencode run workers shows 31.
```

### Files Scope

- `.agents/scripts/setup/modules/schedulers-pulse.sh`
- `.agents/scripts/setup/modules/schedulers-platform.sh`
- `.agents/scripts/tests/test-pulse-merge-routine-standalone.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] The generated supervisor pulse, pulse watchdog and merge-pass plists contain `ProcessType` = `Interactive`.
- [ ] None of them contains `Background`, `LowPriorityBackgroundIO` or `Nice`. The t3381 regression guard still holds.
- [ ] After deploy, Pulse and newly spawned worker processes report base priority 31, not 20.
- [ ] Existing launchd setup suites pass.
