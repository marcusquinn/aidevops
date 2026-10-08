<!-- aidevops:brief-schema=v2 -->

# fix(pulse): detached script routine lock is never released, stalling every script routine

## Pre-flight

- [x] Memory recall: `cloudron app packaging upstream version update routine` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 commit after #32668 touches `pulse-routines.sh` (af5e6017ec, unrelated backup work); 0 open PRs; no matching issues for "detached runner already active" or "routine lock"
- [x] File refs verified: `.agents/scripts/pulse-routines.sh:273-342` present at HEAD
- [x] Tier: `tier:standard` — known bug with resolved fix; stale-lock reclaim policy is a small bounded choice
- [x] Seeded draft PR decision recorded: skipped — two-line root-cause fix plus reclaim; issue-only is sufficient

## Origin

- **Created:** 2026-10-08
- **Created by:** ai-interactive
- **Conversation context:** The user asked whether routines keep our Cloudron app packages current. r916 (Cloudron upstream check) has not run since 2026-09-28. The cause is a lock that affects every script routine.

## What

Script routines dispatched through `_routine_dispatch_script` must release their per-routine runner lock when the detached runner exits. They must also recover from a lock left by a runner that died. After the fix, each due script routine runs, records a terminal state (`success`, `failure` or `deferred`), and runs again at its next due time.

## Why

`_routine_run_detached_script` (`.agents/scripts/pulse-routines.sh:273-307`) acquires `lock_dir` with `mkdir`, then sets:

```bash
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
```

`lock_dir` is a function-local variable, and the single-quoted trap expands it only when the shell exits. By then the function has returned and the local is gone. The trap runs `rmdir ""`, which fails silently, so the lock directory stays. Every later dispatch then logs `routine <id>: detached runner already active` and returns without running anything.

Evidence (this host, 2026-10-08):

- 32 empty lock directories `~/.aidevops/.agent-workspace/routine-state.json.<id>.runner` exist (r040-r046, r902-r920, r-pulse-check, r-session-miner, r-gh-audit-scan, r-keywords-*, r-issue-archive, r-attribution-scan). Most were created 2026-09-28 ~02:13 UTC, a few hours after #32668 merged (2026-09-27T22:20Z). No runner process is alive.
- `routine-state.json` shows `last_status: running` for all of them. For example, r916 has `last_run 2026-09-27T03:33:50Z` and `last_attempt 2026-10-07T22:19:52Z`.
- `pulse.log` repeats `routine r916 is due ... dispatching ... detached runner already active` on every cycle, about 4 times a day for 10 days.
- r917 completed a run on 2026-10-04 with `script exited with code 1` and finalized its state, but its lock directory from that run still exists. So a normal exit leaks the lock too, not only a crash.
- Minimal repro: a bash script whose function sets `local lock_dir=...; mkdir "$lock_dir"; trap 'rmdir "$lock_dir" ...' EXIT` leaves the directory after the script exits.

