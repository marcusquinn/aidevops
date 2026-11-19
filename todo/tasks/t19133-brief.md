<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19133: fix(pulse-watchdog): starved deferrable stages borrow the capped dispatch-reserve fuse so dirty_pr_sweep stops starving

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `dirty_pr_sweep starvation deferrable stage fuse` → 0 hits
- [x] Discovery pass: GH#38747 added the starvation fuse; GH#38840 lends the dispatch reserve to critical stages only; no open PR touches `_pulse_stage_reserve_borrow_budget`
- [x] File refs verified: `.agents/scripts/pulse-watchdog.sh` `_pulse_stage_starvation_fuse`, `_pulse_stage_reserve_borrow_budget`, `_pulse_stage_cycle_timeout`; `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh` `assert_stage_reserve_borrow_contract`
- [x] Tier: `tier:standard` — extends one existing gate with an extra class and bound
- [x] Seeded draft PR decision recorded: skipped — implemented interactively

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19 (pulse/worker throughput mission)
- **Created by:** ai-interactive (unattended mission authorised by maintainer)
- **Conversation context:** two planning PRs with TODO.md-only conflicts stayed DIRTY for hours with no automated rebase. The dirty-PR sweep that should rebase them had not run in 6 days.

## What

A deferrable stage starved longer than `AIDEVOPS_PULSE_STAGE_DEFERRABLE_BORROW_STARVATION_S` (default 14400s; 0 disables) may borrow the same capped dispatch-reserve slice (GH#38840) that starved critical stages already use.

## Why

Retained `pulse.log` from 2026-11-13T02:59Z (6 days): `dirty_pr_sweep` has 0 `Stage start` lines, 91 `cycle budget exhausted` deferrals and 53 budget-priority deferrals. `dirty-pr-sweep-last-run` was last written 2026-09-29. In the same cycles the critical `redirect_spam_sweep`, which runs right after it, gets `Stage starvation fuse: ... reserve_borrow=120s`. The sweep is the only automated route that union-rebases TODO.md-only conflicts, closes stale abandoned PRs and notifies about real conflicts. Without it, conflicted planning PRs wait for a human session. Other deferrable stages also start rarely: `sync_todo_refs_all_repos` 3, `dependabot_alert_monitor` 5, `refresh_blocked_status_from_graph` 15.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-watchdog.sh` — `_pulse_stage_reserve_borrow_budget` admits `deferrable` and prints `<borrow> <bound>`; `_pulse_stage_starvation_fuse` takes the bound as an optional 5th argument; `_pulse_stage_cycle_timeout` passes both.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh` — `assert_stage_reserve_borrow_contract` covers the deferrable bound, its 0 override and a borrowed grant.

### Hazards

- The per-cycle borrow stays capped by `AIDEVOPS_PULSE_STAGE_RESERVE_BORROW_S` (120s), shared with critical stages. Maximum dispatch loss per cycle is unchanged, and the longer bound lets starved critical stages take the slice first.
- `progress` stages and a missing classifier still never borrow. Budget-priority (REST/GraphQL quota) deferral is unchanged and runs first.

## Acceptance Criteria

- [x] `bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh` passes (99/0); without the watchdog change the borrow contract fails.
- [x] ShellCheck clean on both files.
- [ ] After deploy, `rg 'Stage start: dirty_pr_sweep' ~/.aidevops/logs/pulse.log` shows a start within a few cycles and `dirty-pr-sweep-last-run` is refreshed.

## Relevant Files

- `.agents/scripts/pulse-watchdog.sh` — `_pulse_stage_starvation_fuse`, `_pulse_stage_reserve_borrow_budget`, `_pulse_stage_cycle_timeout`
- `.agents/scripts/pulse-budget-priority.sh` — `_pulse_stage_priority_class`
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh` — `assert_stage_reserve_borrow_contract`
