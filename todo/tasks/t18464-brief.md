<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18464: Competitor recommendations and evidence-backed pain-theme insights

## Pre-flight

- [x] Memory recall: no relevant lessons in parent queries.
- [x] Discovery pass: content research and queued community/ROI analysis reused; no duplicate native prospecting insights feature found.
- [x] File refs verified: content/research.md and SEO experiment guidance present; new implementation paths declared.
- [x] Tier: standard; semantic aggregation over the defined project evidence model.
- [x] Seeded draft PR skipped: downstream of collector and store.

## Origin

2026-09-20 interactive background brief. Parent: t18459. blocked-by:t18462. Native implementation only; no Lurk/AnyAPI integration.

## What

Aggregate competitor mentions/recommendations/sentiment, buyer stages and recurring pain themes from project conversations, with drill-down evidence and date-window comparisons.

## Why

Turn a lead feed into useful product/content intelligence without inventing market share, causal insights or personal profiles.

## Tier

**Selected tier:** `tier:standard` — established semantic analysis with fixed evidence/privacy boundaries.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/prospecting-insights.md` — insight interpretation leaf.
- `NEW: .agents/scripts/prospecting-insights-helper.py` — derive/compare CLI.
- `NEW: .agents/scripts/prospecting_insights.py` — bounded aggregation and evidence-linked themes.
- `NEW: .agents/scripts/tests/test-prospecting-insights.py` — focused tests/fixture.

Reference `.agents/content/research.md`, `.agents/seo/conversational-search-intent.md`, `.agents/seo/seo-geo-experiment-design.md` and t18453 community triage. Emit compatible evidence for t18454 reports rather than adding a second financial attribution engine.

### Files Scope

- `.agents/marketing-sales/prospecting-insights.md`
- `.agents/scripts/prospecting-insights-helper.py`
- `.agents/scripts/prospecting_insights.py`
- `.agents/scripts/tests/test-prospecting-insights.py`
- `.agents/scripts/tests/fixtures/prospecting/insights.json`

### Complete Write Surface

- **Callers/readers:** `.agents/marketing-sales/prospecting-insights.md`, workbench/API and existing report handoffs consume derived results.
- **Writers/mutation paths:** `.agents/scripts/prospecting_insights.py` writes versioned derived artifacts through foundation storage.
- **Tests/fixtures:** test-prospecting-insights.py with `.agents/scripts/tests/fixtures/prospecting/insights.json`.
- **Schemas/config:** `.agents/configs/prospecting.schema.json` plus local rubric/version metadata; no global model changes.
- **Generated/deployed mirrors:** source leaf only; `setup.sh` and final registration own deployment.
- **Migrations/backfills:** N/A because raw conversations and historical labels are not rewritten.
- **Cleanup/rollback paths:** supersede/recompute derived views via `prospecting_store.py`; preserve source evidence and manual dispositions.

### Implementation Steps

1. Implement `derive --input FILE --decisions FILE --dry-run`; consume supplied/approved decisions via existing model routing. Resolve competitor aliases/domains with evidence and support multiple entities per conversation plus unknown/ambiguous matches.
2. Separate mention, recommendation, comparison, complaint and sentiment/target. Link every count to source IDs/spans; do not infer the sentiment of an entire thread from one comment or attribute quoted criticism to the author automatically.
3. Produce pain/theme/community-stage summaries with representative verbatim quotes, counts, coverage, denominator and observed windows. Distinguish posts/comments/threads so repeated comments do not masquerade as independent customers. Suppress personal/small-cell details as existing privacy policy requires.
4. Compare like-for-like windows and rubric versions; expose changing collection coverage and no-data states. Provide content/product opportunity handoffs through the shared matcher/report contract, not automatic outreach or proof of market-wide demand.
5. Keep manual hide/not-fit feedback explicit and separate from raw observations and model training. No silent adaptive targeting or demographic/user-history profiling.

### Hazards and Compatibility

- **Concurrency/atomicity:** derive from a pinned as-of snapshot and write immutable versioned insights.
- **Migration/rollback:** recomputation creates new versions; never overwrite historical evidence or dispositions.
- **Mixed-version/backward compatibility:** reject incomparable cohorts or mark comparison unavailable; preserve original rubric IDs.
- **Idempotency/retry:** stable source IDs prevent duplicate counts and theme proliferation on replay.
- **Partial failure/recovery:** retain partial coverage and failed classifications explicitly; no fabricated zero competitors or themes.

### Verification Before Dispatch

```bash
python3 .agents/scripts/prospecting-insights-helper.py --help
python3 .agents/scripts/tests/test-prospecting-insights.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** exercise derive on insights.json with inline synthetic decisions in the focused test; verify aliases, multi-entity sentiment, quoted speech, duplicate comments, privacy, comparable windows and null data through real CLI output.
- **Recovery:** checkpoint focused verified work; keep remaining criteria and resume offline after rate/cost stops. No new analytics/test infrastructure.

## Acceptance Criteria

- [ ] Project snapshots yield competitor and pain-theme views with auditable counts, examples, dates and coverage.
- [ ] Ambiguous entities, quoted sentiment and duplicate/correlated observations retain uncertainty rather than fabricated recommendations or market share.
- [ ] Derivation never contacts prospects, profiles users, changes targeting silently or rewrites raw evidence/manual feedback.
