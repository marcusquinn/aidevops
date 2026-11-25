## Origin

Interactive session, Pulse throughput mission (parent GH#40108 / t19322, Phase 1 follow-up). Implemented by the filing session.

## What

Under `PULSE_DISPATCH_LOCK_SPLIT=1`, a worker-exit refill-only run that owns the runner's dispatch lock (and not the instance lock) dispatches under the elastic dispatch lease, the same way the cycle's own dispatch rounds do. Its rounds then end when slots are full or candidates run out, not when a fixed per-pass cycle clock runs down.

## Why

Measured on one macOS runner (20 slots, split-lock canary, v3.39.280, `~/.aidevops/logs/pulse.log` and `dispatch-stages.tsv`, 2026-11-24/25):

- Worker-exit refill drains hold the dispatch lock almost continuously. The cycle's dispatch stages (`early_dispatch`, `cycle_dispatch_max`, `post_label_refill`, `cycle_final_refill`) logged `Dispatch stage ... skipped: dispatch lock held by PID ...` 104 times. Only the cycle has the elastic lease (`_pulse_dispatch_lease_active` in `.agents/scripts/pulse-watchdog.sh` accepts only the instance-lock owner), so most dispatching now runs in the clock-bounded context.
- A split-lock refill skips the GH#35349 admission budget but keeps the normal cycle clamp, which is about 1,710 s per pass from pass start (t19337 refreshes it per pass). Each pass stops admitting candidates once less than ceremony reserve + pre-stage margin (~400 s + 60 s) remains, then the next pass pays a fresh full census (80–205 s, 55 of 61 censuses were full scans).
- Round endings in the current log: 54 budget-reserve stops (`Dispatch_max stopping early: ... below candidate admission reserve` or `skipped before candidate enumeration`) versus 10 `no available worker slots`.
- Pass boundaries line up with the largest dispatcher-idle gaps after the 05:20Z disk recovery: 05:56Z (338 s) and 06:19Z (602 s). Ceremony idle share was 0.34 for 05:20–07:00Z; census occupancy 8.2/20 against a target of 20.

## Tier

tier:standard. One predicate in a lease helper plus one regression assertion in an existing test.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-watchdog.sh` — `_pulse_dispatch_lease_active` (around line 213): also return 0 when `PULSE_REFILL_ONLY=1`, the instance lock is not owned, `pulse_dispatch_lock_still_owned` succeeds, and `$(pulse_dispatch_lockdir)/heartbeat_epoch` is no older than `PULSE_LOCK_MAX_AGE_S`. Update the comment above it.
- EDIT: `.agents/scripts/tests/test-dispatch-max-parallel.sh` — extend `test_elastic_dispatch_lease` (around line 1908) with split-lock refill holder cases: fresh dispatch-lock heartbeat gives the lease; a stale heartbeat, a lost lock, or `PULSE_REFILL_ONLY` unset gives none.

### Implementation Steps

1. Add a small helper `_pulse_dispatch_lock_lease_active` next to `_pulse_dispatch_lease_active`; call it first inside `_pulse_dispatch_lease_active` after the `PULSE_ELASTIC_DISPATCH_ENABLED` guard.
2. Keep the existing instance-owner path unchanged.

### Hazards and Compatibility

- Default off: with `PULSE_DISPATCH_LOCK_SPLIT` unset, refill-only runs never own the dispatch lock (`_DISPATCH_LOCK_OWNED` stays false), so behaviour is unchanged.
- A hung holder is still bounded. `_dispatch_refresh_owner_lease` refreshes the dispatch-lock heartbeat on every candidate admission, and contenders reclaim a holder whose heartbeat is older than `PULSE_LOCK_MAX_AGE_S`. The lease also lapses at that age.
- Round length stays bounded by `DISPATCH_ROUND_TOPUP_MAX_ROUND_S` (1800 s) for mid-round top-ups and by the ranked candidate list. Process length stays bounded by `PULSE_EVENT_REFILL_MAX_PASSES`. Bundle and transition checks between passes are unchanged.
- Candidate stage timeouts are no longer clamped to the cycle remainder for this holder; the per-candidate watchdog (600 s or adaptive) still applies, the same as cycle rounds under the lease.
- Supervisor-phase and other dispatch-lock-only callers without `PULSE_REFILL_ONLY=1` keep bounded semantics.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-watchdog.sh .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-event-refill.sh
bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh
```

### Files Scope

- `.agents/scripts/pulse-watchdog.sh`
- `.agents/scripts/tests/test-dispatch-max-parallel.sh`

## Acceptance Criteria

- [ ] A split-lock refill-only process that owns the dispatch lock with a fresh heartbeat gets `_pulse_dispatch_lease_active` = 0, `_dispatch_round_budget_plan before` = `full 0`, and `_pulse_cycle_remaining_seconds` returns 1 (no fixed deadline).
- [ ] Negative: stale dispatch-lock heartbeat, dispatch lock owned by another PID, or `PULSE_REFILL_ONLY` unset gives no lease (existing bounded behaviour).
- [ ] Existing instance-owner lease tests still pass.
- [ ] Runtime: after deploy, `Dispatch_max stopping early: ... below candidate admission reserve` lines from `event_refill_drain` rounds drop to near zero and `pulse-throughput-report-helper.sh report` ceremony idle share falls below the 0.27–0.39 range measured on 2026-11-24/25.

## Context & Decisions

- Phase 3 of GH#40108 plans to remove refill workarounds after split-lock becomes default. This change is the smallest step that lets the refill holder dispatch like the cycle, and needs no removal yet.
- Not chosen: raising `PULSE_LOCK_MAX_AGE_S` or the refill pass clock. That would only move the boundary and keep the per-pass re-census.

## Relevant Files

- `.agents/scripts/pulse-watchdog.sh:211-240` — lease and cycle remainder.
- `.agents/scripts/pulse-instance-lock.sh:652-677` — `pulse_dispatch_lock_still_owned`, `pulse_dispatch_lock_heartbeat`.
- `.agents/scripts/pulse-dispatch-lib.sh:2338` — `_dispatch_refresh_owner_lease`.
- `.agents/scripts/pulse-event-refill.sh:595-635,879-883` — split-lock pass clock (t19337) and budget skip (t19324).
- `.agents/scripts/pulse-dispatch-lib-candidates.sh:895-924,1068-1082` — round budget plan and candidate admission reserve.
