## Task


Let the stale queued-run watchdog safely remove ghost runs that contain no work. Deletion should be
allowed by default only when the run has zero jobs and no logs. Any run with jobs or logs keeps
today's behaviour: deletion only with `AIDEVOPS_STALE_QUEUED_RUN_DELETE=1`.

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## Origin

Found on 2026-10-07 during an interactive check of PRs that looked stuck. A standalone run of
`.agents/scripts/pulse-stale-queued-runs.sh` reported 42 runs as `unkillable-ghost`: 40 in
`marcusquinn/aidevops` dating back to May 2026, and 2 in a managed private repo. Both cancel and
force-cancel return 409 for these runs. Each one has `jobs.total_count == 0` and no downloadable logs.

## What

Let the stale queued-run watchdog safely remove ghost runs that contain no work. Deletion should be
allowed by default only when the run has zero jobs and no logs. Any run with jobs or logs keeps
today's behaviour: deletion only with `AIDEVOPS_STALE_QUEUED_RUN_DELETE=1`.

## Why

- Today, ghosts are "logged once and left alone" (`.agents/reference/github-self-hosted-runners.md`, "Stale queued workflow watchdog"). They pile up indefinitely, inflate `status=queued` counts, and keep getting re-read on every scan. That costs REST budget and adds noise when diagnosing real queue stalls.
- The operator was cautious: "don't want to lose any work". A run with zero jobs and no logs holds no work, history, or artifacts. Deleting it removes only an empty run record, so it is safe to do by default.

## Tier

tier:standard. This is a single-helper change with careful fail-closed checks.

## How (Approach)

1. In `.agents/scripts/pulse-stale-queued-runs.sh`, in the path that currently records `unkillable-ghost`:
   re-read `GET repos/{repo}/actions/runs/{id}/jobs?filter=all`. Proceed only if `total_count == 0`,
   the run is still `queued`, and the age is still at or above the threshold. Then confirm that
   `GET .../runs/{id}/logs` returns 404 or 410, meaning nothing is downloadable.
2. Only when all checks pass, call `DELETE repos/{repo}/actions/runs/{id}` and log the outcome
   `deleted-empty-ghost`. Any API error or ambiguity must fail closed: keep the run and log
   `unkillable-ghost` as today.
3. Add `AIDEVOPS_STALE_QUEUED_RUN_DELETE_EMPTY` (default `1`; `0` disables it). Keep
   `AIDEVOPS_STALE_QUEUED_RUN_DELETE` as the separate, stronger opt-in for runs that have jobs.
4. Update the settings table in `.agents/reference/github-self-hosted-runners.md`.

### Files Scope

- `.agents/scripts/pulse-stale-queued-runs.sh`
- `.agents/reference/github-self-hosted-runners.md`

## Acceptance Criteria

- [ ] A queued run that is at least 8h old, has 0 jobs, and has no logs is deleted and logged as `deleted-empty-ghost`. Any run with at least 1 job is never deleted unless `AIDEVOPS_STALE_QUEUED_RUN_DELETE=1`.

  ```yaml
  verify:
    method: codebase
    pattern: "deleted-empty-ghost"
  ```

- [ ] Regression guard: with `AIDEVOPS_STALE_QUEUED_RUN_DELETE_EMPTY=0`, behaviour is unchanged from today. API or permission failures never lead to a delete. The existing watchdog test (if present under `.agents/scripts/tests/`) passes.

## Context & Decisions

The 42 ghosts observed on 2026-10-07 were intentionally left in place pending this change, so no history was removed by hand.

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
  "id": "I_kwDOQSEXLM8AAAABVvT3XQ",
  "title": "t18620: feat(pulse): stale queued-run watchdog safely deletes job-less ghost runs",
  "updatedAt": "2026-10-09T02:55:38Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/34001",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18620",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "34001",
  "captured_at": "2026-10-09T21:16:00Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
