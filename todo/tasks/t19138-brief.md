<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `watchdog no_output_stall tool output heartbeat isolated db` → 0 relevant hits.
- [x] Discovery pass: no open issue/PR covers DB-visible tool activity in the worker watchdog (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:standard` — kill-policy change in the worker lifecycle.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** In 24h on one runner, 84 worker attempts ended in `watchdog_stall_*` (about 27 worker-hours). For 18 of them (about 8 h) the worker's bash tool was alive and printing a heartbeat every 2 s while it waited for a repository-level exclusive lock. OpenCode `run --format json` emits a tool event only when the tool part completes, so the output file the watchdog watches does not grow; tree CPU stays under 2% and there is no HTTPS socket, so none of the existing deferrals fire. The watchdog kills at 600 s, the session resumes, the lock queue position is lost and the wait starts again.

## What

Give `worker-activity-watchdog.sh` one more liveness signal: recent row updates in the worker's isolated OpenCode DB. While a tool runs, OpenCode rewrites the running tool part (`state.metadata.output`) as output streams; measured live, `part.time_updated` stayed about 1 s old while the heartbeat printed. On a confirmed output stall, a part update within the activity window defers the kill as `tool_output_active`, the same way CPU, network and CI-wait deferrals work. The hard-kill cap is unchanged.

## Why

Workers that are working (long tests, lock waits, builds that print) are killed and resumed in a loop, wasting slots and resume tokens and losing lock-queue order. The signal is exact: it reflects tool output and part updates, not a guess from CPU or sockets.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/worker-activity-watchdog.sh` — new `--worker-db` arg, `_watchdog_db_part_activity`, deferral in `_monitor_handle_confirmed_stall`, classification in `_monitor_enforce_hard_kill`.
- EDIT: `.agents/scripts/headless-runtime-invoke.sh:425-430` — pass `--worker-db "${_WORKER_ISOLATED_DB_PATH}"` when set.
- EDIT: `.agents/scripts/tests/test-watchdog-no-false-kill.sh` — a functional case for the new deferral.

### Reference pattern

- `_monitor_defer_stall "network_active" ...` in `_monitor_handle_confirmed_stall` (same file).

### Files Scope

- `.agents/scripts/worker-activity-watchdog.sh`
- `.agents/scripts/headless-runtime-invoke.sh`
- `.agents/scripts/tests/test-watchdog-no-false-kill.sh`

## Acceptance Criteria

- [ ] A quiet worker whose isolated DB has a part updated within the window is deferred with `tool_output_active`, not killed.
- [ ] A quiet worker with no recent part update and no CPU/network evidence is still killed at the stall timeout.
- [ ] Missing, unreadable or locked DB fails open to existing behaviour (no deferral, no error).
- [ ] Existing watchdog tests pass; ShellCheck clean.
