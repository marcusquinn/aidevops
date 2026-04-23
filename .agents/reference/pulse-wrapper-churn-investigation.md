# Pulse-Wrapper Invocation Churn Investigation

Parent issue: [#20557](https://github.com/marcusquinn/aidevops/issues/20557)
Decomposition issue: [#20566](https://github.com/marcusquinn/aidevops/issues/20566)

## Problem Statement

Observed on 2026-04-23: 3541 instance-lock acquisitions and 4 distinct
`pulse-wrapper.sh` PIDs in a 15-minute window. The mkdir instance lock
prevents concurrent execution correctly, but the volume of contending
invocations indicates redundant scheduling.

Hypothesis: multiple schedulers (launchd + cron + plugin hooks + shell
login hooks) independently trigger `pulse-wrapper.sh`.

## Decomposition

| Child | Issue | Description | Tier |
|-------|-------|-------------|------|
| Investigation | [#20577](https://github.com/marcusquinn/aidevops/issues/20577) | Enumerate invocation sources and measure cadence | `tier:standard` |
| Rate-limit | [#20578](https://github.com/marcusquinn/aidevops/issues/20578) | Timestamp-based cooldown at wrapper entry | `tier:standard` |
| Is-running check | [#20579](https://github.com/marcusquinn/aidevops/issues/20579) | pgrep short-circuit before mkdir lock | `tier:standard` |
| Source logging | [#20580](https://github.com/marcusquinn/aidevops/issues/20580) | Per-source invocation counters in pulse-stats.json | `tier:standard` |

## Architecture Notes

### Current invocation flow (pulse-wrapper.sh main())

```text
launchd fires (every 120s)
  -> main()
    -> _pulse_handle_self_check()     # Phase 0: validate all symbols loaded
    -> _pulse_setup_dry_run_mode()
    -> _pulse_setup_canary_mode()
    -> trap 'release_instance_lock' EXIT
    -> acquire_instance_lock()         # mkdir atomicity (POSIX-guaranteed)
    -> check_session_gate()            # pulse-hours window
    -> check_dedup()                   # PID file sentinel
    -> [pulse cycle runs]
    -> release_instance_lock()
```

### Proposed flow (after #20578 + #20579)

```text
launchd fires (every 120s)
  -> main()
    -> _pulse_handle_self_check()
    -> _pulse_setup_dry_run_mode()
    -> _pulse_setup_canary_mode()
    -> [NEW] rate-limit check          # Exit 0 if last run < 90s ago
    -> [NEW] is-running check          # Exit 0 if pulse PID alive (pgrep)
    -> trap 'release_instance_lock' EXIT
    -> acquire_instance_lock()
    -> check_session_gate()
    -> check_dedup()
    -> [pulse cycle runs]
    -> release_instance_lock()
```

The two new checks are ordered intentionally:
1. **Rate-limit first** — cheapest check (single `stat` call on a timestamp file).
2. **Is-running second** — slightly more expensive (`pgrep` syscall) but catches
   the case where a previous cycle is still running past the rate-limit window.

Both checks exit before the mkdir lock, eliminating contention entirely for the
common cases (rapid re-invocation and overlapping cycles).

## Dependency Order

- #20577 (investigation) runs in parallel with #20578-#20580 (fixes).
- The fixes are independently implementable.
- #20577 may surface an additional child: "Consolidate schedulers" (Child A from
  the parent's original plan). This child is deferred until the investigation
  identifies which schedulers are redundant.
