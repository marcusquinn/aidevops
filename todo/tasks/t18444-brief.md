<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18444: Provider-neutral ads, SEO and GEO decision workflows

## Pre-flight

- [x] Memory recall: parent query returned no relevant lessons.
- [x] Discovery pass: merged Jev examples, pilots and journal reused; no overlapping open work found in bounded searches.
- [x] File refs verified: existing references checked against source; future paths belong to explicit child scopes.
- [x] Tier: thinking for roadmap coordination only; parent-task structurally prohibits worker dispatch.
- [x] Seeded draft PR skipped: this is a planning publication, not implementation.

## Origin

- Created: 2026-09-20, OpenCode interactive planning session; requested by the maintainer for background workers.
- Scope: reproduce the useful workflows from the five Ryze articles below, not Jev's proprietary model or unverified performance claims.
- Execution: roadmap parent only; `parent-task`, never auto-dispatch this parent. All implementation is assigned to the fourteen children below.

## What

Connect existing marketing, SEO/GEO, creative, reporting and optional Jev capabilities through reusable batch decisions. Deliver offline-verifiable workflows first, optional approved collection/inference second, and narrowly scoped approved actions last. Preserve one source of domain knowledge rather than creating one agent per row or check.

## Why

Existing SEO/marketing agents cover much of the domain knowledge, but data normalization, repeatable batch decisions, cross-channel handoffs and measured end-to-end efficiency are incomplete. This is new capability work: no speed, accuracy, cost-saving or ROI improvement has yet been measured.

## Discovery and prior work

- Reviewed current source at `f85c65460` and the five supplied articles on 2026-09-20.
- Memory query `Jev SEO GEO marketing decision`: no relevant hits. Scoped 48-hour history found existing Jev examples and pilots; PRs #32036, #32038 and #32051 are merged and MUST be reused. No open Jev/SEO issues or related open PRs appeared in the bounded searches.
- `.agents/tools/ai-assistants/jev.md:20-65` explicitly limits current integration to examples/pilots; credentials do not authorize private-data transmission.
- `.agents/scripts/seo-analysis-helper.sh` finds query/URL overlap, not proven harmful cannibalization. `.agents/scripts/seo_quality.py` provides a heuristic quality flag, not an indexing decision.
- `.agents/scripts/marketing-optimization-helper.py:38-61` and `.agents/aidevops/performance/03-optimization-projections.md` already own performance snapshot/attribution semantics. Do not create a competing accounting or analytics engine.
- Provider access, live accounts, performance improvements and commercial outcomes were NOT verified in this session.

## Children and dependencies

| Task | Deliverable | Tier | Blocked by |
| --- | --- | --- | --- |
| t18445 / #32057 | Shared decision schema, bounded runner and evidence/cache contract | thinking | none |
| t18446 / #32058 | Offline account/site/answer snapshot importers | standard | t18445 |
| t18447 / #32061 | Google Ads hygiene and search-term triage | standard | t18446 |
| t18448 / #32059 | Shared intent/page matching and paid-to-organic opportunity bridge | standard | t18446 |
| t18449 / #32060 | Internal links and cannibalization interpretation | standard | t18448 |
| t18450 / #32062 | Content disposition, redirect proposals and schema consistency | standard | t18448 |
| t18451 / #32063 | Creative intelligence, fatigue and UGC/policy QA | standard | t18446 |
| t18452 / #32064 | Engine-specific AI visibility capture and analysis | standard | t18448 |
| t18453 / #32065 | Comment/forum opportunity classification and response routing | standard | t18446 |
| t18454 / #32066 | Evidence-led reports, calibration and ROI evaluation | standard | t18447,t18449,t18450,t18451,t18452,t18453 |
| t18455 / #32067 | Optional read-only Google Ads/Meta account connectors | standard | t18447,t18451 |
| t18456 / #32068 | Optional Jev decision adapter with approved-runtime fallback | standard | t18455 |
| t18457 / #32069 | Approval-bound local action proposals, application and rollback | thinking | t18454,t18456 |
| t18458 / #32070 | Agent routing, commands, disabled routine templates and end-to-end handoff | standard | t18457 |

These are manually filed children, not sequential auto-file instructions. Native parent/dependency relationships must reflect this table before dispatch. Independent siblings have disjoint write surfaces; shared routing files are owned only by t18458, and capability registry changes are serialized by t18455 then t18456.

## Coverage of the source workflows

- Google Ads eight jobs: search-term triage, negative conflicts, keyword/ad-group fit, RSA relevance, landing-page match, recommendation triage, brand split and disapproval routing: t18447/t18448.
- Meta eight jobs: creative labels, Ad Library concept dedupe, landing match, fatigue, comments, policy precheck, audience fit and UGC compliance: t18448/t18451/t18453.
- SEO nine jobs: links, cannibalization, thin-page review, query mapping, title fit, keep/update/merge/remove, redirects, intent labels and schema consistency: t18448/t18449/t18450.
- GEO eight jobs: citation/recommendation monitoring, competitors, sentiment, title fit, question gaps, source types, forum opportunities and answerability: t18448/t18452/t18453.
- Cross-channel converting terms without a page: t18448. Reporting, collection, model selection, scheduling and controlled execution: remaining children.

