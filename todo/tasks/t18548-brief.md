<!-- aidevops:brief-schema=v2 -->

# t18548: Pulse: clamp stage timeouts to the cycle deadline so full cycles finish before lock force-reclaim kills them

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found during post-release monitoring of aidevops 3.37.30. `pulse-health.json` showed cycle `20260929T052653Z-87280` ending `interrupted` for the 5th consecutive cycle, and `pulse-wrapper.log` showed the next launcher force-reclaiming its lock after 3905 s. Issue: GH#33007.

## What

Make every main pulse cycle finish, and publish terminal cycle state, before the 1800 s instance-lock force-reclaim kills it. Every stage timeout should be bounded by one cycle deadline. The long internal budgets (merge pass, TODO sync) should pause gracefully at that deadline, and a cycle that dispatched work before it was interrupted should still record progress.

## Why

- `~/.aidevops/logs/pulse-wrapper.log` has 47 `FORCE-RECLAIMED stale lock from PID N (age Ns > ceiling 1800s ...) — killing hung owner (GH#20025)` lines, with ages from 1801 s to 4050 s. The last 5 main cycles all ended this way.
- `pulse-health.json` reports `consecutive_no_progress_cycles: 5` and `progress.last_at: 03:12:57Z`, although the killed cycle had `issues_dispatched: 2`. Stall detection and the supervisor therefore see a false no-progress signal.
- The killed cycle spent its time in stages that ignore cycle start:
  - `sync_todo_refs_repo_5` (429 s timeout);
  - `preflight_ownership_reconcile` (600 s timeout);
  - `deterministic_merge_pass` (555 s);
  - dispatch candidates (600 s each).
- **Root cause:**
  - Only two preflight helpers compute the remaining cycle time (`.agents/scripts/pulse-dispatch-preflight-lib.sh:361-376,430-460`).
  - `run_stage_with_timeout` never clamps to it (`.agents/scripts/pulse-watchdog.sh:204-288`).
  - The lock ceiling `PULSE_LOCK_MAX_AGE_S` (`.agents/scripts/pulse-wrapper-config.sh:174`) is enforced on process age (`.agents/scripts/pulse-instance-lock.sh:129-137`), independently of the cycle ceiling `PULSE_STALE_THRESHOLD` (`.agents/scripts/pulse-wrapper-config.sh:38`).
  - Interrupted cycles are finalised with `"[]"` progress kinds (`.agents/scripts/pulse-logging.sh:409`).

## Tier

**Selected tier:** `tier:thinking`

