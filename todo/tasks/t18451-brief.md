<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18451: Creative intelligence, fatigue and UGC policy QA

## Pre-flight

- [x] Memory recall: parent query found no relevant lessons.
- [x] Discovery pass: existing creative taxonomy/QA reviewed; no related open Jev work found.
- [x] File refs verified: creative management, testing and Meta UGC/QA docs are present.
- [x] Tier: standard; snapshot-driven implementation under existing domain rules.
- [x] Seeded draft PR skipped: implementation belongs to the worker.

## Origin

2026-09-20 OpenCode interactive background request. Parent: t18444. blocked-by:t18446.

## What

Add one creative-intelligence leaf and helper for hook/format/offer/awareness labels, competitor concept dedupe, performance grouping, fatigue triage, audience fit, policy precheck and UGC brief evidence coverage. Reuse existing creative knowledge rather than separate agents per rubric.

## Why

Reduce repetitive creative review while retaining sample uncertainty, visual evidence and human ownership of claims/rights.

## Tier

Selected tier: `tier:standard`; established creative rubrics and fixed recommendation-only contract.

## How

### Files to Modify

- `NEW: .agents/marketing-sales/creative-intelligence.md` — batch creative leaf and helper below.

NEW `.agents/marketing-sales/creative-intelligence.md`, `.agents/scripts/creative-intelligence-helper.py`, `.agents/scripts/creative_intelligence.py`; EDIT `.agents/marketing-sales/ad-creative.md` for its leaf pointer. Reference `ad-creative-campaign-management.md`, `ad-creative-testing-optimization.md`, `meta-ads-creative-briefs-ugc-brief.md` and `meta-ads-creative-production-qa.md` in the same domain directory.

### Files Scope

- `.agents/marketing-sales/creative-intelligence.md`
- `.agents/marketing-sales/ad-creative.md`
- `.agents/scripts/creative-intelligence-helper.py`
- `.agents/scripts/creative_intelligence.py`
- `.agents/scripts/tests/test-creative-intelligence.py`
- `.agents/scripts/tests/fixtures/marketing-decisions/creative-manifest.json`
- `.agents/scripts/tests/fixtures/marketing-decisions/creative-decisions.json`

### Complete Write Surface

- **Callers/readers:** `.agents/marketing-sales/ad-creative.md` routes to creative-intelligence; reports consume artifacts.
- **Writers/mutation paths:** `.agents/scripts/creative_intelligence.py` writes private labels/grouped observations/proposals only.
- **Tests/fixtures:** `.agents/scripts/tests/test-creative-intelligence.py` and `fixtures/marketing-decisions/creative-*`.
- **Schemas/config:** consume `.agents/configs/marketing-decision.schema.json`; local creative rubric versions.
- **Generated/deployed mirrors:** final integration owns `.agents/subagent-index.toon`; no deployed edits.
- **Migrations/backfills:** N/A because analysis never rewrites ad assets or insights.
- **Cleanup/rollback paths:** revert `.agents/scripts/creative_intelligence.py` and leaf/pointer; evidence retention remains operator-owned.

### Implementation Steps

1. Implement `analyze --input FILE --decisions FILE --dry-run`; extract multiple independent labels per shared creative evidence and dedupe concept versus superficial variation using stable evidence IDs.
2. Group owned-ad outcomes by tags with exposure, date windows, audience/placement, spend, conversions, margin/refunds where available. Keep competitor Ad Library metadata separate: longevity is not observed profitability.
3. Fatigue uses configured evidence windows/sample/lag and alternative explanations, not a universal three-day/50-conversion rule. Emit leave/refresh/review hypotheses without switching ads off.
4. Audience/creative fit, policy risk and UGC compliance return requirement-specific evidence. Transcript-only checks cannot pass visual product/disclosure/rights requirements. Unknown media evidence remains unknown; policy precheck does not certify provider approval.
5. Reference t18448's shared landing matcher when available; until then emit a typed handoff, not a second matcher. Do not block this independent implementation on that later optional integration.

### Hazards and Compatibility

- **Concurrency/atomicity:** bind asset/window/audience identities and use shared atomic artifacts.
- **Migration/rollback:** no account migration; revert opt-in source/pointer, keeping existing creative guidance.
- **Mixed-version/backward compatibility:** validate manifests/rubrics; missing multimodal fields remain unknown.
- **Idempotency/retry:** replay unchanged scoped evidence without duplicate refresh briefs; invalidate changed assets/windows.
- **Partial failure/recovery:** preserve incomplete media/rights evidence and confounders; never replace with unsupported claims or outbound messages.

### Verification Before Dispatch

Run new `analyze` with synthetic `creative-manifest.json` and decisions; add/run `python3 .agents/scripts/tests/test-creative-intelligence.py` for labels, variations, sparse/confounded fatigue, multi-asset joins and missing visual/rights evidence. Run `.agents/scripts/linters-local.sh --changed`. No network, purchased assets or media tools required.

```bash
python3 .agents/scripts/tests/test-creative-intelligence.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** analyze CLI proves creative/QA outputs; tests exercise sparse/confounded/unknown cases; lint checks helper and agent guidance.
- **Recoverability:** checkpoint verified work; after a fuse preserve remaining criteria and resume offline instead of activating media/account services. No broad gate.

## Acceptance Criteria

- [ ] Creative tagging, concept dedupe, grouped outcomes, fatigue and audience fit produce evidence-linked recommendations on offline snapshots.
- [ ] Policy/UGC checks retain unknown requirements and cannot certify unseen visuals, rights or provider acceptance.
- [ ] Competitor longevity is never reported as ROAS/profit and no ads are launched/paused, budgets changed or creators contacted.
