## Task


Pulse cycles on this runner spend their wall-clock budget in preflight and time out there. They never
reach `_pulse_run_deterministic_pipeline` (`.agents/scripts/pulse-wrapper.sh`, called around line 1817).
Every stage after preflight is therefore starved: in-cycle merge pass, dirty-PR sweep, todo-ref sync,
dependency graph, blocked-status refresh, `dispatch_max`, `stale_queued_runs`, and `dependabot_alert_monitor`.
Make preflight bounded enough that the deterministic pipeline runs on most cycles. At minimum, the
hourly/optional stages must not depend on preflight finishing.

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## Origin

Found on 2026-10-07 during an interactive check of open PRs that looked stuck. On this runner, the hourly
`stale_queued_runs` watchdog (merged in #33874 that morning) ran once at 09:27Z and never again.
The cause turned out to be broader: the whole post-preflight deterministic pipeline stopped running.

## What

Pulse cycles on this runner spend their wall-clock budget in preflight and time out there. They never
reach `_pulse_run_deterministic_pipeline` (`.agents/scripts/pulse-wrapper.sh`, called around line 1817).
Every stage after preflight is therefore starved: in-cycle merge pass, dirty-PR sweep, todo-ref sync,
dependency graph, blocked-status refresh, `dispatch_max`, `stale_queued_runs`, and `dependabot_alert_monitor`.
Make preflight bounded enough that the deterministic pipeline runs on most cycles. At minimum, the
hourly/optional stages must not depend on preflight finishing.

## Why

Evidence from `~/.aidevops/logs/pulse.log` on 2026-10-07 (line numbers are from that file):

- `Stage start: reap_orphan_workers` is the first stage in the deterministic pipeline. Its last occurrence was at line 354278, around 09:27Z. The only `stale_queued_runs` stage ran then: `pulse-stage-timings.log` shows `2026-10-07T09:27:06Z stale_queued_runs`.
- From line 330000 to the end of the log (about 23:30Z), the counts are:
  - `Stage timeout: preflight_label_maintenance`: 21
  - `Stage timeout: preflight_prefetch_and_scope`: 21
  - `Stage timeout: prefetch_state`: 17
  - `Stage complete: prefetch_state`: 4
- A typical sequence is line 377871 `preflight_label_maintenance (timeout 197s)`, then line 377914 `exceeded 197s`, then `Post-label dispatch_max skipped: insufficient wall-clock budget`, then line 377922 `prefetch_state (timeout 503s)`, then a new launchd `pulse-wrapper invoked` at 21:40:01Z. Another example is line 382124 `prefetch_state (timeout 463s)` followed by line 382656 `exceeded 463s`.
- No `budget-priority: deferred ... 'stale_queued_runs'` line exists, so the stage was never deferred. It was simply never reached.
- Downstream effects seen the same day: 42 job-less queued runs stayed in place, and the in-cycle merge pass did not run. The standalone merge routine was still working.

This is not REST/GraphQL quota exhaustion. `gh api rate_limit` showed `core` at 4997/5000 at 23:34Z.

## Tier

tier:standard. This needs diagnosis of the prefetch/label-maintenance cost per repo, then a bounded
fix in pulse orchestration. It touches the dispatch path, so expect thinking-tier elevation by the
pre-dispatch detector.

## How (Approach)

1. Measure where preflight time goes. Use `pulse-stage-timings.log` together with the `_prefetch_single_repo`
   and `dormancy` log lines to identify the slow repos and calls in `prefetch_state` and
   `_preflight_label_maintenance`. Note that about 54 pulse repos are configured.
2. Choose the smallest effective fix. Candidates:
   - Give `preflight_label_maintenance` a resumable cursor and cap its per-cycle share, the same way the merge pass uses its PR cursor (GH#33307/GH#33569).
   - When `prefetch_state` times out, continue into the deterministic pipeline with cached state instead of ending the cycle.
   - Move `stale_queued_runs` and `dependabot_alert_monitor` into the existing async post-dispatch housekeeping, or into a separate hourly launchd routine, so they cannot be starved.
3. Keep the existing budget-priority semantics (`pulse-budget-priority.sh`) and stage-wiring contracts
   (`tests/test-pulse-dispatch-engine-stage-wiring.sh`).

### Files Scope

- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-dispatch-preflight-lib.sh`
- `.agents/scripts/pulse-prefetch.sh`
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`

## Acceptance Criteria

- [ ] Within one hour of deployment on a runner with the same repo count, `pulse.log` shows `Stage start: stale_queued_runs` and `Stage start: reap_orphan_workers` in at least half of the cycles.

  ```yaml
  verify:
    method: bash
    run: "rg -c 'Stage start: (reap_orphan_workers|stale_queued_runs)' ~/.aidevops/logs/pulse.log"
  ```

- [ ] Regression guard: the existing pulse stage-wiring and budget-priority tests still pass, and dispatch and merge reserves (GH#33307) are unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh && bash .agents/scripts/tests/test-pulse-graphql-budget-priority.sh"
  ```

## Context & Decisions

Related but distinct items:
- #33944/#33947 cover the post-label refill dependency normalization (dispatch path).
- #33993 covers Linux systemd unit timeouts killing workers.
- Closed #33246/#33569 were earlier fixes for cycle-budget starvation.

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.30 plugin for [OpenCode](https://opencode.ai) v1.18.35 with claude-opus-5-5 spent 58m and 35,562 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVvTtfg",
  "title": "t18619: fix(pulse): preflight timeouts starve the deterministic pipeline (merge pass, dispatch_max, stale_queued_runs)",
  "updatedAt": "2026-10-09T02:55:37Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/34000",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18619",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "34000",
  "captured_at": "2026-10-09T21:16:02Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