`tier:thinking`: it modifies dispatch-path files (`pulse-wrapper.sh`, `pulse-dispatch-*`), which the t2819 detector normalises to `tier:thinking` (`reference/auto-dispatch.md` "Dispatch-Path Default"). It also needs cross-stage design judgment: one deadline shared across synchronous stages, an async housekeeping opt-out, graceful pause versus kill, and fail-open behaviour when inputs are missing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-watchdog.sh:204-288` — add `_pulse_cycle_remaining_seconds [reserve]`:
  - deadline = `PULSE_START_EPOCH + min(PULSE_STALE_THRESHOLD, PULSE_LOCK_MAX_AGE_S)`;
  - reserve defaults to about 90 s via `AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S`;
  - it returns 1 (fail open) when inputs are missing or invalid.
  Add a small clamp helper that `run_stage_with_timeout` calls. It lowers the timeout, and below about 15 s remaining it logs `Stage deferred: <name> cycle budget exhausted` and returns 124 without running the command. Skip the clamp when `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0`.
- `EDIT: .agents/scripts/pulse-dispatch-preflight-lib.sh:361-376,430-460` — make `_preflight_refill_reserved_timeout` and `_preflight_post_label_refill_wall_clock_allows` use the helper for remaining time, with identical admission results and log text.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:1129-1132` — set `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0` inside the async post-dispatch housekeeping subshell only.
- `EDIT: .agents/scripts/pulse-merge-pass.sh:156-179` — make `_pmp_merge_pass_budget_deadline` return the earlier of its current deadline and `now + _pulse_cycle_remaining_seconds`, guarded by `declare -F`.
- `EDIT: .agents/scripts/pulse-wrapper-cycle.sh:912-914` — cap `aggregate_deadline` in `sync_todo_refs_all_repos` the same way.
- `EDIT: .agents/scripts/pulse-dispatch-lib-candidates.sh:589-600` — before `run_stage_with_timeout "dispatch_candidate_..."`, when the remaining time is below the candidate floor, log `Dispatch_max: cycle budget exhausted` and return the existing benign-skip code without any API call. Do not lower the floor for candidates that start.
- `EDIT: .agents/scripts/pulse-wrapper.sh:1669-1670` — also export the cycle dispatch baseline as the global `_PULSE_CYCLE_DISPATCH_BEFORE`.
- `EDIT: .agents/scripts/pulse-logging.sh:400-412` — in `_pulse_cycle_state_finish_if_needed`, pass `["worker-dispatched"]` instead of `"[]"` when `_pulse_capture_dispatch_total` (`.agents/scripts/pulse-wrapper-cycle-gates.sh:512`) exceeds `_PULSE_CYCLE_DISPATCH_BEFORE`.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh:323-349` — add clamp, deferral, opt-out and fail-open cases, reusing the `PULSE_START_EPOCH`/`date` stub pattern.
- `EDIT: .agents/scripts/tests/test-pulse-merge-pr-cursor-resume.sh:179-193` and `EDIT: .agents/scripts/tests/test-pulse-todo-sync-parallel.sh:114-165` — add cycle-deadline cap cases.

### Complete Write Surface

- **Callers/readers:** `run_stage_with_timeout` is called by every pulse stage (`.agents/scripts/pulse-wrapper.sh`, `.agents/scripts/pulse-dispatch-engine.sh`, `.agents/scripts/pulse-dispatch-lib-candidates.sh:599`, `.agents/scripts/pulse-wrapper-cycle.sh`) and is stubbed by many tests; `_pmp_merge_pass_budget_deadline` is read at `.agents/scripts/pulse-merge-pass.sh:868`; `pulse-health.json` `cycle_state` is read by stall detection and dashboards.
- **Writers/mutation paths:** `_pulse_cycle_state_finalize` and `write_pulse_health_file` (`.agents/scripts/pulse-logging.sh:246-293,366-398`) write cycle state; the merge pass writes its PR cursor on pause (`.agents/scripts/pulse-merge-pass.sh:255-277`); no other persisted state changes.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`, `.agents/scripts/tests/test-pulse-merge-pr-cursor-resume.sh`, `.agents/scripts/tests/test-pulse-todo-sync-parallel.sh`, `.agents/scripts/tests/test-pulse-lock-force-reclaim.sh`, `.agents/scripts/tests/test-pulse-is-running-stale-lock-breaker.sh`, `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`, plus the production signals `pulse-wrapper.log` `FORCE-RECLAIMED` count and `pulse-health.json` `cycle_state.outcome`.
- **Schemas/config:** two new optional env overrides, `AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S` and `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP`, documented next to the helper in `.agents/scripts/pulse-watchdog.sh`. The `cycle_state` schema is unchanged (`progress.kinds` already allows `worker-dispatched`).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`, and the pulse loads it through the runtime bundle after release.
- **Migrations/backfills:** N/A because no persisted format changes; existing `pulse-health.json` and merge cursors stay readable.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/pulse-watchdog.sh` and the other listed scripts, or set `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0` in the pulse launch environment to disable the clamp without a release.

### Implementation Steps

