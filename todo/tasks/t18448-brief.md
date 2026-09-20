<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18448: Shared intent-to-page matching and paid-to-organic opportunities

## Pre-flight

- [x] Memory recall: no relevant hits in parent query.
- [x] Discovery pass: current SEO/marketing source reviewed; no open matching work found; existing fan-out remains the domain authority.
- [x] File refs verified: query-fanout, conversational intent, meta-creator and landing congruence docs exist.
- [x] Tier: standard; adapt established retrieval and evidence patterns with fixed no-mutation limits.
- [x] Seeded draft PR skipped: dependency-first implementation.

## Origin

2026-09-20 OpenCode interactive, background implementation requested. Parent: t18444. blocked-by:t18446.

## What

One reusable matcher for paid-query/ad-to-page fit, GSC query mapping, buyer-question coverage, title/H1 intent fit, answerability and converting terms without a suitable page. Produce prioritized content or landing-page briefs, not automatic pages.

## Why

This joins paid conversion evidence to SEO/GEO planning while avoiding separate, inconsistent matchers per channel.

## Tier

Selected tier: `tier:standard`; bounded retrieval/scoring implementation, not a full specified simple transform.

## How

### Files to Modify

- `NEW: .agents/seo/intent-page-matching.md` — shared matcher leaf and companion helper below.

NEW `.agents/seo/intent-page-matching.md`, `.agents/scripts/intent-page-match-helper.py`, `.agents/scripts/intent_page_matching.py` and tests/fixtures. Reference `.agents/seo/query-fanout-research.md`, `.agents/seo/conversational-search-intent.md`, `.agents/content/meta-creator.md`, `.agents/marketing-sales/ad-creative-offers-landing.md` and `.agents/seo/sro-grounding.md`.

### Files Scope

- `.agents/seo/intent-page-matching.md`
- `.agents/scripts/intent-page-match-helper.py`
- `.agents/scripts/intent_page_matching.py`
- `.agents/scripts/tests/test-intent-page-matching.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/intent-pages.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/intent-decisions.json`

### Complete Write Surface

- **Callers/readers:** SEO/ads leaves import `.agents/scripts/intent_page_matching.py`; new leaf invokes its CLI.
- **Writers/mutation paths:** `.agents/scripts/intent-page-match-helper.py` writes private matching matrices/briefs only.
- **Tests/fixtures:** `.agents/scripts/tests/test-intent-page-matching.py` and `fixtures/marketing-decisions/intent-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`, with local fit-rubric versions.
- **Generated/deployed mirrors:** no generated/deployed edits; t18458 owns `.agents/subagent-index.toon` registration.
- **Migrations/backfills:** N/A because new analysis does not alter pages or prior SEO data.
- **Cleanup/rollback paths:** remove `.agents/scripts/intent_page_matching.py` and companions; preserve original fan-out/meta workflows.

### Implementation Steps

1. Add `match --input FILE --decisions FILE --dry-run`. Shortlist candidates using deterministic lexical retrieval first and optional existing approved embeddings; bound candidates and record retrieval coverage. Always allow none, multiple valid pages and insufficient evidence.
2. Assess intent, offer, CTA, pricing/conditions, title/H1, answer passage and evidence freshness. Return source passages, not invented rationale. Count words in code; an early-answer score is an editorial rubric, not predicted citation probability.
3. Rank converting-query gaps by observed conversion value/margin where available, cost, sample/lag and uncertainty. Deduplicate equivalent intents before briefs; flag existing-page improvements before creating near-duplicate pages. No paid-to-organic causal revenue promise.
4. Preserve observed ranking URL versus proposed page separately. A disagreement with a model does not establish a search-engine defect. Expose ad landing-match results to both Google and Meta workflows.

### Hazards and Compatibility

- **Concurrency/atomicity:** shared atomic writer; changed page hashes invalidate scoped cache entries.
- **Migration/rollback:** additive helper only; rollback preserves existing fan-out/meta behavior.
- **Mixed-version/backward compatibility:** require known snapshot/rubric versions, preserving unknown outcomes and currency/time scope.
- **Idempotency/retry:** replay exact matching evidence; never force an absent candidate or duplicate a brief.
- **Partial failure/recovery:** shortlist/coverage failure is abstention, with original evidence retained for broader authorized retrieval.

### Verification Before Dispatch

Run `python3 .agents/scripts/intent-page-match-helper.py match --input .agents/scripts/tests/fixtures/marketing-decisions/intent-pages.json --decisions .agents/scripts/tests/fixtures/marketing-decisions/intent-decisions.json --dry-run`; add/run `python3 .agents/scripts/tests/test-intent-page-matching.py` for exact/partial/none/multiple matches, candidate-recall failure, offer mismatch and duplicate commercial intents; run changed-file lint. No live provider calls.

```bash
python3 .agents/scripts/tests/test-intent-page-matching.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** match CLI proves shared consumer output; tests cover shortlist/offer/unknown/brief-dedupe behavior; lint covers scoped files.
- **Recoverability:** checkpoint verified work and preserve remaining criteria; after a fuse resume the offline batch, not an unauthorized provider route. No broad gate.

## Acceptance Criteria

- [ ] One callable path covers ads, organic queries and buyer questions and emits traceable page matches or abstentions.
- [ ] Converting queries without coverage produce deduplicated prioritized briefs with outcome/sample uncertainty, not automatically published content.
- [ ] Missing candidates, unsupported facts and low answerability cannot be reported as proven ranking/citation failures.
