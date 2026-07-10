---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18077: Publish linter resource evidence, rollback guidance, and staged rollout results

## Pre-flight

- [x] Memory recall: `linter optimisation rollout rollback evidence` → 0 hits — no reusable lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced for the target planning files in the prework window
- [x] File refs verified: 4 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — cross-target evidence synthesis with a fixed mission template
- [x] Seeded draft PR decision recorded: skipped — the report was created only after implementation evidence existed

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18072, t18073, t18074
- **Conversation context:** The mission must finish with reviewable aggregate evidence, safe defaults, explicit rejected hypotheses, independent rollback, and staged terminal verification.

## What

Publish a redacted final report, update mission state and decisions, document reusable resource-safe lint guidance, and verify retained target changes sequentially.

## Why

Performance changes without measurement context and rollback guidance are difficult to trust, maintain, or reproduce safely.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** No — report, mission state, and reusable guidance may change.
- [x] **Every target file under 500 lines?** Yes — use bounded mission and reference sections.
- [x] **Exact replacements available?** No — final evidence is produced by prior features.
- [x] **No judgment or design decisions?** No — accepted, rejected, and inconclusive outcomes must be synthesized.
- [x] **No fallback logic to design?** Yes — rollback order is fixed.
- [x] **No cross-module changes?** No — mission and reference documentation interact.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no self-hosting dispatch file is targeted.

**Selected tier:** `tier:standard`

**Tier rationale:** The format is constrained, but evidence from multiple target worktrees and CI outcomes must be reconciled carefully.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A final report seed before measurements would create placeholder conclusions.
- **Status:** `completed` — all prerequisite target changes reached terminal CI and merged sequentially
- **Freshness evidence:** Mission state, brief set, and documentation locations were verified.
- **Verification run:** Per-file privacy scans passed, and the bounded changed-mode suite passed in 31 seconds at 104,144 KiB aggregate peak RSS with 11 processes, normal thermal state, and zero starting swap.
- **Stale-assumption warning:** Do not publish until terminal checks and rollback status are current.

## How (Approach)

### Files to Modify

- `NEW: todo/missions/m-20260710-11431d/research/final-report.md` — redacted before/after evidence and decisions.
- `EDIT: todo/missions/m-20260710-11431d/mission.md` — status, budget, decisions, progress, and retrospective.
- `NEW: .agents/reference/linter-resource-safety.md` — reusable bounded profiling and stop policy if evidence supports promotion.

### Implementation Steps

1. Normalize each target's aggregate metrics, cache state, coverage digest, confidence, and rollback result.
2. Record accepted, rejected, and inconclusive hypotheses; never convert correlation into causation.
3. Document changed/affected versus authoritative full-check boundaries and safe local defaults.
4. Verify retained changes sequentially: framework, Target B, then Target C; wait for terminal CI before advancing.
5. Update mission budget and retrospective with measured actuals.

### Verification

```bash
.agents/scripts/markdown-lint-fix.sh todo/missions/m-20260710-11431d/mission.md todo/missions/m-20260710-11431d/research/final-report.md .agents/reference/linter-resource-safety.md
.agents/scripts/linters-local.sh --changed
```

### Files Scope

- `todo/missions/m-20260710-11431d/mission.md`
- `todo/missions/m-20260710-11431d/research/final-report.md`
- `.agents/reference/linter-resource-safety.md`

## Acceptance Criteria

- [x] Every target has before/after metrics or an explicit unmeasurable baseline, coverage evidence, confidence, decision rationale, and rollback status.
- [x] No private target name, path, source content, raw session record, or raw system log appears in committed artefacts.
- [x] Retained changes have focused local verification and terminal CI evidence.
- [x] Mission status, budget actuals, progress log, decisions, and retrospective are current.

## Context & Decisions

- Roll out and verify one target at a time.
- Revert only the latest target on failure; retain independently verified earlier improvements.
- Pending CI is not failure and does not trigger repair or rollback.

## Relevant Files

- `todo/missions/m-20260710-11431d/mission.md` — source of truth.
- `todo/missions/m-20260710-11431d/research/resource-baseline.md` — F1/F2 aggregate evidence.
- `todo/missions/m-20260710-11431d/research/target-b-resource-evidence.md` — Target B aggregate evidence.
- `todo/missions/m-20260710-11431d/research/target-c-integration-evidence.md` — Target C aggregate evidence.

## Dependencies

- **Blocked by:** t18072, t18073, t18074
- **Blocks:** mission completion
- **External:** terminal existing CI for each retained target change

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Normalize feature outputs |
| Implementation | 10m | Report, mission state, reusable guidance |
| Testing | 5m | Markdown, privacy, and changed lint checks |
| **Total** | **20m** | |