1. Add the deadline helper and clamp helper to `.agents/scripts/pulse-watchdog.sh`, and wire the clamp into `run_stage_with_timeout` behind the opt-out.
2. Refactor the two preflight copies onto the helper with identical behaviour, then set the opt-out in the async housekeeping subshell.
3. Cap the merge-pass and TODO-sync internal deadlines, and add the dispatch candidate early stop.
4. Publish `_PULSE_CYCLE_DISPATCH_BEFORE` and use it in `_pulse_cycle_state_finish_if_needed`.
5. Extend the three test files, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** stages run in background subshells that inherit `PULSE_START_EPOCH`, so every stage computes the same deadline; the async housekeeping subshell outlives a normal main exit and must opt out, or it would be clamped to a deadline that no longer applies; no new shared files or locks.
- **Migration/rollback:** no persisted-format change. Roll back by revert or with the `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0` kill switch.
- **Mixed-version/backward compatibility:** the helper fails open when `PULSE_START_EPOCH`, `PULSE_STALE_THRESHOLD` or `PULSE_LOCK_MAX_AGE_S` is unset or invalid, so `--refill-only`, `--merge-only`, standalone helper invocations and unit tests that source single libraries keep today's timeouts; merge-pass and TODO-sync callers must guard with `declare -F` because their libraries can be sourced without `.agents/scripts/pulse-watchdog.sh`.
- **Idempotency/retry:** deferred stages and paused merge cursors resume next cycle, as today; deferral returns 124, the existing timeout code, so callers' `|| true` and timeout handling are unchanged.
- **Partial failure/recovery:** if the helper errors, stages run with their original timeout (fail open), never with zero; progress is derived from counters that already exist and only adds `worker-dispatched` when the counter actually increased.

### Complexity Impact

- **Target function:** `run_stage_with_timeout` in `.agents/scripts/pulse-watchdog.sh`
- **Current line count:** about 85 lines (L204-288; threshold: 100 lines for function-complexity)
- **Estimated growth:** +3 lines (one call to the extracted clamp helper plus its early return)
- **Projected post-change:** about 88 lines (88% of threshold). The new helpers stay under 40 lines each. `_run_preflight_stages` (about 97 lines) and `main` in `.agents/scripts/pulse-wrapper.sh` (already over) must not grow beyond the single baseline export line.
- **Action required:** keep all new logic in the extracted helpers. Do not add branches to `main`, `_pulse_run_deterministic_pipeline` or `_run_preflight_stages`.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-watchdog.sh .agents/scripts/pulse-dispatch-preflight-lib.sh .agents/scripts/pulse-dispatch-engine.sh .agents/scripts/pulse-merge-pass.sh .agents/scripts/pulse-wrapper-cycle.sh .agents/scripts/pulse-dispatch-lib-candidates.sh .agents/scripts/pulse-logging.sh .agents/scripts/pulse-wrapper.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash .agents/scripts/tests/test-pulse-merge-pr-cursor-resume.sh
bash .agents/scripts/tests/test-pulse-todo-sync-parallel.sh
bash .agents/scripts/tests/test-pulse-lock-force-reclaim.sh
bash .agents/scripts/tests/test-pulse-is-running-stale-lock-breaker.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

- **Surface mapping:** `shellcheck` covers all eight modified scripts. The three test files are each mapped to specific surfaces and hazards:
  - `test-pulse-dispatch-engine-stage-wiring.sh` proves:
    - the helper, clamp, deferral and opt-out in `.agents/scripts/pulse-watchdog.sh` and `.agents/scripts/pulse-dispatch-engine.sh`, including fail-open (the mixed-version and partial-failure hazards) and the async opt-out (the concurrency hazard);
    - the unchanged refill admission in `.agents/scripts/pulse-dispatch-preflight-lib.sh`;
    - the dispatch early stop in `.agents/scripts/pulse-dispatch-lib-candidates.sh`;
    - interrupted-cycle progress in `.agents/scripts/pulse-logging.sh` and `.agents/scripts/pulse-wrapper.sh`.
  - `test-pulse-merge-pr-cursor-resume.sh` proves the capped merge deadline and cursor persistence in `.agents/scripts/pulse-merge-pass.sh` (the idempotency hazard).
  - `test-pulse-todo-sync-parallel.sh` proves the capped aggregate deadline in `.agents/scripts/pulse-wrapper-cycle.sh`.
  - The force-reclaim, stale-lock-breaker and characterization tests prove that lock behaviour and pulse-wide sourcing are unchanged (the rollback hazard).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**
