---
description: Background jobs, scheduled tasks, long-running processes, operations, and worker architecture for business apps
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Operations, Jobs, and Scheduling

Background work is product infrastructure, not an implementation detail. Model jobs, schedules, long-running processes, retries, logs, and admin controls from the first non-trivial app.

## Runtime objects

| Object | Purpose |
|--------|---------|
| `job_definitions` | Registered job types, handler key, queue, timeout, retry policy, owner, enabled state |
| `scheduled_jobs` | Recurring schedule: cron/interval, timezone, calendar, enabled state, next run |
| `jobs` | Enqueued job instance: type, status, queue, priority, payload, run time, target entity |
| `job_runs` | Execution attempt/run: worker, started/finished, duration, result, error summary |
| `job_attempts` | Retry history with attempt number, backoff, error class, next attempt |
| `job_locks` | Concurrency/advisory locks, lease owner, expiry, lock key, stale lock policy |
| `worker_heartbeats` | Worker identity, queues served, last seen, version, capacity, drain state |
| `operation_logs` | Admin/maintenance action, actor, scope, command, result, evidence |

Rules:

- `jobs` are runtime execution records; `scheduled_jobs` are recurring definitions; workflows are business state machines.
- Every side-effecting job needs an idempotency key, target entity, retry policy, timeout, and audit/provenance reference.
- Separate queue, priority, and worker capacity so long-running work cannot starve interactive jobs.
- Use leases/locks for singleton jobs and entity-scoped jobs; expired locks need safe recovery rules.
- Job payloads store references and minimal parameters, not secrets or large source data.

## Long-running processes and mass actions

| Object | Purpose |
|--------|---------|
| `process_definitions` | Named long-running business/admin process with inputs, permissions, and handler |
| `process_runs` | Process instance: status, actor, target scope, progress, result, cancellation state |
| `process_steps` | Ordered steps/checkpoints with status, progress, retry/cancel policy |
| `job_batches` | Batch of jobs for import/export, bulk update, report generation, or sync |
| `mass_actions` | User-requested bulk action: entity type, filter/scope snapshot, action, counts, notify flag |
| `mass_action_items` | Per-record status/result/error for a bulk action when traceability matters |

Rules:

- Use `process_runs` when users need progress, pause/resume/cancel, approvals, or step visibility.
- Use `job_batches` when a process fans out into many jobs that must be counted, retried, or rolled up.
- Mass actions must snapshot the selected filter/scope, check permissions at execution time, and record per-record failures when partial success is possible.
- Long-running jobs emit progress/activity events and optional notifications when finished.

## Trigger sources

| Trigger | Standard handling |
|---------|-------------------|
| Schedule | `scheduled_jobs` creates `jobs` using timezone/calendar-aware next-run calculation |
| Domain event | `change_events` / `outbox_events` enqueue work after transaction commit |
| Workflow timer | `workflow_timers` creates jobs or resumes workflow runs |
| User/admin action | `mass_actions` or `process_runs` records actor, scope, and notify preference |
| Integration/webhook | Webhook event validates, dedupes, then enqueues idempotent work |
| Maintenance | Operation logs capture actor, evidence, dry-run/result, and rollback note |

Rules:

- Schedule in UTC internally, preserve source timezone, and use working calendars when business-time SLAs matter.
- Use separate maintenance queues for cleanup, retention, search indexing, cache refresh, reconciliation, and repair work.
- Treat missed schedules explicitly: skip, catch up once, catch up all, or require operator approval.

## Working calendars and SLAs

| Object | Purpose |
|--------|---------|
| `working_calendars` | Timezone, weekdays, default working windows, owner/team/workspace scope |
| `working_calendar_exceptions` | Holidays, shutdowns, extra working days, user/team overrides |
| `sla_policies` | Response/resolution clocks, pause rules, escalation targets |
| `sla_events` | Clock start/pause/resume/breach/resolve events tied to records and workflows |

Rules:

- Keep calendar math in shared domain code and test DST, timezone, holiday, and overnight ranges.
- SLA timers should produce workflow timers/jobs and audit/activity events, not hidden UI-only state.

## Worker package defaults

- Monorepos use an explicit `apps/worker` or `packages/jobs` when background execution is not hosting-native.
- Worker code imports domain services and database clients; UI/app code enqueues jobs through typed service functions.
- Provide local commands for `worker:dev`, `worker:run-once`, `worker:drain`, and `worker:retry-failed` when the app owns its worker runtime.
- Expose an admin screen for queues, schedules, failures, retries, disabled jobs, worker heartbeats, and operation logs.

## Verification

- Trace one scheduled job from definition to next-run calculation, job row, lock, attempt, run log, notification, and audit event.
- Trace one bulk action through filter snapshot, permission check, batch jobs, per-record failures, partial-success result, and retry.
- Prove duplicate delivery/retry is idempotent for one external side effect.
- Prove one missed schedule policy and one expired-lock recovery path.
- Confirm job payloads, logs, and errors do not expose secrets or private source data.
