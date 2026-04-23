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

---

## Investigation Findings (#20577)

**Date:** 2026-04-23  
**Result:** Hypothesis **partially rejected** — only one direct scheduler found.

### Enumerated Invocation Sources

| Source | Cadence | Direct invocation of pulse-wrapper.sh? |
|--------|---------|----------------------------------------|
| `com.aidevops.aidevops-supervisor-pulse` (launchd) | **180s** | YES — sole direct source |
| `com.aidevops.aidevops-auto-update` → `setup.sh` → `restart-if-running` | 600s plist, but setup.sh only on updates | Indirect restart (~32× in 42 days, ~0.5% of auto-update runs) |
| Cron | n/a | NO — no pulse entries in `crontab -l` |
| Plugins (`opencode-aidevops`) | n/a | NO — plugin references are doc strings only |
| Shell login hooks (`.zshrc`, `.bashrc`, `.bash_profile`) | n/a | NO — no pulse references |
| `worker-watchdog` (launchd, 120s) | 120s | NO — monitors workers, does not invoke wrapper |
| `process-guard-helper.sh` (launchd, 30s) | 30s | NO — kills runaway children inside existing sessions |

**Conclusion: exactly one direct scheduler exists.**

**Note:** `pulse-wrapper.sh` header line 64 says "launchd fires every 120s" — this is a stale
comment. The deployed plist uses `StartInterval=180`.

### The 4-PID / 15-Minute Pattern Explained

Log evidence:
```
[pulse-wrapper] Instance lock acquired via mkdir (PID 93516)
[pulse-wrapper] Instance lock acquired via mkdir (PID 10463)
[pulse-wrapper] Another pulse instance holds the mkdir lock (PID 10463, age 203s…) — exiting
[pulse-wrapper] Instance lock acquired via mkdir (PID 82162)
[pulse-wrapper] Instance lock acquired via mkdir (PID 93078)
```

4 distinct PIDs in 15 minutes is expected at a 180s launchd interval (15×60/180 = 5 possible
firings). The **voluntary pre-LLM lock release** (`pulse-wrapper.sh:1329`) releases the instance
lock before launching the LLM session, allowing the next launchd invocation to run deterministic
ops concurrently. This produces multiple sequential lock acquisitions while an earlier invocation's
LLM session is still running. This is documented design behaviour, not anomalous churn.

### Measured Cadence (42-day log window: 2026-03-11 to 2026-04-23)

| Metric | Value |
|--------|-------|
| Total wrapper invocations (acquired + rejected) | 4,021 |
| Successful lock acquisitions | 3,544 |
| Lock rejections ("Another pulse instance holds…") | 477 (11.9%) |
| LLM supervisor sessions started | 2,181 |
| Actual invocation rate | 4.0/hr (avg 910s interval) |
| Expected at 180s if always-on (42 days) | 20,323 |
| Machine uptime fraction | ~20% (sleeping ~80% of the time) |

The invocation rate is consistent with normal launchd operation on a laptop that
sleeps frequently. The 11.9% lock rejection rate is within design parameters.

### Additional Finding: Persistent trigger=stall

All recent LLM sessions show `trigger=stall`, meaning the backlog stall detector
(`_should_run_llm_supervisor` in `pulse-dispatch-engine.sh:686`) fires on every cycle
because open issue+PR counts are not decreasing. April 2026 median LLM interval: **76 minutes**.
This is a throughput/capacity signal — separate from the scheduler question — but means the LLM
supervisor is running as often as the stall threshold allows, amplifying the observed invocation count.

---

## Architecture Notes

### Current invocation flow (pulse-wrapper.sh main())

```text
launchd fires (every 180s — note: code comment on line 64 says 120s, stale)
  -> main()
    -> _pulse_handle_self_check()     # Phase 0: validate all symbols loaded
    -> _pulse_setup_dry_run_mode()
    -> _pulse_setup_canary_mode()
    -> trap 'release_instance_lock' EXIT
    -> acquire_instance_lock()         # mkdir atomicity (POSIX-guaranteed)
    -> check_session_gate()            # pulse-hours window
    -> check_dedup()                   # PID file sentinel
    -> [pulse cycle runs]
    -> release_instance_lock()         # voluntary pre-LLM release (line 1329)
    -> [LLM session runs with lockdir.llm lock]
```

### Proposed flow (after #20578 + #20579)

```text
launchd fires (every 180s)
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
- Investigation confirms **Child A (Consolidate schedulers)** from the parent's
  original plan is **not needed** — only one scheduler exists. The three remaining
  fix children (#20578, #20579, #20580) address the voluntary-release churn pattern,
  not a multi-scheduler problem.

## Resolution (2026-04-23)

Consolidated issue: [#20592](https://github.com/marcusquinn/aidevops/issues/20592)

All four child issues have been resolved and their PRs merged:

| Issue | PR | Merged | Summary |
|-------|----|--------|---------|
| [#20577](https://github.com/marcusquinn/aidevops/issues/20577) | [#20589](https://github.com/marcusquinn/aidevops/pull/20589) | 2026-04-23 | Investigation report (this file) |
| [#20578](https://github.com/marcusquinn/aidevops/issues/20578) | [#20588](https://github.com/marcusquinn/aidevops/pull/20588) | 2026-04-23 | Entry-point rate-limit cooldown (`PULSE_MIN_INTERVAL_S`, default 90s) |
| [#20579](https://github.com/marcusquinn/aidevops/issues/20579) | [#20584](https://github.com/marcusquinn/aidevops/pull/20584) | 2026-04-23 | Is-running short-circuit via `pgrep` before mkdir lock |
| [#20580](https://github.com/marcusquinn/aidevops/issues/20580) | [#20586](https://github.com/marcusquinn/aidevops/pull/20586) | 2026-04-23 | Invocation-source logging and `pulse-stats.json` counters |

### Verdict

**Original hypothesis (multiple schedulers causing churn): rejected.**
Only one direct scheduler exists (`com.aidevops.aidevops-supervisor-pulse`, launchd, 180s).

**Root cause:** The 4-PID / 15-minute pattern is normal behaviour from the voluntary pre-LLM lock release at `pulse-wrapper.sh:1329`. Successive launchd firings acquire the lock after the previous invocation voluntarily releases it. The 11.9% lock rejection rate (477/4021 over 42 days) is within design parameters.

**Fixes shipped:** Three defence-in-depth measures now reduce unnecessary lock contention:

1. **Rate-limit** (#20578) — skips cycle if last run was <90s ago (single `stat` call)
2. **Is-running check** (#20579) — skips if another pulse PID is alive (`pgrep`, before mkdir)
3. **Source logging** (#20580) — per-source invocation counters for future monitoring

**Scheduler consolidation (Child A) not needed** — confirmed only one scheduler.

**Stale comment fix:** `pulse-wrapper.sh` header comment corrected from "120s" to "180s" to match the deployed plist `StartInterval=180`.
