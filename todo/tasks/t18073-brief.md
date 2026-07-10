---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18073: Bound Target B monorepo lint concurrency while preserving affected coverage

## Pre-flight

- [x] Memory recall: `monorepo turbo lint concurrency memory` → 0 hits — no reusable lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced in the public planning pass
- [x] File refs verified: 4 target patterns checked locally, all present; private paths intentionally omitted
- [x] Tier: `tier:thinking` — private cross-package graph and resource trade-offs require local judgment
- [x] Seeded draft PR decision recorded: skipped — target-local evidence and a target-local brief were created first

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18071
- **Conversation context:** Target B already has affected-mode commands, explicit concurrency defaults, caches, and package-config grouping; these must be measured rather than replaced by assumption.

## What

Create a target-local worktree and private brief, compare affected and full task graphs under bounded concurrency, and retain the safest explicit local profile that preserves file, package, and security coverage.

## Why

Default parallelism can multiply memory-heavy type-aware lint processes, but lowering concurrency without graph evidence may create unnecessary latency.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Unknown until the private target graph is resolved.
- [x] **Every target file under 500 lines?** Unknown; use selective reads only.
- [x] **Exact replacements available?** No — measurements choose the profile.
- [x] **No judgment or design decisions?** No — memory versus wall-time trade-offs are explicit.
- [x] **No fallback logic to design?** No — local and CI profiles must remain distinct.
- [x] **No cross-module changes?** No — root scripts and task graph may both be involved.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no framework self-hosting path is targeted.

**Selected tier:** `tier:thinking`

**Tier rationale:** The public brief deliberately omits private paths, so the worker must resolve and verify the target graph locally before implementation.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A public seed cannot safely contain the target mapping or private graph details.
- **Status:** `completed` — the target-local change merged after terminal checks
- **Freshness evidence:** Existing affected commands, explicit concurrency, cache flags, and changed-file grouping were inspected locally.
- **Verification run:** The terminated affected route was replaced by 37 serial package checkpoints; every shard passed and the full task-graph digest remained unchanged after lowering the local default.
- **Stale-assumption warning:** Regenerate the graph if the target revision or package manager lock changes.

## How (Approach)

### Files to Modify

- `TARGET-LOCAL: root lint script configuration` — make local concurrency explicit and bounded.
- `TARGET-LOCAL: task graph configuration` — remove only measured recursive or duplicate traversal.
- `TARGET-LOCAL: changed-file lint helper or tests` — preserve package-config grouping and coverage.
- `NEW: todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md` — redacted aggregate decision record.

### Implementation Steps

1. Resolve Target B through local mission configuration; never persist its name or path in this repository.
2. Create a target-local brief with exact paths and a worktree before editing.
3. Compare equivalent affected/full task graphs with concurrency 1 and 2; do not exceed 2 locally.
4. Preserve existing cache flags, affected filtering, and changed-file grouping unless a stale-cache or duplicate-traversal fixture proves a defect.
5. Retain only a profile with unchanged package/file digests and acceptable resource trade-offs.

### Verification

```text
Run the target-native affected lint command twice under the bounded wrapper, once cold and once warm.
Run the target-native changed-file dry-run and compare normalized package/file digests.
Run the target-native focused lint tests and terminal CI after any retained change.
```

### Files Scope

- `todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md`

## Acceptance Criteria

- [x] Target-local task and file digests match before and after.
- [x] Local lint concurrency is explicit, starts at 1, and never exceeds 2 during profiling.
- [x] The performance hypothesis is inconclusive; the retained safety guardrail makes no unsupported optimisation claim.
- [x] No private target name, path, source content, or raw log is committed here.

## Context & Decisions

- Target B may accept up to 25% more wall time for a material peak-memory reduction.
- Existing CI concurrency may remain higher only when current CI evidence supports it.
- Cache contention and recursive traversal are hypotheses, not findings.
- The valid cold concurrency-1 affected route peaked at 5,593,600 KiB across 11 processes and exited 137 after 45 seconds.
- That unsafe route was not retried. All 37 package lint shards passed serially through recoverability checkpoints.
- The complete 102-task dry graph had the same digest before and after the retained change.
- Local `lint` and `lint:affected` now default to concurrency 1; overrides and the existing required CI profile remain available.
- The target-local change passed terminal lint, format, typecheck, unit, end-to-end, security, and review checks before merge.

## Relevant Files

- `todo/missions/m-20260710-11431d/mission.md` — measurement and stop contract.
- Target-local root script configuration — exact path resolved only in the private worktree.
- Target-local task graph configuration — exact path resolved only in the private worktree.
- Target-local changed-file helper — exact path resolved only in the private worktree.

## Dependencies

- **Blocked by:** t18071
- **Blocks:** t18075, t18077
- **External:** existing local Target B checkout only; no credentials or new dependencies

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Resolve graph and create private target brief |
| Implementation | 20m | Explicit bounded profiles or measured traversal fix |
| Testing | 20m | Serialized cold/warm and coverage comparison |
| **Total** | **55m** | |
