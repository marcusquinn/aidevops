<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18450: Content disposition, redirect proposals and schema consistency

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: existing quality/crawler guidance reviewed; no overlapping open SEO task found.
- [x] File refs verified: programmatic-seo, schema-validator, seo_quality.py and site-crawler exist.
- [x] Tier: standard; review-only proposals within decided safety boundaries, not migration execution.
- [x] Seeded draft PR skipped: no implementation seed.

## Origin

2026-09-20 OpenCode interactive background brief. Parent: t18444. blocked-by:t18448.

## What

A content-disposition subagent/helper that reviews unique value/thinness, recommends keep/update/merge/remove, proposes old-to-new migration maps and compares structured data with visible content. It must not deindex, delete, redirect or publish automatically.

## Why

Combine existing heuristics and semantic evidence into reviewable changes without turning a quality score into irreversible SEO actions.

## Tier

Selected tier: `tier:standard`; implement evidence/rubric integration, with consequential migration authority explicitly excluded.

## How

### Files to Modify

- `NEW: .agents/seo/content-disposition.md` — review-only lifecycle agent and helper below.

NEW `.agents/seo/content-disposition.md`, `.agents/scripts/seo-content-disposition-helper.py`, `.agents/scripts/seo_content_disposition.py`; EDIT `.agents/seo/programmatic-seo.md` and `.agents/seo/schema-validator.md` only for focused integration. Reference `.agents/scripts/seo_quality.py`, `.agents/seo/site-crawler.md` and `.agents/seo/ai-hallucination-defense.md`.

### Files Scope

- `.agents/seo/content-disposition.md`
- `.agents/seo/programmatic-seo.md`
- `.agents/seo/schema-validator.md`
- `.agents/scripts/seo-content-disposition-helper.py`
- `.agents/scripts/seo_content_disposition.py`
- `.agents/scripts/tests/test-seo-content-disposition.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/disposition-pages.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/disposition-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/seo/content-disposition.md`, programmatic-seo and schema-validator consume new review records.
- **Writers/mutation paths:** `.agents/scripts/seo_content_disposition.py` writes private proposals/maps only.
- **Tests/fixtures:** `.agents/scripts/tests/test-seo-content-disposition.py` and `fixtures/marketing-decisions/disposition-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; existing seo_quality.py unchanged.
- **Generated/deployed mirrors:** source pointers only; deployment through `setup.sh`, no deployed edits.
- **Migrations/backfills:** N/A because analyses only propose migrations and never rewrite existing stores.
- **Cleanup/rollback paths:** revert `.agents/scripts/seo_content_disposition.py` and pointers; site/config originals remain intact.

### Implementation Steps

1. Add `review --input FILE --decisions FILE --dry-run`. Distinguish measured hard defects, heuristic scores, semantic originality and missing evidence. Draft holds are recommendations; never translate a score directly into noindex.
2. Keep/update/merge/remove proposals include content purpose, query/intent, backlinks, traffic/conversions, freshness, protected revenue/legal/service pages and uncertainty. Missing traffic is not zero demand.
3. Shortlist migration targets with the common matcher, support no replacement/manual review, and check target existence/status, loops/chains and intentional many-to-one mappings. No automatic redirects regardless of confidence.
4. Parse structured data deterministically, then compare scoped claims/entities with visible canonical facts. Distinguish syntax validity, visible consistency and actual factual verification; unsupported claims remain unresolved.

### Hazards and Compatibility

- **Concurrency/atomicity:** shared private writer; hashes bind source/target proposals.
- **Migration/rollback:** no migrations executed; revert optional helper/pointers without destructive restoration.
- **Mixed-version/backward compatibility:** preserve publishing_ready meaning; reject unknown versions or incoherent snapshot dates.
- **Idempotency/retry:** replay bound evidence, invalidate changed pages, deduplicate map candidates.
- **Partial failure/recovery:** incomplete crawl/demand evidence means unknown/review; preserve remaining criteria and originals.

### Verification Before Dispatch

Run `review` on new `disposition-pages.json`/decision fixtures; add/run `python3 .agents/scripts/tests/test-seo-content-disposition.py` covering useful short pages, duplicate boilerplate, protected pages, unknown demand, redirect loops/no-match and markup-visible mismatch. Run changed-file lint. Tests follow the existing Python layout; no live site or new harness.

```bash
python3 .agents/scripts/tests/test-seo-content-disposition.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** review CLI verifies lifecycle/maps/schema findings; tests prove protected-page/unknown/loop safeguards; lint checks changed source/docs.
- **Recoverability:** checkpoint after focused verification; a fuse leaves criteria open and resumes via offline fixtures, never site mutation. No broad gate.

## Acceptance Criteria

- [ ] All four disposition outcomes and abstention carry evidence; useful short/protected/unknown-demand pages are not mechanically discarded.
- [ ] Proposed redirects are validated and unmatched/looping targets are rejected without touching server configuration.
- [ ] Schema syntax, visible consistency and factual evidence are separate; no automatic deletion, noindex, canonical or publication occurs.
