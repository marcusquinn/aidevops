<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18465: Budgeted prospecting routines, usage and internal alert delivery

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: existing routine scheduling, social lease/notification and channel guidance reviewed; no prospecting scheduler found.
- [x] File refs verified: routines.md, routine-helper.sh, routine-schedule-helper.sh and Slack/Discord/email guidance exist.
- [x] Tier: standard; reuse existing scheduler and implement a specified bounded outbox, not a new dispatch engine.
- [x] Seeded draft PR skipped: domain jobs must merge first.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18463,t18464. Native operator alerts only; no prospect contact, Lurk/AnyAPI integration or broad scraping.

## What

Wire native prospecting scan/SEO/insight jobs into existing aidevops routines with project budgets, usage/activity views and opt-in email/Slack/Discord/webhook digests.

## Why

Make the workflow repeatable without duplicate scans, surprise spend or repeated/unauthorized notifications.

## Tier

**Selected tier:** `tier:standard` — implement explicit leases, reservations and delivery states using existing patterns.

## How

### Files to Modify

- `NEW: .agents/scripts/prospecting-routine-helper.py` — due-job/digest/usage entry point.
- `NEW: .agents/scripts/prospecting_jobs.py` — job adapters, budget reservations and run receipts.
- `NEW: .agents/scripts/prospecting_alerts.py` — internal digest selection/outbox/sinks.
- `NEW: .agents/templates/prospecting-routines.md` — disabled routine definitions and operator configuration.
- `NEW: .agents/scripts/tests/test-prospecting-routines.py` — focused clock/transport tests.

Reuse `.agents/reference/routines.md`, `.agents/scripts/routine-schedule-helper.sh`, `.agents/scripts/_knowledge_social_lease.py`, `.agents/scripts/_knowledge_social_notifications.py`, `.agents/services/communications/slack.md`, `.agents/services/communications/discord.md` and `.agents/services/email/email-agent.md`. Do not assume documentation-only channel helpers are installed; use the existing authorized service route or explicit unavailable status.

### Files Scope

- `.agents/scripts/prospecting-routine-helper.py`
- `.agents/scripts/prospecting_jobs.py`
- `.agents/scripts/prospecting_alerts.py`
- `.agents/templates/prospecting-routines.md`
- `.agents/scripts/tests/test-prospecting-routines.py`
- `.agents/scripts/tests/fixtures/prospecting/routines.json`

### Complete Write Surface

- **Callers/readers:** existing routine engine calls prospecting-routine-helper.py; workbench/API read usage/job state through `prospecting_jobs.py`.
- **Writers/mutation paths:** `prospecting_jobs.py` owns project job/budget receipts; `prospecting_alerts.py` sends only to explicitly approved internal sinks.
- **Tests/fixtures:** `.agents/scripts/tests/test-prospecting-routines.py` with synthetic clock and mock sink fixture.
- **Schemas/config:** `.agents/configs/prospecting.schema.json` job/usage records; secret handles reference existing credential tooling.
- **Generated/deployed mirrors:** `.agents/templates/prospecting-routines.md` stays disabled; no launchd/cron/Pulse or production routine edits in this task.
- **Migrations/backfills:** N/A because new opt-in job/outbox records do not alter historical routine/marketing records.
- **Cleanup/rollback paths:** disable project job/alert config, release owned leases and retain outbox/run receipts through `prospecting_jobs.py`.

### Implementation Steps

1. Add `plan --input FILE --dry-run`, project `run-due`, `digest-preview` and `usage` commands. Reuse calendar/timezone semantics; provide daily/hourly/manual scans and independent SEO/insight cadences, default disabled and bounded.
2. Reserve project/provider requests, rows, tokens, wall time and known estimated cost before work. Record actual/estimated/unknown cost separately, including cached reads, errors and manual review where supplied. Unknown price cannot satisfy a dollar-cap guarantee; request caps remain enforced. No vendor wallet or commercial plan limits.
3. Use stable scheduled-slot/manual-run IDs, fenced leases and per-project concurrency limits; skipped/budget/partial/error/cancelled states retain coverage. Restart must not duplicate a paid scan or advance completed windows on failure.
4. Build digest payloads only for newly qualifying lead versions with score/reason/evidence link and community-policy caveats. Separate post/comment/thread counts, local hidden/not-fit preferences and already-delivered receipts; empty digest sends nothing.
5. Deliver only to operator-configured verified Slack/Discord/email/webhook targets. Protect credential-bearing URLs and redact logs, use bounded allowlisted transport, block SSRF/redirect/DNS-rebinding and malicious mentions/HTML. Scraped text can never supply recipients or endpoints. Read-only collector credentials are not reused for sends.
6. Use outbox states pending/sending/sent/failed/unknown; a post-send timeout remains unknown and needs reconciliation, not blind retry. Dedupe by project, destination, digest window and lead-version set; no claim of guaranteed exactly-once delivery when the provider lacks it.

### Hazards and Compatibility

- **Concurrency/atomicity:** atomically reserve budgets and acquire one run owner; outbox identity prevents competing deliveries.
- **Migration/rollback:** additive records/config; disabling schedules does not remove evidence or reset budget history.
- **Mixed-version/backward compatibility:** consume pinned project/rubric versions and existing routine semantics; no dispatch engine edits.
- **Idempotency/retry:** exact replay reuses receipts; uncertain external delivery is not automatically resent.
- **Partial failure/recovery:** checkpoints retain remaining work and unsent/unknown digests; security/cost stops never enlarge permissions.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-routine-helper.py plan --input .agents/scripts/tests/fixtures/prospecting/routines.json --dry-run
python3 .agents/scripts/tests/test-prospecting-routines.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** dry-run proves schedule/budget selection; fake-clock/mock-sink tests cover restart/concurrency, DST, budget caps, empty digests, duplicate/unknown delivery and malicious destinations. Reuse existing routine tests if integration semantics change.
- **Recovery:** checkpoint focused verified work; no real schedules, accounts, webhook sends or paid scans are activated during verification.

## Acceptance Criteria

- [ ] Configured synthetic jobs produce bounded scan/SEO/insight runs, visible usage/activity and correctly filtered digest previews.
- [ ] Concurrent/restarted runs cannot exceed reservations or blindly duplicate unknown deliveries; empty digests send nothing.
- [ ] No public posting, prospect messaging, unauthorized destination, secret disclosure or automatic schedule installation occurs.
