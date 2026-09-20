<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18452: Engine-specific AI visibility capture and analysis

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: existing GEO measurement guidance reviewed at `f85c65460`; no overlapping open SEO/Jev work found.
- [x] File refs verified: ai-search-scoring, KPI template and experiment design exist; new implementation paths declared below.
- [x] Tier: standard; measurement and access boundaries are specified, implementation adapts existing patterns.
- [x] Seeded draft PR skipped: worker implements against merged predecessors.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18448.

## What

Create an AI-visibility monitoring leaf and helper that captures/imports dated engine answers, extracts observed citations/brands, classifies recommendations/sentiment/source type, and compares controlled cohorts. Support approved collection paths but keep unsupported consumer surfaces explicitly unavailable.

## Why

Automate evidence collection/coding without confusing a model answer, a citation and a commercially useful recommendation.

## Tier

Selected tier: `tier:standard`; fixed read-only measurement contract, no new authority or scraping bypass.

## How

### Files to Modify

- `NEW: .agents/seo/ai-visibility-monitor.md` — agent and collection/coverage instructions.
- `NEW: .agents/scripts/ai-visibility-helper.py` — capture import and analysis CLI.
- `NEW: .agents/scripts/ai_visibility.py` — normalized observation and coding logic.
- `NEW: .agents/scripts/tests/test-ai-visibility.py` — focused standard-library tests and the two fixtures in scope.

Reference `.agents/seo/ai-search-scoring.md:91-118`, `.agents/seo/seo-geo-experiment-design.md:33-69`, `.agents/seo/ai-search-kpi-template.md` and existing browser/provider readiness guidance. Existing metric semantics are authoritative.

### Files Scope

- `.agents/seo/ai-visibility-monitor.md`
- `.agents/scripts/ai-visibility-helper.py`
- `.agents/scripts/ai_visibility.py`
- `.agents/scripts/tests/test-ai-visibility.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/visibility-answers.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/visibility-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/seo/ai-visibility-monitor.md` and later reports consume the new helper artifacts.
- **Writers/mutation paths:** `.agents/scripts/ai_visibility.py` writes private captures/observations, never engine settings or sites.
- **Tests/fixtures:** `.agents/scripts/tests/test-ai-visibility.py` with scoped synthetic captures.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; engine/mode metadata is local module configuration, not a global provider mapping.
- **Generated/deployed mirrors:** source only; `setup.sh` handles later deployment, t18458 handles discovery.
- **Migrations/backfills:** N/A because this new opt-in observation stream rewrites no existing records.
- **Cleanup/rollback paths:** revert `.agents/scripts/ai_visibility.py` and leaf; private capture deletion stays operator-owned.

### Implementation Steps

1. Implement `analyze --input FILE --decisions FILE --dry-run` plus an explicit capture-import path. Store exact prompt, cohort, engine/product/model when exposed, search/grounding mode, locale/language, time, session context, outcome status and raw-answer source ID. Failed collection is not a negative answer.
2. Parse visible URLs and exact entities in code, then use bounded semantics for recommendation context, ambiguity and sentiment. Multiple competitors are supported; do not force one Choice. Track mention, recommendation and citation separately and do not attribute a negative statement to a cited source without supporting evidence.
3. Classify cited-source types and hand off question/page gaps to t18448. Report per-engine/mode lines, valid denominators, completion coverage and repeat variation. Aggregate only after component tables with explicit weights/cohort contributors.
4. Agent collection may use existing approved read-only provider/browser routes after readiness and task authority checks, never arbitrary endpoints or a normal signed-in profile. API versus consumer UI results remain separate. If no supported collection route exists, import supplied captures and report unavailable rather than pretending end-to-end live monitoring.
5. Default to a small commercially relevant cohort and explicit query/token/time/spend limits. No scheduled crawling, account creation, subscriptions or live calls in tests. A citation is not factual verification; answerability is not citation probability.

### Hazards and Compatibility

- **Concurrency/atomicity:** use shared atomic artifacts; uniquely identify repeated runs without treating them as independent users.
- **Migration/rollback:** additive observation files only; reverting source leaves prior captures available.
- **Mixed-version/backward compatibility:** unknown model/mode is explicit; never combine incompatible engine surfaces silently.
- **Idempotency/retry:** retries preserve failure receipts and original cohort; repeated captures get explicit identities.
- **Partial failure/recovery:** rate-limit/cost/access stops retain unfinished prompts and coverage; resume only the authorized collection path.

### Verification Before Dispatch

```bash
python3 .agents/scripts/ai-visibility-helper.py analyze --input .agents/scripts/tests/fixtures/marketing-decisions/visibility-answers.json --decisions .agents/scripts/tests/fixtures/marketing-decisions/visibility-decisions.json --dry-run
python3 .agents/scripts/tests/test-ai-visibility.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI proves observation/report path; tests cover multiple competitors, mention/citation separation, failed requests, mode/cohort differences and denied collection; lint covers changed files. Future checks, not already-run proof.
- **Recoverability:** commit focused verified progress, keep unfulfilled criteria open and resume with offline captures after a safety stop. No broad gate or public benchmark.

## Acceptance Criteria

- [ ] Per-engine/mode reports show observed brands, citations, recommendations, sentiment/source types and correct coverage denominators.
- [ ] Multiple competitors, failed requests, missing model IDs and unavailable consumer surfaces remain explicit rather than fabricated or counted as absence.
- [ ] Default execution needs no credentials/network and never promises causality, citation likelihood or proprietary retrieval visibility.
