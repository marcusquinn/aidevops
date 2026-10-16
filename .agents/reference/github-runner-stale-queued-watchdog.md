<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stale Queued Workflow Watchdog

Parent runbook: `reference/github-self-hosted-runners.md`.

Pulse runs `.agents/scripts/pulse-stale-queued-runs.sh` as a bounded optional
stage, at most once per hour per Pulse-managed repository. It skips local-only,
maintenance-disabled and contributor repositories and verifies repository write
permission before touching Actions runs. The token must also have Actions write
permission; denied API calls are non-fatal and raw responses are never logged.

| Setting | Default | Behaviour |
|---------|---------|-----------|
| `AIDEVOPS_STALE_QUEUED_RUN_MAX_AGE_HOURS` | `8` | Minimum queued age in whole hours; `0` disables the stage. |
| `AIDEVOPS_STALE_QUEUED_RUN_DELETE_EMPTY` | `1` | Deletes ghosts (409 from both cancellation endpoints) only when a fresh read shows zero jobs and the logs endpoint returns 404/410; logged as `deleted-empty-ghost`. Any API error keeps the run. `0` disables. |
| `AIDEVOPS_STALE_QUEUED_RUN_DELETE` | `0` | Only `1` allows deletion of stale ghosts that return HTTP 409 from both cancellation endpoints and have jobs or logs. |

Each scan requests one page (up to 100 stale queued runs), rechecks status and
age before writes, requests cancellation, and tries force-cancellation if the
first request returns 409 or leaves the run queued. Logs contain run ID, workflow
name, age in seconds and outcome. A successful request is not reported as a
confirmed cancellation until a subsequent read observes a cancelled conclusion;
a run that started meanwhile is reported as `no-longer-queued` instead.
Cancellation can be asynchronous; `cancellation-pending` is retried next hour.
Reruns (`run_attempt > 1`) are excluded: their original creation timestamp does
not establish the current attempt's queue age. Age is conservatively based on
the original run's `created_at`, not runner capacity or job count.

Unkillable ghosts are logged once per repository/run ID and left alone by default,
except job-less runs with no logs, which hold no work and are deleted.
Deleting runs with jobs or logs removes history: enable it only deliberately. Cadence and
ghost records live under `~/.aidevops/.agent-workspace/pulse/stale-queued-runs/`.
The stage respects Pulse stop/rate-limit flags, the circuit breaker, REST budget
admission and the wrapper's stage timeout. Standalone execution uses the same
quota guard:

```bash
bash .agents/scripts/pulse-stale-queued-runs.sh
```

For operational verification, compare queued Actions runs before and after an
hourly scan and inspect watchdog outcomes. `pulse-wrapper.sh --dry-run` does not
cancel or delete runs. A scan is limited to 100 candidates; additional old runs
are handled by rotating through up to ten pages (GitHub's 1,000-result filtered
search limit) on later scans, even if the first page contains permanent ghosts.
The owner-PID lock is released on normal exit or stage termination and a dead
owner is reclaimed on the next scan.
