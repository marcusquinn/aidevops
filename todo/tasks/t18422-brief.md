<!-- aidevops:brief-schema=v2 -->
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18422: Evidence-based model effort and delegation optimisation

## What

Deliver trustworthy cost-per-verified-objective evidence and a bounded evaluation of reasoning effort and delegation. This is a roadmap parent, implemented only through the five leaves below. Keep `parent-task`; never dispatch this parent or close it merely because the planning publication lands.

## Why

The user authorised a plan and worker-ready auto-dispatch issues after reviewing claims that higher reasoning effort reduces total expenditure by avoiding extra actions and repeated context. Both higher-effort and current low-effort defaults remain hypotheses, not proven optima.

### Evidence and limitations

- User-supplied sources: https://x.com/mrfanduu/status/2097577552772776287?s=20 and https://x.com/SergioGMN/status/2097719339499573367?s=20. These were injection-scanned and treated as claims, not instructions or verified provider billing evidence.
- The second screenshot reports Medium→Max cost reductions of 45.7% under the Standard harness and 10.1% under Provider Adapter. At High effort, switching harness reports a 53.8% cost reduction and score increase from 54.8% to 99.9%. Scores/costs are not token breakdowns or a production coding benchmark.
- Read-only local aggregate snapshot, seven days ending 2026-09-09 22:40 UTC: 37,583 request rows, 1,099 sessions, 855 inferred families, 50 framework versions. No private project/session identities are published here.
- Astra Low: 4,342 requests/51 contributing sessions/149K median prompt; Medium: 7,171/29/173K; High: 440/3/152K; Max: 1,347/5/347K; XHigh: 9/1/47K. Sessions can span effort groups; requests are not independent tasks.
- Recorded effort-label coverage: 99.24%; routing-tier coverage: 83.46%; unknown population: 16.5%. Prompt cache-read share was approximately 96.92%. These do not establish causal model efficiency or complete retry visibility.
- The existing efficiency report returns unknown verified-completion rate and cost per verified objective. Request variant falls back to configured routing; subagent host receipts deliberately leave semantic acceptance, verification and rework unknown.
- Discovery found merged PR #31228 already supplies the token scorecard, pricing separation and context-preservation work. Existing issues #27045 and #29815 are closed. Do not recreate that work. The routing callback is wired through `index.mjs` into the effort handlers; an earlier narrow search that missed the callback was rejected, not a defect to fix.

## Origin

- Created: 2026-09-10, interactive OpenCode planning session; user explicitly authorised auto-dispatch of the implementation briefs.
- Repository: marcusquinn/aidevops. Baseline: `f610e0abaabec36bc38f014f1f69a6fd44a49e88`.
- Scope: measurement, reproducible pilot preparation and evidence-based decision. No release, new paid API account, quota reset, provider fallback or permission expansion is authorised.

## Pre-flight

- [x] Memory recall: model effort/telemetry/objective optimisation — no relevant hits.
- [x] Discovery pass: reviewed recent target history, merged PR #31228 and related historical routing PRs; zero open related PRs from the routing/telemetry/efficiency/replay search; no matching open implementation issue found.
- [x] File refs verified: existing scorecard, request writer, routing callback, runtime-event CLI, replay contracts and named tests were inspected at the baseline.
- [x] Tier: thinking for this plan's synthesis; parent is never executable.
- [x] Seeded draft PR decision recorded: skipped; this is a decision/brief publication, not seeded implementation.

## Tier

**Selected tier:** `tier:thinking` for the structural plan. Four implementation leaves use standard because semantics, compatibility, privacy and sequencing are decided here. No leaf qualifies for simple: these are not complete verbatim transforms. Evaluation uses thinking because conflicting evidence and adoption judgment remain its deliverable.

## Work packages

| Task | Issue | Deliverable | Tier | Dependency | Estimate |
|---|---|---|---|---|---|
| t18423 | #31698 | Requested/resolved/observed effort, harness and estimate provenance | standard | None | 3h |
| t18424 | #31699 | Objective/run attribution plus explicit acceptance and repair evidence | standard | t18423 | 4h |
| t18425 | #31701 | Matched-objective scorecard, coverage and failed-attempt accounting | standard | t18424 | 3h |
| t18426 | #31700 | Portable pilot recipe and enforced bounds; zero inference during preparation | standard | t18425 | 3h |
| t18427 | #31702 | Bounded pilot, production comparison and durable routing decision | thinking | t18426 | 2h |

