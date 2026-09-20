<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18446: Offline marketing and site snapshot importers

## Pre-flight

- [x] Memory recall: no relevant hits for the parent query.
- [x] Discovery pass: `f85c65460`, existing Jev and marketing snapshot tooling reviewed; no related open Jev/SEO work found.
- [x] File refs verified: SEO exporters, Google Ads historical-metrics client and marketing optimization CLI exist; new paths explicitly marked.
- [x] Tier: standard; adapt existing normalization patterns inside a fixed read-only boundary.
- [x] Seeded draft PR skipped: issue-only implementation handoff.

## Origin

2026-09-20 OpenCode interactive, maintainer-authorized background work. Parent: t18444. blocked-by:t18445. Wait for its merged contract, do not invent a parallel schema.

## What

Import authorized local CSV/JSON exports into the shared decision snapshots: Google Ads search terms/account entities, Meta creative/insights manifests, GSC query-page rows, page/crawl inventory and captured AI answers/community text.

## Why

Offline imports make useful analysis possible before credentials or provider integrations and keep tests reproducible.

## Tier

Selected tier: `tier:standard`; ordinary parser/normalizer work, not a verbatim simple-tier contract.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing-snapshot-helper.py` — importer entry point and companion module/docs below.

NEW `.agents/scripts/marketing-snapshot-helper.py`, `.agents/scripts/marketing_snapshot_imports.py`, `.agents/reference/marketing-snapshot-imports.md`, tests and fixtures. Reuse `.agents/scripts/seo-export-gsc.sh`, `.agents/scripts/domain_opportunity_google_ads.py` and `.agents/scripts/marketing-optimization-helper.py` as read-only patterns. The historical-metrics client is NOT a search-term report API.

### Files Scope

- `.agents/scripts/marketing-snapshot-helper.py`
- `.agents/scripts/marketing_snapshot_imports.py`
- `.agents/reference/marketing-snapshot-imports.md`
- `.agents/scripts/tests/test-marketing-snapshot-imports.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/import-google.csv`
- `.agents/scripts/tests/fixtures/marketing-decisions/import-all.json`

### Complete Write Surface

- **Callers/readers:** domain CLIs consume normalized exports from `.agents/scripts/marketing-snapshot-helper.py`.
- **Writers/mutation paths:** `.agents/scripts/marketing_snapshot_imports.py` writes only explicit private output; source CSV/JSON remains unchanged.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-snapshot-imports.py` and `fixtures/marketing-decisions/import-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; importer-local column/unit mappings only.
- **Generated/deployed mirrors:** normal `setup.sh` deployment; no generated/deployed files edited here.
- **Migrations/backfills:** N/A because the new import path does not rewrite existing exporters or records.
- **Cleanup/rollback paths:** remove `.agents/scripts/marketing_snapshot_imports.py` and companions; keep original exports/private output under operator retention.

### Implementation Steps

1. Implement `import --kind KIND --input FILE --dry-run` and an explicit private-output option. Record original column mapping, source hash, scope, dates, timezone, currency, row omissions and unknown metrics.
2. Normalize micros/amounts, conversion counts/value and attribution windows without rounding loss or mixing currencies. Keep clicks, impressions, spend, refunds and conversions distinct; preserve censored/absent query coverage rather than inventing zero rows.
3. Preserve raw strings as inert data, including CSV formula-like cells and injection text. Reject traversal, duplicate/conflicting IDs, malformed CSV/JSON, ambiguous units or mismatched accounts; report recoverable row errors without dropping evidence silently.
4. Supply small synthetic fixtures for each supported kind and explicit mapping/unsupported-format documentation; derive schema fields from t18445.

### Hazards and Compatibility

- **Concurrency/atomicity:** use foundation atomic writes and account-scoped identities.
- **Migration/rollback:** new files only; remove importer without modifying original exports.
- **Mixed-version/backward compatibility:** reject unknown schemas/ambiguous units; report unfamiliar columns explicitly.
- **Idempotency/retry:** same scoped export replays; conflicting IDs cannot overwrite prior output.
- **Partial failure/recovery:** keep row-level errors and originals; no network, private log dump or silent data loss.

### Verification Before Dispatch

Run `python3 .agents/scripts/marketing-snapshot-helper.py import --kind google-ads --input .agents/scripts/tests/fixtures/marketing-decisions/import-google.csv --dry-run`; add/run `python3 .agents/scripts/tests/test-marketing-snapshot-imports.py` covering all kinds, units, nulls, conflicts, malformed rows and no-network behavior. Validate output with the foundation CLI; run `.agents/scripts/linters-local.sh --changed`. Checks are implementation acceptance, not already-run evidence.

```bash
python3 .agents/scripts/tests/test-marketing-snapshot-imports.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** import CLI proves each source mapping; tests cover malformed/partial/scope/unit cases; lint checks changed files.
- **Recoverability:** checkpoint focused verified work; preserve remaining criteria and resume from original offline exports after a fuse. No broad gate or release.

## Acceptance Criteria

- [ ] All named input families have a synthetic import example and produce scope/time/evidence-preserving records usable by downstream CLIs.
- [ ] Missing conversions/costs, censored search terms and failed AI captures are never converted to zero or negative observations.
- [ ] Input files, existing exporters and live accounts are unchanged; reruns cannot cross-contaminate accounts or overwrite conflicting output.
