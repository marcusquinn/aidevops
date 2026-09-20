<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18447: Google Ads hygiene and search-term triage

## Pre-flight

- [x] Memory recall: parent query found no relevant lessons.
- [x] Discovery pass: current source and merged Jev work reviewed; no open overlapping issue/PR found in bounded searches.
- [x] File refs verified: ad-creative Google guidance and keyword historical-metrics client present; implementation paths below are new.
- [x] Tier: standard; eight bounded rubrics on the predecessor snapshot contract.
- [x] Seeded draft PR skipped: no implementation performed.

## Origin

2026-09-20 OpenCode interactive background brief. Parent: t18444. blocked-by:t18446.

## What

Create a read-only Google Ads triage agent and CLI producing ranked, evidence-backed recommendations for all eight article jobs, with explicit handoff to intent/page matching where applicable.

## Why

Turn exported account evidence into reviewable hygiene decisions and reusable buyer-query evidence without risking conversion loss through automatic negatives.

## Tier

Selected tier: `tier:standard`; platform semantics and local recovery need implementation judgment, but account mutation is excluded.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/google-ads-triage.md` — domain leaf with the new helper below.

NEW `.agents/marketing-sales/google-ads-triage.md`, `.agents/scripts/google-ads-triage-helper.py`, `.agents/scripts/google_ads_triage.py`, focused tests/fixtures. Reference `.agents/marketing-sales/ad-creative-platform-google.md`, `.agents/marketing-sales/ad-creative-offers-landing.md` and `.agents/scripts/domain_opportunity_google_ads.py`; no root routing edits here.

### Files Scope

- `.agents/marketing-sales/google-ads-triage.md`
- `.agents/scripts/google-ads-triage-helper.py`
- `.agents/scripts/google_ads_triage.py`
- `.agents/scripts/tests/test-google-ads-triage.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/google-account.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/google-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/marketing-sales/google-ads-triage.md` invokes the new Google CLI; reports consume shared records.
- **Writers/mutation paths:** `.agents/scripts/google_ads_triage.py` emits private proposals, never account mutations.
- **Tests/fixtures:** `.agents/scripts/tests/test-google-ads-triage.py` and `fixtures/marketing-decisions/google-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json` plus local versioned rubrics; no core schema edits.
- **Generated/deployed mirrors:** source-only agent/helper; final integration owns registration, `setup.sh` deploys normally.
- **Migrations/backfills:** N/A because only snapshots are analyzed; no account/store migration.
- **Cleanup/rollback paths:** remove `.agents/scripts/google_ads_triage.py` and companions; retain existing historical-metrics tooling and snapshots.

### Implementation Steps

1. Implement `analyze --input FILE --decisions FILE --dry-run` using the common runner. Cover search intent, negative conflicts, keyword/ad-group fit, RSA/page relevance, landing mismatch handoff, recommendation routing, brand/non-brand/ambiguous labels and policy/destination/editorial disapproval routing.
2. Actual negative blocking follows currently documented platform match semantics in code; semantic similarity alone is not blocking. Preserve account/campaign/ad-group scope, match type and affected query preview. Verify primary-source API/policy/version facts before implementing, not from article assertions.
3. Protect observed converting/profitable terms; make evidence window, conversion lag, minimum spend/sample and account exclusions explicit. Unknown/missing outcome data means review, not junk. Support business-supplied definitions and brand aliases; never infer universal buyer rules.
4. Emit stable candidate/evidence IDs and source metrics. Budget/bid recommendations, negative changes, restructuring, conversion actions and appeals are proposals only. Cross-channel buyer rows remain usable by t18448.

### Hazards and Compatibility

- **Concurrency/atomicity:** use the shared private artifact writer and account-scoped keys.
- **Migration/rollback:** no account migration; revert new opt-in files only.
- **Mixed-version/backward compatibility:** validate predecessor schema/rubric versions and leave legacy tooling unchanged.
- **Idempotency/retry:** evidence-bound proposals replay without duplicate account operations; no operations exist here.
- **Partial failure/recovery:** missing sections are partial coverage; preserve unresolved rows, never dismiss recommendations or claim Quality Score uplift.

### Verification Before Dispatch

Run the real `analyze` CLI on new `google-account.json`/`google-decisions.json` synthetic fixtures; add/run `python3 .agents/scripts/tests/test-google-ads-triage.py` for all eight rubrics, exact/phrase/broad negative semantics, converting terms, typos, missing data and malformed choices. Run `.agents/scripts/linters-local.sh --changed`. No live account or credentials required.

```bash
python3 .agents/scripts/tests/test-google-ads-triage.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** analyze CLI verifies all eight outputs; tests prove match rules and conversion protection; lint checks scoped source/docs.
- **Recoverability:** checkpoint after focused verification; preserve incomplete criteria and resume offline if a fuse trips. No broad gate or release.

## Acceptance Criteria

- [ ] Each of the eight jobs yields a proposal, no-action or review outcome with evidence and coverage; no unsupported section is silently marked passed.
- [ ] Converting/ambiguous terms and semantic-only negative similarities cannot become automatic exclusions.
- [ ] No account mutation, appeal submission, recommendation dismissal, budget/bid or conversion setting change is possible through the CLI.
