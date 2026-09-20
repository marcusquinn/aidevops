<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18449: Evidence-backed internal links and cannibalization review

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: current helper has overlap detection; no parallel SEO implementation found in bounded searches.
- [x] File refs verified: internal-linker, ranking-opportunities and seo-analysis-helper are present; new helper paths are explicit.
- [x] Tier: standard; extend existing workflows with a bounded semantic review stage.
- [x] Seeded draft PR skipped: wait for the shared matcher.

## Origin

2026-09-20 OpenCode interactive background brief. Parent: t18444. blocked-by:t18448.

## What

Extend existing internal-link and ranking-opportunity agents with batch link recommendations and evidence-based cannibalization interpretation, using shortlisted pages rather than all-pairs model calls.

## Why

The current helper detects query overlap, while useful actions require intent, page purpose, anchor context and business evidence.

## Tier

Selected tier: `tier:standard`; known agent/helper patterns inside a proposal-only boundary.

## How

### Files to Modify

- `EDIT: .agents/content/internal-linker.md` — add the batch review handoff; other targets below.

EDIT `.agents/content/internal-linker.md` and `.agents/seo/ranking-opportunities.md`; NEW `.agents/scripts/seo-link-review-helper.py`, `.agents/scripts/seo_link_review.py`, focused tests/fixtures. Read `.agents/scripts/seo-analysis-helper.sh` as candidate-generation prior art; keep its CLI/output backward compatible and do not edit it for cosmetic cleanup.

### Files Scope

- `.agents/content/internal-linker.md`
- `.agents/seo/ranking-opportunities.md`
- `.agents/scripts/seo-link-review-helper.py`
- `.agents/scripts/seo_link_review.py`
- `.agents/scripts/tests/test-seo-link-review.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/links-pages.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/links-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/content/internal-linker.md` and `.agents/seo/ranking-opportunities.md` invoke review; reports consume its artifacts.
- **Writers/mutation paths:** `.agents/scripts/seo_link_review.py` writes proposals only, never HTML/CMS/redirect changes.
- **Tests/fixtures:** `.agents/scripts/tests/test-seo-link-review.py` and `fixtures/marketing-decisions/links-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json` and matcher contracts; local rubrics only.
- **Generated/deployed mirrors:** no generated/deployed edits; normal later `setup.sh` deployment.
- **Migrations/backfills:** N/A because no legacy shell helper or site state is changed.
- **Cleanup/rollback paths:** revert `.agents/scripts/seo_link_review.py` and two pointers; existing link/overlap workflow remains available.

### Implementation Steps

1. Provide `analyze --input FILE --decisions FILE --dry-run` using the common matcher/runner. Shortlist a configurable bounded number of relevant candidates per page and report candidate-recall limits.
2. Link proposals require an observed anchor span, destination status/canonical evidence, topical reason, existing-link dedupe and source location. Exclude self-links, invalid destinations and fabricated anchors; preserve no-useful-link outcomes.
3. Use overlapping GSC query/page pairs as candidates only. Distinguish complementary intents, legitimate multiple results, duplication and unknown cases; record traffic/conversions/links where supplied. Propose differentiate/update/merge-review rather than destructive merging.
4. Reuse existing recommendation formats where possible and emit shared evidence IDs for downstream content disposition/reporting.

### Hazards and Compatibility

- **Concurrency/atomicity:** use shared atomic output, bind source/anchor/destination hashes.
- **Migration/rollback:** proposals only; revert helper/pointers without site rollback.
- **Mixed-version/backward compatibility:** old overlap helper output remains unchanged; validate imported versions.
- **Idempotency/retry:** scoped evidence replay deduplicates links; changed anchors invalidate proposals.
- **Partial failure/recovery:** unknown crawl/performance means review, never safe-merge inference; preserve all candidates for recovery.

### Verification Before Dispatch

Run the new `analyze` CLI with `links-pages.json` and supplied decision fixtures under `.agents/scripts/tests/fixtures/marketing-decisions/`; add/run `python3 .agents/scripts/tests/test-seo-link-review.py` for orphan candidates, existing links, anchor changes, invalid URLs, complementary versus duplicate intent and abstention. Run `.agents/scripts/linters-local.sh --changed`; do not run a whole-site live crawl.

```bash
python3 .agents/scripts/tests/test-seo-link-review.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** analyze CLI proves link/cannibalization records; tests cover stale anchors, overlap ambiguity and no mutations; lint checks helper/pointers.
- **Recoverability:** preserve the original objective and unresolved pairs after a fuse, checkpoint verified source and resume offline. No full crawl or broad gate.

## Acceptance Criteria

- [ ] Link recommendations resolve to actual spans/destinations, retain evidence and skip invalid or already-linked pairs.
- [ ] Same-query multi-URL cases are not automatically labeled harmful or merged; uncertainty and legitimate overlap survive.
- [ ] No source page, index directive, canonical or redirect changes occur during analysis, and existing helper behavior is unchanged.