Impact: no script routine runs at all. That includes r916/r917, so Cloudron packages behind upstream have not had update issues filed since 2026-09-27: NetBird v0.80.0, AI DevOps Worker v3.38.33 and Buzz v0.5.27 are pending.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The root cause and primary fix are exact. Stale-lock reclaim needs a small, bounded design choice (owner PID record plus liveness check) inside the existing lock boundary.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-routines.sh:273-342` — fix trap expansion, record the owner PID, reclaim dead-owner locks
- `EDIT: .agents/scripts/tests/test-routine-tracking-updates.sh` — existing test added by #32668 for this path; add one regression case for lock release and stale reclaim

### Complete Write Surface

- **Callers/readers:** `_routine_dispatch_script` (`pulse-routines.sh:309-342`) spawns `_routine_run_detached_script` via `setsid`/`perl`/`nohup bash -c`; `_routine_execute` (`pulse-routines.sh:348+`) calls the dispatcher. Nothing else reads `*.runner` (search: `rg -n '\.runner' .agents/scripts`).
- **Writers/mutation paths:** only `_routine_run_detached_script` creates/removes `${ROUTINE_STATE_FILE}.${routine_id}.runner`. `_routine_update_state` and `_routine_record_lifecycle` write state and lifecycle.
- **Existing verification/tests:** `.agents/scripts/tests/test-routine-tracking-updates.sh` (from #32668).
- **Schemas/config:** none; the lock directory is internal runtime state.
- **Generated/deployed mirrors:** deployed copy at `~/.aidevops/agents/scripts/pulse-routines.sh`, updated by `setup.sh`/release.
- **Migrations/backfills:** existing leaked lock directories hold no owner PID. Reclaim must treat a lock with no PID file, or a dead PID, as stale. That clears the 32 existing locks on the first post-deploy cycle without a manual step.
- **Cleanup/rollback paths:** reverting the commit restores the old behaviour. The lock remains a plain directory.

### Implementation Steps

1. Expand the lock path when the trap is set, not when it fires. For example:

   ```bash
   # shellcheck disable=SC2064 # expand lock_dir now; the local is gone at EXIT
   trap "rmdir $(printf '%q' "$lock_dir") 2>/dev/null || true" EXIT
   ```

   Better still, release the lock explicitly after `_routine_finalize_terminal`, before `return 0`, and keep the trap only as a fallback for crashes. If a PID file is written inside the lock (step 2), use `rm -rf -- "$lock_dir"` scoped to that exact path instead of `rmdir`.
2. Record ownership: after `mkdir "$lock_dir"` succeeds, write `$$` to `"$lock_dir/pid"`. When `mkdir` fails, read `pid`. If it is missing or `kill -0` fails, and the lock is older than a short grace period (for example 60s, which covers the gap between `mkdir` and writing the PID), remove that exact lock path, log `routine <id>: reclaimed stale runner lock`, and retry `mkdir` once.
3. When the lock is held by a live owner, keep the current skip. Make sure the pre-dispatch `running` state written by `_routine_dispatch_script` is not left as the final record for a dispatch that never ran. Either check the lock in the dispatcher before writing `running`, or leave the existing state untouched on the skip path.
4. Run `shellcheck .agents/scripts/pulse-routines.sh`, then the existing test.

### Hazards and Compatibility

- **Concurrency/atomicity:** `mkdir` stays the atomic acquire. Reclaim removes only a lock whose recorded owner is dead (or which has no PID past the grace period) and retries `mkdir` once. A concurrent pulse that wins the retry keeps the lock.
- **Migration/rollback:** existing PID-less locks are reclaimed after the grace period. Rollback leaks locks again, as it does today.
- **Mixed-version/backward compatibility:** an old-version runner holding a PID-less lock and still alive (unlikely, given the 10-day age) would be reclaimed after the grace period. The grace period must be well below the routine cadence and above the `mkdir`→PID write gap.
- **Idempotency/retry:** a routine that genuinely runs long (r916 ~5 min) keeps its live-PID lock, so no double run happens.
- **Partial failure/recovery:** SIGKILL or a reboot leaves a lock with a dead PID, which is reclaimed on the next due cycle.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-routines.sh
bash .agents/scripts/tests/test-routine-tracking-updates.sh
# Production path after deploy: next pulse cycle should log completion, not "already active"
rg -n 'routine r916: (script completed|script exited|reclaimed stale)' ~/.aidevops/logs/pulse.log
```

- **Surface mapping:** shellcheck covers the trap quoting; the test covers lock release and stale reclaim; the pulse log proves the production path.
- **Broad verification trigger:** not required; single module.

### Files Scope

- `.agents/scripts/pulse-routines.sh`
- `.agents/scripts/tests/test-routine-tracking-updates.sh`

## Acceptance Criteria

- [ ] After a detached script routine exits (success or failure), `${ROUTINE_STATE_FILE}.<id>.runner` no longer exists.
- [ ] A runner lock with no PID file or a dead PID, older than the grace period, is reclaimed and the routine runs on its next due cycle; a lock with a live owner PID is never removed.
- [ ] `routine-state.json` records a terminal status for each completed run; skipped dispatches do not leave a permanent `running` state.
- [ ] `shellcheck .agents/scripts/pulse-routines.sh` is clean.

  ```yaml
  verify:
    method: codebase
    pattern: "trap 'rmdir \"\\$lock_dir\""
    path: ".agents/scripts/pulse-routines.sh"
    expect: absent
  ```

## Context & Decisions

- Regression introduced by #32668 (GH#32637, "detach due script routines").
- Agent routines (`_routine_dispatch_agent`) do not use this lock and are unaffected.
- Non-goal: changing routine schedules or failure backoff.
