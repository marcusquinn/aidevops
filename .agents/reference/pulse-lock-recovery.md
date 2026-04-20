<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Pulse Lock Recovery (GH#20025)

## Overview

The pulse uses an `mkdir`-based lock (`LOCKDIR`) to ensure only one instance
runs at a time. When a pulse instance crashes, hangs, or is OOM-killed, the
lock directory persists and blocks subsequent invocations.

Prior to GH#20025, the only recovery path was "owner PID dead → clear lock".
A hung pulse (alive PID, running for 40+ minutes) would block every subsequent
invocation indefinitely, causing a cascade where 10+ pulse cycles are skipped.

## Force-Reclaim Behaviour

`_handle_existing_lock()` in `pulse-instance-lock.sh` now performs three
checks when the lock directory already exists:

### 1. PID liveness (`ps -p`)

If the lock owner PID is dead, clear and re-acquire (existing behaviour).

### 2. PID reuse detection (`ps -o command=`)

If the PID is alive but `ps -o command=` does NOT contain `pulse-wrapper`,
the original owner died and the PID was reused by an unrelated process.
The lock is reclaimed immediately **without killing** the unrelated process.

### 3. Age-based ceiling (`PULSE_LOCK_MAX_AGE_S`)

If the PID is alive, IS a pulse-wrapper, but has been running longer than
`PULSE_LOCK_MAX_AGE_S` (default 1800s = 30 min), the owner is considered
hung. The hung process is killed via `_kill_tree` and the lock is reclaimed.

A healthy pulse cycle completes in <5 minutes. 30+ minutes means the process
is stuck (typically in a GH API call or a heavy stage).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `AIDEVOPS_PULSE_LOCK_MAX_AGE_S` | `1800` | Age ceiling in seconds before force-reclaim |

Set via environment variable to adjust without code changes:

```bash
export AIDEVOPS_PULSE_LOCK_MAX_AGE_S=900  # more aggressive: 15 min
```

## Audit Trail

Every force-reclaim is logged to `$WRAPPER_LOGFILE` (`~/.aidevops/logs/pulse-wrapper.log`):

```
[pulse-wrapper] FORCE-RECLAIMED stale lock from PID 55064 (age 2432s > ceiling 1800s, owner_cmd='pulse-wrapper') — killing hung owner (GH#20025)
[pulse-wrapper] FORCE-RECLAIMED stale lock from PID 12345 (age 100s, owner_cmd='sleep') — PID reused by non-pulse process (GH#20025)
```

## Stage Timing Log

`run_stage_with_timeout()` in `pulse-watchdog.sh` emits structured TSV
records to `~/.aidevops/logs/pulse-stage-timings.log`:

```
# Format: ISO-timestamp \t stage_name \t duration_seconds \t exit_code \t pid
2026-04-20T01:45:00Z	deterministic_merge_pass	12	0	55064
2026-04-20T01:45:12Z	preflight_cleanup_and_ledger	45	0	55064
2026-04-20T01:45:57Z	preflight_daily_scans	600	124	55064
```

Exit code `124` = stage timed out. Use this log to identify which stages
consume the most time and whether timeouts are firing.

The log is rotated alongside the main pulse log when it exceeds 1MB.

## Regression Tests

`.agents/scripts/tests/test-pulse-lock-force-reclaim.sh` covers:

1. Live pulse owner within ceiling → blocked (no reclaim)
2. Dead PID owner → reclaimed
3. Alive-but-stale owner (age > ceiling) → force-reclaimed, `_kill_tree` called
4. PID reused by unrelated process → reclaimed, `_kill_tree` NOT called
5. `AIDEVOPS_PULSE_LOCK_MAX_AGE_S` env override adjusts ceiling

## Related

- `reference/bash-fd-locking.md` — why mkdir, not flock
- `pulse-instance-lock.sh` — lock module
- `pulse-watchdog.sh` — `run_stage_with_timeout()` with timing output
- `pulse-dispatch-engine.sh` — preflight stages wrapped with per-group timeouts
