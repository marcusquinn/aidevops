<!-- aidevops:brief-schema=v2 -->

# t19015: perf(pulse): a drained cycle exits at the next stage boundary instead of running its full maintenance tail

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Parent:** GH#38332 (dispatch-starvation source flagged in its 2026-11-14 supervisor evidence comment)
- **Conversation context:** Measured on one 20-slot macOS runner while 3/20 slots were in use and the ready queue was non-empty.

## What

When a deploy asks the running Pulse cycle to drain (GH#37907, `LOCKDIR/drain_requested`), that cycle can no longer dispatch. It must stop running its remaining deferrable stages and exit at the next stage boundary. The activated bundle then starts on the next scheduler tick and adopts the handed-off census (GH#38048).

## Why

GH#37907 specified that a drained cycle "finishes the in-flight candidates, skips the floor refill and any new census, and exits the cycle so launchd starts the activated bundle". Only the dispatch half was implemented. `_dispatch_compute_capacity`, the serial and parallel dispatch loops, and the floor refill stop dispatching, but every other stage still ran. That covered the rest of `_run_preflight_stages`: cleanup/ledger, capacity, label maintenance (up to 488 s), trusted NMR reconcile, post-label refill, the housekeeping launch, and prefetch (about 426 s). It also covered the whole `_pulse_run_deterministic_pipeline`: orphan reaper, stale runs, Dependabot, merge pass, PR sweeps, TODO sync, graph rebuild, blocked refresh, canonical maintenance, and `dashboard_freshness_check` with its 600 s timeout.

Evidence, 2026-11-13T03:00Z to 2026-11-15T01:56Z (45.8 h). `pulse-cycle-index.jsonl` was correlated with the 41 bundle activations named in `pulse.log`:

| Measure | Value |
| --- | --- |
| Cycles running when a bundle activated (drained) | 40 of 64 (62%), 73% of cycle wall time |
| Time from activation to drained-cycle exit | p50 849 s, p90 1560 s |
| Total time alive with dispatch suppressed by a drain | 36,850 s (10.2 h, 22% of the window) |
| `pulse.log` drain skips | 62 `Dispatch_max skipped`, 54 `stopping early`, 84 floor refills stopped, against 108 `Dispatch_max: available=` |

Same-version drift redeploys and releases activate a bundle about every 66 minutes. The drain tail therefore costs about one sixth of every hour of dispatch time, and it also delays the new code it was meant to accelerate.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One helper adds stage-boundary checks to three orchestration functions. Dispatch, claim and lock semantics are unchanged.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib.sh` — adds `_pulse_cycle_drain_exit <phase>` next to `_pulse_drain_requested_bundle`. It returns 0 when the drain marker names this cycle's lock owner and logs `Cooperative drain: skipping remaining cycle stages` once per cycle, with the `pulse_drain_fast_exit` stat. It also releases `_PULSE_MAIN_DISPATCH_RESERVE_S`, and marks `_PULSE_PREFETCH_DEGRADED=1` when prefetch has not run, so a GH#38162 drain-escape supervisor treats the previous cycle's STATE_FILE as incomplete (GH#34000). `PULSE_DRAIN_FAST_EXIT=0` disables it.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh` (`_run_preflight_stages`) — checks once after mechanical blocker re-arm and once after early dispatch. The second check returns the promoted-prefetch rc, so a hard prefetch failure still aborts the cycle.
- `EDIT: .agents/scripts/pulse-wrapper.sh` (`_pulse_run_deterministic_pipeline`, `_pulse_drain_cycle_final_refill`) — checks before each phase. Drained paths still drain prefetch counters and accumulate merge health. The cycle-final refill leaves its trigger for the activated bundle.
- `EDIT: TODO.md` — task entry; records t19014 completion (PR #38407).

### Unchanged by design

- `_pulse_run_supervisor_phase` keeps its drain, census-handoff (GH#38048), starvation-escape (GH#38162) and deferral (GH#38210) logic.
- `_pulse_record_cycle_terminal` still records the cycle.
- In-flight stages finish; checks run only at boundaries.

### Verification

```bash
shellcheck -x -P .agents/scripts .agents/scripts/pulse-dispatch-engine.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/pulse-dispatch-lib.sh
bash .agents/scripts/tests/test-permission-block-breaker.sh
bash .agents/scripts/tests/test-pulse-supervisor-starvation-escape.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-dispatch-candidate-snapshot.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
# Runtime, 24 h after deploy: rerun the activation/cycle-index correlation;
# drained-cycle exit p50 should fall from 849 s to under 300 s.
```

### Files Scope

- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `TODO.md`
- `todo/tasks/t19015-brief.md`

## Acceptance Criteria

- [ ] A drained cycle logs `Cooperative drain: skipping remaining cycle stages` once and runs no further preflight or pipeline stage after the boundary where the drain was first seen.
- [ ] An undrained cycle runs every stage in its current order, and a drain marker that names another lock owner is ignored.
- [ ] Supervisor-phase drain behaviour, census handoff and the starvation escape are unchanged; a drain that skipped prefetch marks the state incomplete for the supervisor.
- [ ] `PULSE_DRAIN_FAST_EXIT=0` restores current behaviour.
- [ ] Runtime: drained-cycle exit p50 falls below 300 s over 24 h (from 849 s).

## Context & Decisions

- An alternative was to keep dispatching from the old bundle until it exits naturally. That removes four checks, but the new code would still wait about 14 minutes at p50 and the drained cycle would still run a full maintenance tail. Fast exit matches the GH#37907 design and brings both dispatch and activation forward.
- The skipped stages are either cadence-gated or run again in the activated bundle's first cycle. The standalone merge routine (120 s launchd) covers the merge pass, and the next cycle starts the async housekeeping lane.
- Back-to-back activations could keep skipping the maintenance tail. Drift redeploys are debounced to one per hour, and a drained cycle now exits within minutes, so the next cycle normally completes.
