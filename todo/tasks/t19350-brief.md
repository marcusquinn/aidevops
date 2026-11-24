## What

With `PULSE_DISPATCH_LOCK_SPLIT=1`, a Pulse cycle that starts with a retained worker-exit refill trigger only logs `action=drain_completed source=cycle-entry pass=0 dispatch=deferred trigger=retained` and leaves the trigger for its own first dispatch round. That round runs after the cycle's preflight (`stale_blocked_reconcile`, `prefetch_state`, …), often 5–15 minutes later. Free slots stay empty for that time: no dispatch-lock holder is running, and the waker that left the trigger has already exited (`lock_busy` or `runtime_transition` deferral).

Fix: in split-lock mode, the cycle-entry drain wakes the existing detached refill path (`pulse_event_refill_wake_underfilled`, GH#38696) instead of only deferring. The waker coalesces on the wake lock, rebases to the active bundle, and takes only the dispatch lock. It can therefore launch while the cycle holds the instance lock through preflight. Flag off: unchanged.

## Why (measured 2026-11-24 on one macOS runner, 20 slots, split-lock canary)

| Measure | Value | Source |
|---|---|---|
| Cycle-entry deferrals, 05:05–22:40Z (host IPC outage 14:45–16:25Z excluded) | 23 | `[pulse-event-refill] action=drain_completed source=cycle-entry … dispatch=deferred` in `pulse.log` |
| Minutes from deferral to the next ceremony start, summed | 93 min (max 14.8 min; 10 events ≥ 3.6 min) | `pulse-stage-timings.log` `dispatch_candidate_*` starts |
| Free slot-hours in those intervals | 19.9 | PR #40221 report modules (worker intervals) |
| Example, 19:28:52Z cycle (pid 38504) | 13.3 min until first ceremony; 9–14 free; stages in between: `stale_blocked_reconcile` 168 s, `prefetch_state` 402 s | stage timings |
| Free slot-time after recovery, 16:25–22:40Z | 25% no ceremony running, 48% fewer ceremonies than free slots, 27% covered | same modules |

A woken refill still needs its own census (~2–3 min) unless it adopts a handoff. The expected recovery is about 12 slot-hours per 16 h, roughly +0.75 mean occupancy against today's 9.45.

Why it was deferred: GH#32688. An in-process cycle-entry `apply_dispatch_max` consumed the whole cycle before preflight. A detached, dispatch-lock-only waker cannot do that, because it is a separate process and the cycle keeps its own budget. In split mode, cycle dispatch rounds already skip while a refill holds the dispatch lock: 61 `Dispatch stage … skipped` lines today, against 23 `event_refill_drain` and 11 cycle-round acquisitions. So this adds no new interaction.

## How

- `.agents/scripts/pulse-event-refill.sh`:
  - `pulse_event_refill_wake_underfilled`: accept an optional refill source (`$1`, default `active-pulse`; the same charset check as `pulse_event_refill_signal`), so the attribution says `cycle-entry`.
  - `pulse_event_refill_drain`, cycle-entry branch: when the trigger exists and `_pulse_event_refill_split_lock` succeeds, call `pulse_event_refill_wake_underfilled cycle-entry` and log `action=drain_completed source=cycle-entry pass=0 dispatch=woken trigger=retained`. Otherwise keep today's `dispatch=deferred` line.
  - Update the branch comment: shared-lock mode still defers (GH#32688). Split mode wakes a detached refill.
- No change to `apply_dispatch_max`, locks or budgets.

### Files Scope

- `.agents/scripts/pulse-event-refill.sh`

## Acceptance

- Split mode, trigger present at cycle entry: one detached `signal 0 <cycle pid> cycle-entry` wake starts. No in-process `apply_dispatch_max` runs.
- Flag off, or no trigger: behaviour and log lines unchanged.
- After deploy on the canary runner, `pulse.log` shows `dispatch=woken` at cycle entry, followed by `wake_started … source=cycle-entry` and `drain_started source=cycle-entry` before the cycle's `preflight_prefetch_and_scope` completes. `cycle_entry_cost`-style measurement: deferral-to-first-ceremony falls toward the census time (~2–3 min).
- `shellcheck` clean; `.agents/scripts/tests/test-pulse-event-refill.sh` passes.

## Verification

```bash
rg -n 'source=cycle-entry' ~/.aidevops/logs/pulse.log | tail -5
bash .agents/scripts/tests/test-pulse-event-refill.sh
```

For #40108 (Phase 1 follow-up; t19324 / PR #40121 added the split lock, GH#38696 added the underfill wake).
