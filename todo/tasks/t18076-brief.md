---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18076: Consolidate duplicated framework CI lint work without reducing security coverage

## Pre-flight

- [x] Memory recall: `CI lint duplicate security coverage` → 0 hits — no reusable lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced for the target planning files in the prework window
- [x] File refs verified: 4 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — existing local/CI gate patterns constrain a conditional change
- [x] Seeded draft PR decision recorded: skipped — t18072 must first prove duplicated work

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18072
- **Conversation context:** Some framework CI checks may repeat local discovery or analysis, but platform coverage and security defence-in-depth can look similar while serving distinct purposes.

## What

Consolidate only CI work proven duplicate by t18072, while preserving required platform checks, independent security gates, negative fixtures, and terminal failure semantics.

## Why

Measured CI duplication consumes compute and delays feedback, but careless consolidation can remove platform-specific or security coverage.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** No — workflow, helper, and fixture may change.
- [x] **Every target file under 500 lines?** No — workflow and gate modules require selective reads.
- [x] **Exact replacements available?** No — t18072 selects measured duplication.
- [x] **No judgment or design decisions?** No — intentional independence must be distinguished.
- [x] **No fallback logic to design?** Yes — required checks remain fail closed.
- [x] **No cross-module changes?** No — local helper and CI workflow interact.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no self-hosting dispatch file is targeted.

**Selected tier:** `tier:standard`

**Tier rationale:** The change follows existing gate and workflow patterns but spans multiple files and requires coverage comparison.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** This stretch task is conditional on measured duplicate work and remaining time.
- **Status:** `blocked`
- **Freshness evidence:** Current code-quality and local linter entrypoints were verified.
- **Verification run:** Planning-only.
- **Stale-assumption warning:** Workflow changes merged after t18072 require a fresh job graph.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/code-quality.yml` — reuse or remove only a proven duplicate step.
- `EDIT: .agents/scripts/linters-local-gates.sh` — expose reusable output only when it remains trustworthy across CI boundaries.
- `NEW: .agents/scripts/tests/test-linter-ci-coverage.sh` — compare required gate and negative-fixture coverage.
- `EDIT: todo/missions/m-20260710-11431d/research/resource-baseline.md` — record compute and critical-path decision.

### Implementation Steps

1. Map each candidate duplicate to its platform, security, and failure-semantics purpose.
2. Exclude independent security and cross-platform checks from consolidation.
3. Reuse an immutable manifest or remove one repeated step only when revisions and inputs match.
4. Add a fixture that compares required checks and deliberately failing cases before and after.
5. Retain only if CI compute drops at least 15% without increasing critical-path time more than 10%.

### Verification

```bash
bash .agents/scripts/tests/test-linter-ci-coverage.sh
.agents/scripts/linters-local.sh --changed
```

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-linter-ci-coverage.sh`
- [ ] WIP commit created before broad gates: `wip: consolidate measured CI lint duplication`
- [ ] Broad verification then run: `.agents/scripts/linters-local.sh --full`

### Files Scope

- `.github/workflows/code-quality.yml`
- `.agents/scripts/linters-local-gates.sh`
- `.agents/scripts/tests/test-linter-ci-coverage.sh`
- `todo/missions/m-20260710-11431d/research/resource-baseline.md`

## Acceptance Criteria

- [ ] Required platform and security gate coverage is unchanged.
- [ ] Deliberately failing fixtures still fail every authoritative gate.
- [ ] Measured CI compute falls at least 15% without critical-path regression above 10%.
- [ ] The change is skipped or rolled back if elapsed mission time exceeds the Tier 3 gate.

## Context & Decisions

- This is a Tier 3 stretch feature.
- Similar checks are not duplicates when they provide platform or trust-boundary independence.

## Relevant Files

- `.github/workflows/code-quality.yml` — primary framework quality workflow.
- `.agents/scripts/linters-local-gates.sh` — local gate dispatch.
- `.agents/scripts/linters-local.sh:224-243` — summary and failure contract.
- `todo/missions/m-20260710-11431d/research/resource-baseline.md` — measured prerequisite.

## Dependencies

- **Blocked by:** t18072 and Tier 3 time gate
- **Blocks:** none
- **External:** terminal existing CI only

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Confirm duplicate job graph |
| Implementation | 15m | One bounded consolidation |
| Testing | 10m | Coverage and negative fixtures |
| **Total** | **30m** | |
