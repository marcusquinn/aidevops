<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18463: Google-ranked Reddit opportunities and observed position history

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: existing Serper/DataForSEO guidance and shared intent matcher identified; no dedicated ranked-thread feature found.
- [x] File refs verified: serper.md, dataforseo.md and SEO experiment design exist; new helper paths declared.
- [x] Tier: standard; bounded SERP adapter and observed-history analysis using existing provider capabilities.
- [x] Seeded draft PR skipped: waits for native conversation/evidence contract.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18462. No general search/scraping platform or Lurk/AnyAPI integration.

## What

Find Reddit discussions in actual Google result sets for project buyer queries, retain dated rank observations and prioritize relevant, reply-eligible opportunities with competitor evidence.

## Why

Complement fresh-lead monitoring with durable search-visible conversations while separating observed rankings from speculation about AI citation or sales.

## Tier

**Selected tier:** `tier:standard` — known search-provider patterns, fixed observation semantics.

## How

### Files to Modify

- `NEW: .agents/seo/reddit-opportunities.md` — Reddit SEO leaf.
- `NEW: .agents/scripts/prospecting-seo-helper.py` — refresh/history CLI.
- `NEW: .agents/scripts/prospecting_seo.py` — SERP normalization/history and opportunity joins.
- `NEW: .agents/scripts/tests/test-prospecting-seo.py` — focused fixtures/tests.

Reuse `.agents/seo/serper.md`, `.agents/seo/dataforseo.md`, `.agents/seo/seo-geo-experiment-design.md` and t18448 matcher. Serper guidance is a provider recipe, not evidence of authenticated live access; verify readiness and current response/API contract.

### Files Scope

- `.agents/seo/reddit-opportunities.md`
- `.agents/scripts/prospecting-seo-helper.py`
- `.agents/scripts/prospecting_seo.py`
- `.agents/scripts/tests/test-prospecting-seo.py`
- `.agents/scripts/tests/fixtures/prospecting/serp.json`

### Complete Write Surface

- **Callers/readers:** `.agents/seo/reddit-opportunities.md`, workbench and API read the native SEO projection.
- **Writers/mutation paths:** `.agents/scripts/prospecting_seo.py` writes scoped rank observations via foundation storage; no website/provider writes.
- **Tests/fixtures:** test-prospecting-seo.py and `.agents/scripts/tests/fixtures/prospecting/serp.json`.
- **Schemas/config:** `.agents/configs/prospecting.schema.json` query/location/mode/position semantics; provider config remains existing-owned.
- **Generated/deployed mirrors:** source-only leaf; final integration owns routing and normal `setup.sh` deployment.
- **Migrations/backfills:** N/A because observations are additive and no ranking/citation history is fabricated or backfilled.
- **Cleanup/rollback paths:** disable this refresh/helper; project retention through `prospecting_store.py` retains original captures until approved removal.

### Implementation Steps

1. Add `refresh --input FILE --dry-run` plus explicit approved provider mode using existing Google SERP capability. Record exact query, date/time, provider/engine, locale/language/device where exposed, result depth, actual ordinal and original URL/snippet.
2. Distinguish unfiltered commercial-query ranking from `site:reddit.com` discovery; filtered-query position is not a global Google rank. Canonicalize supported Reddit post/comment URLs and preserve original evidence.
3. Retain repeated observation history, query-specific dedupe, rank changes and missing-window uncertainty. Not found within requested depth is not deindexed; failed calls are not rank loss.
4. Enrich selected discussions through t18462's bounded thread/rules adapter and existing matcher. Show thread age/activity, open/locked/archived state and evidence-backed multiple competitor mentions; old ranked threads are not discarded merely by the fresh-lead recency filter.
5. Prioritize useful human contributions and evidence gaps. No promise that a reply ranks, gets cited or converts; actual AI citation measurement remains #32064 and economics #32066.

### Hazards and Compatibility

- **Concurrency/atomicity:** snapshot identity binds query/provider/locale/time; atomic observation writes.
- **Migration/rollback:** additive history only; no provider/SEO configuration changes.
- **Mixed-version/backward compatibility:** preserve provider result semantics and unknown device/model fields; do not merge incompatible query cohorts.
- **Idempotency/retry:** dedupe exact runs while retaining genuinely later observations; cache expiry remains explicit.
- **Partial failure/recovery:** preserve prior observations and unfinished queries on failure; budget stops do not become rank declines.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-seo-helper.py refresh --input .agents/scripts/tests/fixtures/prospecting/serp.json --dry-run
python3 .agents/scripts/tests/test-prospecting-seo.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI produces SEO opportunity/history records; tests cover filtered versus organic ranks, locale changes, old/locked threads, multiple competitors, empty/failed pages and replay. No live spend.
- **Recovery:** checkpoint focused evidence and resume pending queries from recorded fixtures after a fuse; do not build a new SERP scraper.

## Acceptance Criteria

- [ ] Google result fixtures produce dated query-specific Reddit opportunities with rank, context, competitor evidence and history.
- [ ] Failed/missing-depth/filtered-search observations cannot become fabricated organic rank loss or citation/ROI claims.
- [ ] Existing search tooling is reused and no thread is posted to, scraping platform built or live account changed.
