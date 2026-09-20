<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18454: Decision reports, calibration and end-to-end ROI evaluation

## Pre-flight

- [x] Memory recall: no relevant lessons in parent query.
- [x] Discovery pass: merged Jev evaluation journal #32051 and existing marketing optimization reviewed; reuse rather than duplicate.
- [x] File refs verified: marketing helper/contract, Jev evaluation and report templates exist.
- [x] Tier: standard; integrate decided metric/evidence contracts, not a new analytics platform.
- [x] Seeded draft PR skipped: depends on concrete feature outputs.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18447,t18449,t18450,t18451,t18452,t18453.

## What

Join domain decision artifacts into existing marketing/SEO-GEO reports and add a small private evaluation path for labeled holdouts, calibration, acceptance/repair effort, total cost and business outcomes.

## Why

Measure useful completion and human time, not just cheap tokens or vendor benchmarks; prioritize work without fabricating revenue attribution.

## Tier

Selected tier: `tier:standard`; existing reporting/statistical boundaries remain authoritative.

## How

### Files to Modify

- `NEW: .agents/scripts/marketing-decision-report-helper.py` — aggregate report/evaluation adapter.
- `NEW: .agents/scripts/marketing_decision_reports.py` — versioned joins and metrics.
- `EDIT: .agents/reports/marketing.md` — decision evidence/ROI handoff.
- `EDIT: .agents/reports/seo-geo.md` — per-engine decision evidence handoff.
- `NEW: .agents/scripts/tests/test-marketing-decision-reports.py` — scoped fixtures/tests.

Reference `.agents/scripts/marketing-optimization-helper.py:38-61`, `.agents/aidevops/performance/03-optimization-projections.md`, `.agents/scripts/jev-evaluation.py` and `.agents/seo/seo-geo-experiment-design.md`. Do not lower existing privacy/experiment floors or broaden the Jev journal's permitted data/categories.

### Files Scope

- `.agents/scripts/marketing-decision-report-helper.py`
- `.agents/scripts/marketing_decision_reports.py`
- `.agents/reports/marketing.md`
- `.agents/reports/seo-geo.md`
- `.agents/scripts/tests/test-marketing-decision-reports.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/report-input.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/report-holdout.json`

### Complete Write Surface

- **Callers/readers:** `.agents/reports/marketing.md` and `.agents/reports/seo-geo.md` consume canonical report data.
- **Writers/mutation paths:** `.agents/scripts/marketing_decision_reports.py` writes private evaluations and permitted aggregate reports.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-decision-reports.py` and report-input/report-holdout fixtures.
- **Schemas/config:** reuse shared decision and `marketing_optimization_contract.py` semantics, adapter-local versioning only.
- **Generated/deployed mirrors:** use the existing exporter selected by `.agents/reports/seo-geo.md`; no hand-edited exported/deployed files.
- **Migrations/backfills:** N/A because prior attribution/journal stores are read-only and no historical costs are repriced.
- **Cleanup/rollback paths:** revert `.agents/scripts/marketing_decision_reports.py` and template pointers; retain original evidence/reports.

### Implementation Steps

1. Implement `report --input FILE --dry-run` and `evaluate --input FILE --dry-run`. Validate scope, source IDs, time windows, currencies, attribution models and observation freshness; reject contradictory joins.
2. Track valid/failed/deferred rows, accepted/repaired/rejected recommendations, false acceptance, abstention/coverage, calibrated versus merely reported confidence, end-to-end time, reviewer time and total known cost (collection, inference, generation, retries, review). Unknown components stay null; OAuth estimates are not billed cash.
3. Use independently labeled held-out samples per task/rubric/model; prohibit Jev-generated ground truth, same-model self-check as independent validation and a universal confidence cutoff. Synthetic tests verify wiring only.
4. Reuse existing marketing measures for margin/refunds/cost/currency and distinguish observational outcomes from approved causal experiments. Per-engine GEO lines precede any aggregate; citation share or creative longevity never establishes profit.
5. Rank opportunities with transparent benefit/effort/risk assumptions and uncertainty, record retain/revise/stop/inconclusive, review date and owner. Emit concise narrative inputs with source evidence, not fabricated decision rationales or public provider benchmarks.

### Hazards and Compatibility

- **Concurrency/atomicity:** immutable report inputs and common atomic storage; consistent as-of joins.
- **Migration/rollback:** no historic store mutation or statistical-floor changes; additive adapter can be removed safely.
- **Mixed-version/backward compatibility:** unknown metric/schema versions fail closed; retain existing report formats through adapters.
- **Idempotency/retry:** same input/version yields stable aggregate identity; do not double-count repeated observations.
- **Partial failure/recovery:** suppress unsafe/private cells, report incomplete cost/coverage and retain failed inputs; never claim savings from missing data.

### Verification Before Dispatch

```bash
python3 .agents/scripts/marketing-decision-report-helper.py report --input .agents/scripts/tests/fixtures/marketing-decisions/report-input.json --dry-run
python3 .agents/scripts/marketing-decision-report-helper.py evaluate --input .agents/scripts/tests/fixtures/marketing-decisions/report-holdout.json --dry-run
python3 .agents/scripts/tests/test-marketing-decision-reports.py
python3 .agents/scripts/tests/test-marketing-optimization.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLIs exercise reports/evaluation; focused tests cover joining, privacy, unknown costs and false ROI claims; existing test preserves attribution/experiment semantics. No broad repo gate.
- **Recoverability:** checkpoint focused verified work, preserve remaining criteria and continue with synthetic evidence if live metrics are unavailable. No credentials required.

## Acceptance Criteria

- [ ] Reports join all feature families with source-linked prioritized recommendations and separate measured, estimated and unknown economics.
- [ ] Holdout evaluation reports errors/coverage/repair burden without treating synthetic or model-produced labels as human ground truth.
- [ ] Missing costs, correlations, aggregate citations and repeated answers cannot become fabricated ROI, causality or provider benchmark claims.