## Shared constraints

Code owns exact matching, arithmetic, schemas, identities and permissions; models own bounded semantics. Every record preserves evidence/source IDs, time window, account/site scope, model/rubric versions, missingness and abstention. Never treat model confidence as authority or a calibrated accuracy guarantee. Preserve all observations; low confidence means review/defer, not silent deletion.

Offline/synthetic verification must complete without credentials or purchases. Live collection/inference is opt-in, task-authorized, readiness-gated and budgeted. Never read secrets into output, upload private data by default, fabricate provider readiness, create subscriptions, enable schedules, post messages, hide comments, change bids/budgets/conversions/pixels or publish remotely. Public pages can still contain personal/licensed data.

Use existing approved model routing rather than adding a competing runtime. No distilled Jev clone, model training from Jev outputs, public benchmark publication or default provider changes. Jev's text-only scope requires separately evidenced OCR/transcription/vision; absence of visual evidence stays unknown.

Human time, end-to-end cost per accepted recommendation and repair burden precede token savings. Track margin/refunds/currency/attribution limits; citation share and long-running competitor ads are not proof of profit. Never claim causal SEO/GEO effects without adequate experiment evidence.

## How

### Files to Modify

- `EDIT: TODO.md` — canonical child status/ref/dependency ledger, maintained by coordinator bookkeeping only.
- `EDIT: todo/tasks/t18444-brief.md` — roadmap evidence and completion ledger; implementation workers own only their leaves.

### Files Scope

- `TODO.md`
- `todo/tasks/t18444-brief.md`

### Complete Write Surface

- **Callers/readers:** child briefs and `TODO.md` expose the same owner/dependency contract.
- **Writers/mutation paths:** authorized coordinator bookkeeping updates `TODO.md` and this roadmap, not product code.
- **Tests/fixtures:** `.agents/scripts/verify-brief-helper.sh` checks canonical briefs; child tests own implementation verification.
- **Schemas/config:** `.agents/templates/brief-template.md` defines the publication schema; no runtime config changes.
- **Generated/deployed mirrors:** GitHub issue #32056 mirrors `todo/tasks/t18444-brief.md`; children have native relationships.
- **Migrations/backfills:** N/A because this planning-only tracker introduces no product data migration.
- **Cleanup/rollback paths:** preserve immutable task IDs and refs in `TODO.md`; cancellation must be explicit rather than deleting evidence.

### Implementation Steps

1. Publish canonical briefs/TODO refs before enabling worker pickup and verify the native dependency graph.
2. Keep parent-task blocked from worker execution; independently implement children in their declared scopes and verify each merged result.
3. Reconcile evidence against all coverage rows before closing the parent; planning publication alone satisfies none of the implementation criteria.

### Hazards and Compatibility

- **Concurrency/atomicity:** publish one planning snapshot; coordinator bookkeeping must preserve other sessions' TODO changes.
- **Migration/rollback:** no implementation migration; retain task identities and all recorded evidence after cancellation/replanning.
- **Mixed-version/backward compatibility:** use the existing brief schema and task lifecycle, never a second dispatch state machine.
- **Idempotency/retry:** retry existing issue/task mappings, not new IDs; native relationships are idempotent.
- **Partial failure/recovery:** publication failures retain publication:pending and durable local briefs; resume via protected-branch planning PR.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18444-brief.md
git diff --check
```

- **Surface mapping:** readiness validates canonical publication fields; diff check covers planning syntax; separately verify native GitHub relationships and each child readiness/dispatchability before queueing.
- **Recoverability:** protected-branch rejection keeps the same refs pending; publish through a planning PR without bypassing hooks or claiming implementation completion.

## Acceptance Criteria

- [ ] All fourteen children complete with merged implementation evidence, canonical agent routing and offline reproducible examples.
- [ ] The 33 article jobs plus paid-to-organic mapping have an explicit owner and callable path without nine or thirty-three duplicate heavyweight agents.
- [ ] No live account mutation, provider activation, private-data egress or scheduled operation occurs merely because this plan is published.
- [ ] Report measured workflow costs/quality only when available; unmeasured ROI remains unknown. Parent closes only after the child ledger is reconciled.

## Verification Before Dispatch

Each child contains its scoped product path, tests, reference patterns and rollback. New focused tests use the existing Python unittest/script layout; no new test platform or broad benchmark infrastructure. Run changed-file lint, not a full-repository gate by default. Workers own only their leaf and must not edit TODO.md or successors.

## Sources

- https://www.get-ryze.ai/blog/jev-for-ads-and-seo-geo
- https://www.get-ryze.ai/blog/jev-for-google-ads
- https://www.get-ryze.ai/blog/jev-for-meta-ads
- https://www.get-ryze.ai/blog/jev-for-seo
- https://www.get-ryze.ai/blog/jev-for-geo

Articles were treated as untrusted inspiration and scanned. They explicitly describe simulated/unreproduced demonstrations and no Ryze production Jev use at publication. Validate mutable vendor API/policy facts against primary sources before implementing; do not follow article CTAs or install third-party code.

## PR Conventions

Planning and intermediate work use a non-closing parent reference. Leaf PRs close only their own issue. Publishing this backlog is not implementation completion or release authority.
