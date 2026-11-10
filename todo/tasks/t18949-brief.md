## What

Add a bounded `delivery` admission class to the GitHub REST transport governor, and use it for the worker-bus relay's reads. Delivery reads skip only the even-spacing primary pacing schedule while the available share of the window is healthy. Below the floor they are paced like everything else.

## Why

The worker-bus relay forwards new human comments, labels and closures on a worker's issue to the live worker session. Workers can then adapt mid-run instead of finishing stale work.

In practice it almost never delivers:

- Relay log history: 1 `sent` line against 26 deferred or failed lines.
- Every relay attempt since v3.39.158 (7 of 7) was `transport error_kind=github-api-read-deferred deferred_by=local_admission attempted=false`.
- Pulse logged 431 `local primary pacing: time to reset divided by remaining quota` deferrals.

Primary pacing (`gh_transport_capacity.py` `primary_wait`, t18827 / #36201) keeps one shared GCRA schedule per credential. Each admission advances the next slot by one interval. The pulse makes about 22k REST reads per day, which keeps that slot far enough ahead that the governor's admission wait (`gh-transport-governor.py` `_acquire`, at most 10s) cannot reach it. A caller that makes a few reads per cycle therefore loses nearly every time. There is no priority concept in the transport.

## How

- `.agents/scripts/gh_transport_capacity.py`: in `capacity_wait`, after the concurrency and 900-points/min secondary checks, admit without primary pacing when `AIDEVOPS_GH_ADMISSION_CLASS=delivery` and `remaining - reserved >= max(1, limit // 4)`. Do not advance the shared pacing slot for these admissions. Their spend still lowers server-reported `remaining`, so bulk pacing tightens on its own.
- Unchanged for every class: cooldowns, exhaustion, revalidation and stale-refresh, concurrency and secondary ceilings, and reservation accounting (all in `gh_transport_budget.py` `acquire`).
- `.agents/scripts/worker-bus-relay-helper.sh` `_relay_get`: run the `gh api` read with `AIDEVOPS_GH_ADMISSION_CLASS=delivery`. The relay's existing shell gates (`_relay_api_allowed`: stop flag, rate-limit flag, breaker, deferrable REST priority) stay in force.
- `.agents/scripts/tests/test-gh-transport-budget.py`: one focused case. A delivery read is admitted where a normal read is paced, and paced again below the floor.

### Files Scope

- .agents/scripts/gh_transport_capacity.py
- .agents/scripts/worker-bus-relay-helper.sh
- .agents/scripts/tests/test-gh-transport-budget.py

## Acceptance

- With healthy quota, relay reads are not deferred by `local primary pacing`.
- Below 25% of the window limit, delivery reads are paced exactly as before.
- Existing transport tests pass: `python3 .agents/scripts/tests/test-gh-transport-budget.py`.
- After deploy, `[worker-bus-relay] sent` lines appear when live workers have new issue activity, and `deferred_by=local_admission` relay lines drop.

## Verification

- `python3 .agents/scripts/tests/test-gh-transport-budget.py`
- `shellcheck .agents/scripts/worker-bus-relay-helper.sh`
- `rg "worker-bus-relay" ~/.aidevops/logs/pulse.log | tail` after deploy
