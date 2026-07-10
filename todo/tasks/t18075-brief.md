---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18075: Optimise Target B lint cache and traversal only when contention is measured

## Pre-flight

- [x] Memory recall: `eslint cache contention duplicate traversal` → 0 hits — no reusable lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced in the public planning pass
- [x] File refs verified: 3 target patterns checked locally, all present; private paths intentionally omitted
- [x] Tier: `tier:thinking` — this conditional task must reject an unproven premise
- [x] Seeded draft PR decision recorded: skipped — t18073 evidence was required before choosing any cache design

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18073
- **Conversation context:** Shared cache contention or repeated traversal may exist in Target B, but repository size and shared cache flags alone do not prove it.

## What

Implement one narrowly measured cache-isolation, manifest-reuse, or traversal fix in Target B, or close the task as falsified when evidence does not meet the mission threshold.

## Why

Speculative cache redesign can increase stale results, disk churn, and complexity. This task exists only for a demonstrated hotspot.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Unknown until t18073 selects the hotspot.
- [x] **Every target file under 500 lines?** Unknown; private paths are deferred.
- [x] **Exact replacements available?** No — conditional evidence selects the fix.
- [x] **No judgment or design decisions?** No — reject or retain is evidence-gated.
- [x] **No fallback logic to design?** No — stale-cache failure must remain authoritative.
- [x] **No cross-module changes?** Potentially no, but not known before evidence.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no framework self-hosting path is targeted.

**Selected tier:** `tier:thinking`

**Tier rationale:** The correct outcome may be no code change; interpreting cache and traversal evidence requires judgment.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Seeding a preferred cache design would bias the evidence-gated decision.
- **Status:** `completed-falsified` — no threshold-meeting cache contention or duplicate traversal was measured
- **Freshness evidence:** Current cache and affected-mode patterns were inspected locally.
- **Verification run:** F3 completed all 37 serial shards and preserved the full task-graph digest before and after the retained concurrency guardrail.
- **Stale-assumption warning:** Any task graph or lint tool upgrade invalidates prior cache measurements.

## How (Approach)

### Files to Modify

- `TARGET-LOCAL: selected cache or traversal hotspot` — one narrow evidence-backed change.
- `TARGET-LOCAL: stale-cache or duplicate-traversal fixture` — negative regression protection.
- `EDIT: todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md` — accepted or falsified decision.

### Implementation Steps

1. Require t18073 evidence of contention or repeated traversal above the mission threshold.
2. If absent, record the hypothesis as falsified and make no target code change.
3. If present, create a private target-local brief and implement only the smallest selected fix.
4. Compare cold and warm runs and mutate an input to prove stale cache does not pass.
5. Roll back if coverage changes or non-target metrics regress beyond the contract.

### Verification

```text
Compare normalized cold and warm task/file digests before and after.
Mutate one linted input and prove the cache invalidates.
Run the target-native focused lint tests and terminal CI.
```

### Files Scope

- `todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md`

## Acceptance Criteria

- [x] F3 found no cache contention or duplicate traversal above the mission threshold, so no F5 code change was made.
- [x] Before and after full task-graph digests are identical.
- [x] A stale local generated cache was isolated and invalidated only after its missing generated prerequisite was restored.
- [x] The speculative cache redesign was rejected and this conditional task was marked falsified.

## Context & Decisions

- This is Tier 2 and proceeds only when F3 measures a threshold-meeting hotspot.
- No cache namespace or manifest complexity is added without measurable benefit.
- The safety fuse did not determine this outcome. The conditional premise was re-evaluated after F3 completed and was not supported by evidence.

## Relevant Files

- `todo/missions/m-20260710-11431d/mission.md` — acceptance thresholds.
- `todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md` — prerequisite evidence.
- Target-local cache configuration and fixture — resolved privately after t18073.

## Dependencies

- **Blocked by:** t18073
- **Blocks:** none
- **External:** existing local Target B checkout only

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Confirm threshold evidence |
| Implementation | 15m | One narrow target-local change |
| Testing | 10m | Cold/warm and stale-cache fixture |
| **Total** | **30m** | |
