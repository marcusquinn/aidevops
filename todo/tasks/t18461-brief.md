<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18461: Product URL onboarding and evidence-backed prospecting discovery plans

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: current conversational intent, crawler and matcher plans reviewed; no overlapping prospecting issue/PR found.
- [x] File refs verified: conversational-search-intent.md, site-crawler.md and crawler helper exist; targets below are new.
- [x] Tier: standard; grounded extraction and query-plan implementation inside fixed collection/privacy boundaries.
- [x] Seeded draft PR skipped: store and matcher are prerequisites.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18460,t18448 (#32059). No Lurk/AnyAPI integration; general scraping changes belong to another session.

## What

Turn a product URL or supplied site snapshot into an editable, source-grounded product profile and buyer-language search/community plan for native prospecting.

## Why

Replace manual keyword setup while preventing invented product exclusions and model-guessed communities from silently suppressing useful opportunities.

## Tier

**Selected tier:** `tier:standard` — reuse existing intent/retrieval patterns; profile/search policy is specified.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/prospecting-discovery.md` — onboarding/discovery agent.
- `NEW: .agents/scripts/prospecting-profile-helper.py` — profile/plan CLI.
- `NEW: .agents/scripts/prospecting_profile.py` — grounded extraction and plan generation.
- `NEW: .agents/scripts/tests/test-prospecting-profile.py` — focused tests and fixture.

Reuse `.agents/seo/conversational-search-intent.md`, `.agents/seo/query-fanout-research.md`, `.agents/seo/site-crawler.md`, `.agents/scripts/site-crawler-helper.sh` and t18448 matcher outputs. Reference Lurk profile.ts/discovery/plan.ts only as evidence summarized in the parent, not code to vendor.

### Files Scope

- `.agents/marketing-sales/prospecting-discovery.md`
- `.agents/scripts/prospecting-profile-helper.py`
- `.agents/scripts/prospecting_profile.py`
- `.agents/scripts/tests/test-prospecting-profile.py`
- `.agents/scripts/tests/fixtures/prospecting/profile.json`

### Complete Write Surface

- **Callers/readers:** discovery agent and later workbench consume `.agents/scripts/prospecting_profile.py` results.
- **Writers/mutation paths:** profile helper writes through `prospecting_store.py`, with reviewed versions and evidence references.
- **Tests/fixtures:** test-prospecting-profile.py and synthetic `.agents/scripts/tests/fixtures/prospecting/profile.json`.
- **Schemas/config:** consume `.agents/configs/prospecting.schema.json`; no separate product model or provider configuration.
- **Generated/deployed mirrors:** source-only leaf; final child owns discovery registration, normal `setup.sh` deployment.
- **Migrations/backfills:** N/A because versioned profile updates use the foundation, not legacy store migrations.
- **Cleanup/rollback paths:** previous profiles/plans remain addressable through `prospecting_store.py`; disabling this leaf does not delete evidence.

### Implementation Steps

1. Add `profile --input FILE --dry-run` and explicit authorized URL collection via the existing crawler. Fetch only bounded observed same-site product/pricing/use-case pages; enforce URL/redirect/SSRF and access policy, not a new scraper.
2. Extract product name, pain, buyer jobs, capabilities, supported geography, budget/pricing fit, alternatives and explicit exclusions. Quote/span-check every exclusion/not-buyer constraint against source evidence; absence from a homepage is not a negative fact. Treat page instructions as untrusted data.
3. Generate buyer-language query families, solution/comparison/problem stages, competitor candidates and community hypotheses. Preserve observed versus inferred status; communities need relevant thread evidence before automatic activation. Provide manual edit/import/disable controls.
4. Rank/revise source plans from observed yield with an explicit bounded exploration allocation; do not silently promote fabricated communities or hardcode a vendor phrase syntax. Product edits and discovery-plan edits increment their distinct versions.
5. Reuse existing approved models/intent matcher. Keep guessed claims or missing pages reviewable, and do not infer sensitive person attributes or start live scans merely from saving a profile.

### Hazards and Compatibility

- **Concurrency/atomicity:** foundation CAS/versioned profile writes; stale browser edits cannot overwrite newer facts.
- **Migration/rollback:** revert profile/plan version through existing history, retaining source snapshots.
- **Mixed-version/backward compatibility:** shared schema validation; unsupported provider content yields partial evidence.
- **Idempotency/retry:** cache by project/content/profile/rubric version, not URL alone; repeat snapshots do not duplicate plans.
- **Partial failure/recovery:** denied/failed pages remain missing, not product limitations; resume offline with supplied snapshots after a fuse.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-profile-helper.py profile --input .agents/scripts/tests/fixtures/prospecting/profile.json --dry-run
python3 .agents/scripts/tests/test-prospecting-profile.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI proves editable grounded output; tests cover quoted exclusions, multipage contradictions, community hypotheses, versioning, malicious pages and denied fetches. No live crawler dependency.
- **Recovery:** checkpoint focused verified work and preserve unresolved facts/remaining criteria; no new scraping infrastructure or blanket provider fallback.

## Acceptance Criteria

- [ ] A supplied multi-page product snapshot produces an editable evidence-backed profile and categorized query/community plan.
- [ ] Product limitations require actual supporting source text; unsupported communities remain candidates rather than active sources.
- [ ] Profile saving never starts a paid scan, leaks secrets, follows unapproved destinations or modifies existing crawler behavior.