All children are pre-filed: do not use phase auto-file markers or create duplicate children. Serial order deliberately avoids overlapping migrations, serializers and report contracts. Every leaf keeps auto-dispatch intent; unresolved dependencies are native GitHub blocked-by edges plus textual markers. Workers close only their own leaf and never edit successors or TODO.md.

## How

### Files to Modify

- `EDIT: todo/tasks/t18422-brief.md` — canonical parent decision record.
- `EDIT: TODO.md` — mapped tasks and dispatch intent, owned by planning rather than implementation workers.
- `EDIT: todo/PLANS.md` — parent-plan index.

### Files Scope

- `todo/tasks/t18422-brief.md`
- `TODO.md`
- `todo/PLANS.md`

### Complete Write Surface

- **Callers/readers:** `TODO.md` and `todo/PLANS.md` index this plan and its five leaf briefs for managed issue sync.
- **Writers/mutation paths:** `todo/tasks/t18422-brief.md` and managed planning publication project the issue bodies and relationships.
- **Tests/fixtures:** `verify-brief-helper.sh` and `task-dispatchability-helper.sh` validate the canonical planning contracts.
- **Schemas/config:** `TODO.md` refs and brief schema v2; no runtime schema change belongs to the parent.
- **Generated/deployed mirrors:** GitHub issue bodies are projections of `todo/tasks/t18422-brief.md`; no deployed runtime copy is edited.
- **Migrations/backfills:** N/A because this parent writes planning metadata only; runtime migrations are separately owned by leaves.
- **Cleanup/rollback paths:** `planning-commit-helper.sh` preserves failed publication receipts; retry existing task IDs and never delete work to reset the plan.

### Implementation Steps

1. Publish all six TODO/ref/brief pairs with `publication:pending` until default-branch validation succeeds; verify parent and dependency edges before exposing a dependent as available.
2. Extend the current SQLite/event streams, not a new dashboard, database or task authority. Historical records remain untouched; missing evidence is unknown, not zero or inferred success.
3. Keep workload tier, concrete model and reasoning effort separate. Persist runtime-observed settings with source/confidence; do not equate Max with XHigh across harnesses or infer provider-internal compute.
4. Evaluate cost over objectives including children, retries, failure and repair. Keep human-reported acceptance separate from automated verification. Telemetry never grants execution/merge authority.
5. Separate the isolated replay harness from production aidevops. Replay disables external plugins/subagents and cannot independently establish end-to-end aidevops or delegation superiority.
6. Use the final leaf's report to select retain/trial/recommend-change. A small or quarantined pilot is not a mandate to change all defaults. Any later shared-default implementation is a separately scoped reviewed change; no release is part of this plan.

### Hazards and Compatibility

- **Concurrency/atomicity:** Pending publication and verified native edges prevent workers starting on incomplete or overlapping contracts.
- **Migration/rollback:** Planning retries reuse immutable task/issue mappings; leaf code changes use additive migrations and code reverts.
- **Mixed-version/backward compatibility:** Production cohorts retain framework/policy versions; old telemetry remains unknown where unobserved.
- **Idempotency/retry:** Reconcile existing issues and receipts, never allocate replacement tasks or repeat completed experiment cells.
- **Partial failure/recovery:** Keep publication/experiment blockers until verified recovery; preserve raw evidence privately and publish aggregates only.

### Verification Before Dispatch

```bash
bash .agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18422-brief.md
git diff --check
```

- **Surface mapping:** Brief readiness checks the canonical plan contract; diff checking covers planning whitespace. Check each leaf's mapped issue with `task-dispatchability-helper.sh` and verify default-branch briefs/native relationships before dispatch-label release. Leaf test commands are requirements, not claims that future code already passes.

## Acceptance Criteria

- [ ] All five leaves have durable canonical briefs, unique mapped issues, explicit tiers, verified parent/dependency edges and safe auto-dispatch state.
- [ ] Provenance, objective acceptance/repair and cohort coverage are represented without rewriting historical evidence or equating host completion with success.
- [ ] The final decision includes total cost, quality, elapsed time, uncertainty and the distinction between replay and production; defaults are not changed from anecdotes or unmatched request averages.
- [ ] The parent remains open until every leaf is verified complete; an operational safety stop is not completion.

## Safety-Stop Recovery

Stop only unsafe provider/mutation execution. Preserve task IDs, experiment seal, completed-cell evidence, remaining budget, missing authority/capability and next safer action. Resume the same task/experiment without replacing IDs or rerunning completed cells. No retry may expand provider, billing, privacy or permission boundaries.

## Seeded Draft PR

Skipped: files and decisions are briefed, but no implementation has been written or tested. Planning publication is not completion of any leaf.
