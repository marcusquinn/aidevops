<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18462: Incremental Reddit discovery and staged community-triage orchestration

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: Reddit account ingestion exists (PRs #28663/#28984); it is not a public query discovery pipeline. No overlapping open Reddit task found.
- [x] File refs verified: Reddit read adapter, knowledge store/lease and social operations guidance present; new prospecting files below.
- [x] Tier: standard; read-only collection adapter and staged orchestration using defined contracts.
- [x] Seeded draft PR skipped: reuse delivered profile/triage exports.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18461,t18453 (#32065). This task calls existing authorized collection capabilities; it does not replicate AnyAPI or general site scraping.

## What

Collect bounded search/community candidates, triage titles before fetching shortlisted threads/comments, attach fresh community-rule evidence and persist actionable comment-level leads using #32065's analysis.

## Why

Supply the missing acquisition loop while controlling request/inference costs and preserving partial coverage instead of silently losing conversations.

## Tier

**Selected tier:** `tier:standard` — existing collector/lease/triage patterns with fixed no-write policy.

## How

### Files to Modify

- `NEW: .agents/scripts/prospecting-scan-helper.py` — scan/status/resume CLI.
- `NEW: .agents/scripts/prospecting_collectors.py` — narrow provider-neutral search/thread/rules adapter.
- `NEW: .agents/scripts/prospecting_scan.py` — staged pipeline and persistence.
- `NEW: .agents/scripts/tests/test-prospecting-scan.py` — focused transport/replay tests and fixture.

Reference `.agents/content/social-reddit.md:71-118`, `.agents/scripts/knowledge_social_reddit.py:16-62`, `.agents/scripts/_knowledge_social_lease.py`, `.agents/aidevops/knowledge-plane/05-social-operations.md` and t18453 community helper. Verify current authorized API access, installed PRAW version/exports, scopes and terms before adding narrow search/rules calls; do not assume account-history streams implement them.

### Files Scope

- `.agents/scripts/prospecting-scan-helper.py`
- `.agents/scripts/prospecting_collectors.py`
- `.agents/scripts/prospecting_scan.py`
- `.agents/scripts/tests/test-prospecting-scan.py`
- `.agents/scripts/tests/fixtures/prospecting/scan.json`

### Complete Write Surface

- **Callers/readers:** profile/workbench/routine callers invoke `.agents/scripts/prospecting-scan-helper.py`; #32065 analyzes shortlisted evidence.
- **Writers/mutation paths:** `.agents/scripts/prospecting_scan.py` writes foundation projections/checkpoints; provider calls are read-only.
- **Tests/fixtures:** test-prospecting-scan.py and `.agents/scripts/tests/fixtures/prospecting/scan.json` contain synthetic provider pages.
- **Schemas/config:** `.agents/configs/prospecting.schema.json` adapter/result contract, no new global provider/default model registry.
- **Generated/deployed mirrors:** normal `setup.sh` deployment; no deployed collector or scheduler changes.
- **Migrations/backfills:** N/A because existing account ingestion/corpora are not migrated; new projections reference existing evidence when available.
- **Cleanup/rollback paths:** `.agents/scripts/prospecting_scan.py` cancellation releases its owned lease; prior complete checkpoints remain intact.

### Implementation Steps

1. Provide `scan --input FILE --dry-run` and explicit project-based live mode. Define search, community listing, thread/comments and rules capability results with provenance, budgets, pagination and unavailable status. Existing API/archive/browser-gap policy and readiness apply; no anti-bot/proxy/captcha workaround or AnyAPI dependency.
2. Search active query/community plans and reserve a small explicit bootstrap/exploration budget for provisional candidates when no observed plan exists. Feed observed thread yield back to the profile/discovery contract before activating communities; this avoids a profile/collector dependency cycle. Dedupe stable provider IDs and retain source/query evidence. Only advance coverage watermarks after complete windows; budget/timeout leaves a visible gap. Reconcile edited/deleted content conservatively.
3. Batch cheap title relevance first, then spend remaining budgets on selected full posts/comments. Retain uncertain/unread versus rejected distinction and sampling coverage; do not silently lose rows when one batch fails.
4. Invoke t18453 for product/intent/category analysis; require genuine quotes and owner-readable reasons. Distinguish buyer asks from seller promotion using conversation content, not personal profiling. Keep each relevant comment's identity and thread context so one thread can yield multiple leads.
5. Attach community policy text/source/time, stale/unavailable status, locked/archived/deleted thread status and safe human next steps. Cache and refresh rules by bounded policy; unknown rules never imply permission to promote. Never invoke Reddit posting, voting, moderation, save, messaging or account-history private inbox routes.

### Hazards and Compatibility

- **Concurrency/atomicity:** one fenced project scan owner; foundation transactions bind results, cost reservations and checkpoints.
- **Migration/rollback:** existing Reddit collector unchanged; remove optional orchestration while retaining source evidence.
- **Mixed-version/backward compatibility:** pin verified provider/parser and decision versions; incompatible/denied routes remain explicit unavailable.
- **Idempotency/retry:** overlap windows and repeated comments dedupe; partial pages do not skip unread history; 429 honors cooldown.
- **Partial failure/recovery:** checkpoint remaining windows/rows on cost/security/cancellation stop; no credential/scope/provider escalation.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-scan-helper.py scan --input .agents/scripts/tests/fixtures/prospecting/scan.json --dry-run
python3 .agents/scripts/tests/test-prospecting-scan.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI exercises staged collection through supplied decisions; tests prove dedupe, missing/edited comments, watermark gaps, stale rules, cancellation, cooldown and write-unreachability. Existing `.agents/tests/test-knowledge-social-reddit.sh` applies if reused behavior changes.
- **Recovery:** checkpoint functional evidence; verify with recorded transport if live access is unavailable. Do not broaden into scraping-platform work to finish.

## Acceptance Criteria

- [ ] A synthetic incremental search produces distinct post/comment leads with source quotes, community rules and explicit coverage/cost receipts.
- [ ] Budget/call failures leave unread candidates and incomplete windows resumable; duplicate runs preserve dispositions and do not duplicate leads.
- [ ] No provider mutation, private inbox collection, Lurk/AnyAPI dependency or general scraping/anti-bot implementation is reachable.
