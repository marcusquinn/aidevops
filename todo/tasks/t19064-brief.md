<!-- aidevops:brief-schema=v2 -->

# perf(pulse): let an admitted dispatch round finish under a bounded cooperative-drain grace

## Pre-flight

- [x] Memory recall: `cooperative drain dispatch round activation pulse` → 0 hits
- [x] Discovery pass: recent commits on `pulse-dispatch-lib.sh` (t19015 1864838b02, GH#38048 4a061e2937, GH#37907 48b3770658); 0 open PRs; 0 claimed issues on the file
- [x] File refs verified: `pulse-dispatch-lib.sh:860-873,1300-1304,1663-1667`, `pulse-lifecycle-helper.sh:1020-1089`, `pulse-dispatch-lib-capacity.sh:204-221,255-270`, `pulse-dispatch-engine.sh:1510-1515` present at HEAD
- [x] Tier: `tier:thinking` (Pulse dispatch-path self-hosting file)
- [x] Seeded draft PR decision recorded: skipped (interactive session implements directly)

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive (productivity mission, GH#38332 follow-up)
- **Conversation context:** Log mining for GH#38332 (mean worker concurrency below target while ready work waits) found that cooperative bundle drain is now the most frequent reason a dispatch round ends early.

## What

When deploy reconciliation asks the running Pulse cycle to drain (GH#37907, `LOCKDIR/drain_requested`), a dispatch round that was already admitted keeps starting candidates from its ranked list while the drain request is younger than `AIDEVOPS_PULSE_DRAIN_ROUND_GRACE_S` (default 600s). After the grace, the round stops at the next candidate boundary, as today. Unchanged: no new dispatch round, census or floor re-enumeration starts under a drain; stage-boundary fast exit (t19015) and census handoff (GH#38048) still run. `AIDEVOPS_PULSE_DRAIN_ROUND_GRACE_S=0` restores the current immediate stop.

## Why

Evidence (one runner, local logs 2026-11-13T03:00Z to 2026-11-16T07:50Z, `~/.aidevops/logs/pulse.log`):

- Dispatch rounds ending under drain: 81 `Dispatch_max stopping early: cooperative drain requested` plus 67 `Dispatch_max skipped: cooperative drain requested`. Only 11 rounds ended on the slot budget.
- Rounds that ended under drain processed 636 of 2676 ranked candidates (24%), leaving 2040 unprocessed across 34 rounds. Normal rounds processed 1693 of 2537 (67%). Source: `Dispatch path=max complete: ... processed=X/Y` lines paired with the preceding drain line.
- 28 runtime activations in the last 24h (10 releases, 7 script-drift redeploys, 2 plist repairs, the rest session deploys). The first launch after an activation took a median of 11.1 min (mean 17.5 min) against a 0.9 min median gap between launches; 8.2h of post-activation gap in 24h. Source: bundle epoch in pulse.log vs `dedup.ceremony_total` rows in `~/.aidevops/logs/dispatch-stages.tsv`.
- Reconciliation never kills a cycle younger than the drain ceiling and defers older cycles while the elastic owner lease is fresh (`pulse-lifecycle-helper.sh:1020-1089`). It still writes the drain marker for any earlier-bundle lock owner, so every activation currently cuts the running round short.
- GH#38332 acceptance (2026-11-16): launches/day met; mean concurrency 3.50-3.70 against a target of 5 or more.

## Tier

**Selected tier:** `tier:thinking`. **Tier rationale:** this edits the Pulse dispatch loop (self-hosting file) and the GH#37907 drain contract.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib.sh`: add `_pulse_drain_stops_admitted_round`. It returns 1 (continue) while the drain marker owned by this process is younger than the grace, and 0 (stop) otherwise, printing the bundle id. Use it in `_dispatch_floor_loop` (serial) and `_dispatch_max_should_stop` (parallel) in place of `_pulse_drain_requested_bundle`. `_dispatch_compute_capacity` keeps using `_pulse_drain_requested_bundle`.
- `EDIT: .agents/scripts/tests/test-dispatch-max-parallel.sh`: pin `test_serial_loop_cooperative_drain` to `AIDEVOPS_PULSE_DRAIN_ROUND_GRACE_S=0` (legacy contract), and add cases: a fresh marker within the grace keeps the serial loop going and logs the grace once; an aged marker stops the loop.

### Complete Write Surface

- **Callers/readers:** `_dispatch_floor_loop` (`pulse-dispatch-lib.sh:1274`), `_dispatch_max_should_stop` (`:1650`). Unchanged readers of `_pulse_drain_requested_bundle`: `_dispatch_compute_capacity` (`:915`), `_pulse_cycle_drain_exit` (`:887`), floor refill (`pulse-dispatch-engine.sh:1511`), census handoff (`pulse-dispatch-lib-capacity.sh:210`), supervisor (`pulse-wrapper.sh:1738`).
- **Writers/mutation paths:** none new. The marker is written only by `_pulse_request_cycle_drain` (`pulse-lifecycle-helper.sh:990`).
- **Existing verification/tests:** `tests/test-dispatch-max-parallel.sh`, `tests/test-pulse-supervisor-starvation-escape.sh`, `tests/test-pulse-dispatch-candidate-snapshot.sh`, `tests/test-pulse-lifecycle-helper.sh`.
- **Schemas/config:** new env `AIDEVOPS_PULSE_DRAIN_ROUND_GRACE_S` (non-negative integer seconds; invalid falls back to 600).
- **Generated/deployed mirrors:** deployed via `setup.sh` runtime bundle. No generated files.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** set the env to 0, or revert the PR.

### Implementation Steps

1. `_pulse_drain_stops_admitted_round`: call `_pulse_drain_requested_bundle` (return 1 when no drain for this owner). Read the grace (default 600, invalid → 600). Grace 0 → stop. Marker mtime from `_file_mtime_epoch`. Unreadable, future-dated or age ≥ grace → stop. Otherwise log once per process: `Dispatch_max continuing admitted round under cooperative drain grace (age Ns < Gs) for activated bundle B` and return 1.
2. Serial loop and parallel stop check: replace the drain block with the new helper; keep the existing log line for the stop.

### Hazards and Compatibility

- **Concurrency/atomicity:** the marker is owner-bound and removed when the lock is released, so a later lock owner never inherits a grace. Launched candidates are written to the snapshot `.consumed` ledger (`_dispatch_ranked_candidate_consumed`), which the GH#38048 handoff transfers, so the activated bundle does not retry them.
- **Reconciliation:** cycles younger than the drain ceiling are never force-replaced; older cycles are deferred while the owner heartbeat lease is fresh, up to the hard cap. The grace bounds the extra delay to about one grace plus in-flight ceremonies.
- **Mixed-version/backward compatibility:** only the draining (old) bundle's loop behaviour changes; the change takes effect for cycles started after deploy.
- **Idempotency/retry:** unchanged. The stop flag, GraphQL breaker, REST headroom and slot budget fences still run on every iteration.
- **Partial failure/recovery:** any helper failure stops the round (fail closed to current behaviour).

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-supervisor-starvation-escape.sh
bash .agents/scripts/tests/test-pulse-dispatch-candidate-snapshot.sh
shellcheck .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/tests/test-dispatch-max-parallel.sh
.agents/scripts/linters-local.sh --changed
```

- **Production evidence after deploy:** `rg "continuing admitted round under cooperative drain grace" ~/.aidevops/logs/pulse.log`, and re-run the drained-round processed/ranked tally. Drained rounds should process well above 24% of ranked candidates.
- **Broad verification trigger:** not required.

### Files Scope

- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/tests/test-dispatch-max-parallel.sh`

## Acceptance Criteria

- [ ] Under a fresh drain marker owned by this process, the serial and parallel loops keep starting candidates until the grace expires; with grace 0 or an aged marker they stop at the next candidate boundary.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-max-parallel.sh"
  ```

- [ ] No new dispatch round, census or floor re-enumeration starts under a drain (existing `Dispatch_max skipped: cooperative drain requested` behaviour unchanged).
- [ ] A drain marker for another owner PID is still ignored.
- [ ] ShellCheck is clean and `linters-local.sh --changed` passes.

## Context & Decisions

- Rejected: removing the mid-round drain stop entirely. Early-dispatch rounds run up to 3655s, which would delay the activated bundle by up to an hour.
- Rejected for this task: raising `AIDEVOPS_SCRIPT_DRIFT_MIN_INTERVAL_SECONDS` (default 3600) to cut activations. It trades fix latency for fewer drains and is tracked separately.
- Grace default 600s: ceremony p90 is about 430s (`dedup.ceremony_total`), so a 10-minute grace lets a parallel round fill its admitted slots while keeping activation delay bounded.