- Do not raise or rename `PULSE_LOCK_MAX_AGE_S` or `PULSE_STALE_THRESHOLD`.
- Do not change the force-reclaim or is-running logic in `.agents/scripts/pulse-instance-lock.sh`.
- Do not lower `DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR` for candidates that start.
- Do not change the `cycle_state` schema.
- Do not clamp async post-dispatch housekeeping.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-watchdog.sh`
- `.agents/scripts/pulse-dispatch-preflight-lib.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-merge-pass.sh`
- `.agents/scripts/pulse-wrapper-cycle.sh`
- `.agents/scripts/pulse-dispatch-lib-candidates.sh`
- `.agents/scripts/pulse-logging.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`
- `.agents/scripts/tests/test-pulse-merge-pr-cursor-resume.sh`
- `.agents/scripts/tests/test-pulse-todo-sync-parallel.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] With `PULSE_START_EPOCH` set so that 300 s remain, a 600 s stage runs with a timeout no greater than 300 s minus the reserve, and the clamp is logged. With less than the minimum remaining, the stage command does not run, the deferral is logged, and rc is 124.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh"
  ```

- [ ] The merge-pass deadline and TODO-sync aggregate deadline never exceed the cycle deadline, and the merge pass still persists its PR cursor when paused.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-pr-cursor-resume.sh && bash .agents/scripts/tests/test-pulse-todo-sync-parallel.sh"
  ```

- [ ] An interrupted cycle whose dispatch counter increased records `worker-dispatched` progress.

  ```yaml
  verify:
    method: codebase
    pattern: "_PULSE_CYCLE_DISPATCH_BEFORE"
    path: ".agents/scripts/pulse-logging.sh"
  ```

- [ ] Negative/regression:
  - with `PULSE_START_EPOCH` unset, or inside async housekeeping, stage timeouts are unchanged;
  - refill admission and reserved-timeout results are unchanged;
  - force-reclaim and stale-lock-breaker behaviour is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-lock-force-reclaim.sh && bash .agents/scripts/tests/test-pulse-is-running-stale-lock-breaker.sh && bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

- [ ] After release, `rg -c "FORCE-RECLAIMED" ~/.aidevops/logs/pulse-wrapper.log` stops growing for main cycles, and `pulse-health.json` `cycle_state.outcome` is not `interrupted` on consecutive cycles. This is observed after deploy, not in this PR.

## Context & Decisions

- Clamping to the cycle deadline was chosen over raising `PULSE_LOCK_MAX_AGE_S`. A higher ceiling would delay recovery from genuinely hung cycles, and cycles already overrun it by up to 2250 s.
- The effective deadline uses `min(PULSE_STALE_THRESHOLD, PULSE_LOCK_MAX_AGE_S)` because the kill is enforced by the lock ceiling, whatever the cycle ceiling says.
- A lock heartbeat (lock-mtime age instead of process age) was considered and deferred. It touches several comparison sites, and it only matters once cycles stay under the deadline by design.

## Relevant Files

- `.agents/scripts/pulse-watchdog.sh:204-288` — `run_stage_with_timeout`
- `.agents/scripts/pulse-dispatch-preflight-lib.sh:361-376,430-460` — existing remaining-time copies
- `.agents/scripts/pulse-dispatch-engine.sh:1088-1137` — async post-dispatch housekeeping
- `.agents/scripts/pulse-merge-pass.sh:156-179,255-277` — merge-pass budget and cursor pause
- `.agents/scripts/pulse-wrapper-cycle.sh:835-938` — bounded TODO sync
- `.agents/scripts/pulse-dispatch-lib-candidates.sh:589-600` — candidate timeout floor
- `.agents/scripts/pulse-logging.sh:246-293,400-417` — cycle-state finalise
- `.agents/scripts/pulse-instance-lock.sh:124-140` — force-reclaim (read-only)
- `.agents/scripts/pulse-wrapper-config.sh:38,172,174` — ceilings (read-only)
