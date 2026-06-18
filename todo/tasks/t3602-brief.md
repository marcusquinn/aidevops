---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3602: Reduce GitHub API pressure during pulse startup and recovery

## Origin

- **Created:** 2026-06-18
- **Session:** Interactive aidevops feedback triage from user `robstiles` monitoring report.
- **Issue:** GH#25047
- **Parent task:** none
- **Blocked by:** none

## What

Reduce GitHub secondary-rate-limit loops that surface at REST Search by lowering aggregate pulse GitHub API pressure during startup and cooldown recovery.

Implement a dispatch ramp that starts with one worker slot and adds one slot per two-minute pulse until the normal minimum worker concurrency is reached, then continues one slot per pulse until max concurrency is reached. Keep broader follow-up work worker-ready for header diagnostics, shared read-pressure governance, and Search avoidance.

## Why

User evidence shows every captured secondary-limit event surfaced through REST Search (`_rest_issue_search` / `rest-search`), but one strong pre-event snapshot had only 2 Search calls in 5 minutes alongside 191 total GitHub API calls: 132 REST core, 36 GraphQL, 2 REST Search, and 21 other. That suggests Search is often the visible tripwire, not necessarily the sole cause.

Pulse startup/recovery can create a feedback loop: pulse restarts or exits cooldown, performs many GitHub state checks, then a Search call happens during that pressure and observes/trips the secondary limit.

## Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-lib.sh` — cap dispatch capacity during boot/cooldown recovery so worker launch pressure ramps gradually instead of jumping to min/max concurrency.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-staggering.sh` — cover one-slot initial cap, one-slot-per-120s ramp, max-cap ceiling, and feature-flag bypass.
- `FOLLOW-UP: .agents/scripts/shared-gh-secondary-cooldown.sh` — ensure retained cooldown events include response headers needed to classify Search quota vs REST core vs GraphQL vs secondary/abuse throttling.
- `FOLLOW-UP: .agents/scripts/shared-gh-wrappers-status.sh` and batch prefetch callers — avoid REST Search when repo scope is known and prefer cached/per-repo REST reads during pressure windows.

## Acceptance Criteria

- [ ] Startup/recovery dispatch capacity is capped to 1 worker at ramp start.
- [ ] Capacity increases by one slot per `AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS` seconds, default `120`.
- [ ] The ramp cap applies after provider/load/min-floor policy so min concurrency does not create an immediate burst.
- [ ] The cap never exceeds normal max concurrency.
- [ ] The ramp is feature-flagged with `AIDEVOPS_PULSE_DISPATCH_RAMP_ENABLED=0`.
- [ ] Tests cover ramp behaviour and normal-mode no-op behaviour.
- [ ] Follow-up issue context captures header telemetry, shared read-pressure governor, startup/recovery dampening, and Search avoidance.

## Verification

Run:

```bash
.agents/scripts/tests/test-pulse-dispatch-staggering.sh
shellcheck .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/tests/test-pulse-dispatch-staggering.sh
.agents/scripts/linters-local.sh
```

## Follow-up Scope

If this ramp lands first, keep these worker-ready follow-ups:

1. Capture missing headers for every GitHub cooldown event: status, `x-ratelimit-resource`, `x-ratelimit-remaining`, `x-ratelimit-reset`, `x-ratelimit-used`, `retry-after`, `x-github-request-id`, endpoint family, and pulse phase.
2. Add a shared GitHub read-pressure governor that pauses or sharply reduces noncritical REST core, REST Search, and GraphQL reads after any secondary-limit event.
3. Jitter or defer batch prefetch/cache warmups during boot and cooldown recovery; prefer stale cache over immediate fanout.
4. Route known-repo issue/PR checks away from REST Search where exact repo scope is already available.
