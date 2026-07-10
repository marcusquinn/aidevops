---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18074: Validate Target C overlays through bounded downstream lint integration

## Pre-flight

- [x] Memory recall: `overlay integration lint validation resource` → 0 hits — no reusable lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced in the public planning pass
- [x] File refs verified: 3 target patterns checked locally, all present; private paths intentionally omitted
- [x] Tier: `tier:thinking` — target-local integration boundary must be chosen from evidence
- [x] Seeded draft PR decision recorded: skipped — a private target-local brief is required

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18071
- **Conversation context:** Target C is an overlay repository; adding an independent broad lint pipeline may duplicate canonical downstream validation.

## What

Prove that a clean overlay application reaches bounded downstream changed-file checks and that an invalid overlay fails, without introducing a second broad lint pipeline.

## Why

The overlay needs reliable quality feedback, but duplicated full linting would add compute cost without necessarily increasing coverage.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** Unknown until the private integration path is resolved.
- [x] **Every target file under 500 lines?** Unknown; inspect only the entrypoint and focused tests.
- [x] **Exact replacements available?** No — positive and negative fixtures determine the boundary.
- [x] **No judgment or design decisions?** No — integration versus duplication is a design decision.
- [x] **No fallback logic to design?** Yes — fail closed without fallback.
- [x] **No cross-module changes?** No — overlay and downstream validation interact.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no framework self-hosting path is targeted.

**Selected tier:** `tier:thinking`

**Tier rationale:** Private integration context and cross-repository validation require target-local judgment.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Exact target paths and fixtures must remain in the private target repository.
- **Status:** `blocked`
- **Freshness evidence:** Overlay entrypoint and current scripts were inspected locally.
- **Verification run:** Static inspection only.
- **Stale-assumption warning:** Re-evaluate if the canonical downstream lint entrypoint changes.

## How (Approach)

### Files to Modify

- `TARGET-LOCAL: overlay validation entrypoint` — invoke bounded canonical changed-file checks after a disposable apply.
- `TARGET-LOCAL: overlay validation fixtures` — positive and deliberately invalid cases.
- `NEW: todo/missions/m-20260710-11431d/research/target-c-integration-evidence.md` — redacted aggregate result.

### Implementation Steps

1. Resolve Target C locally and create its private brief and worktree.
2. Apply the overlay in a disposable target context under a 3-minute bound.
3. Route changed files to the canonical downstream lint command rather than adding a new broad linter.
4. Add a negative fixture proving malformed overlay output fails.
5. Record aggregate duration, coverage boundary, and rollback decision without private details.

### Verification

```text
Run the target-native positive overlay dry-run and bounded changed-file validation.
Run the deliberately invalid fixture and require a non-zero result.
Confirm no independent broad lint pipeline was introduced.
```

### Files Scope

- `todo/missions/m-20260710-11431d/research/target-c-integration-evidence.md`

## Acceptance Criteria

- [ ] Valid overlay output passes canonical bounded downstream checks.
- [ ] Deliberately invalid overlay output fails within 3 minutes.
- [ ] No duplicate broad lint pipeline is added without contrary coverage evidence.
- [ ] No private target identifiers or raw logs are committed here.

## Context & Decisions

- Reliability coverage, rather than reduced runtime from a zero-lint baseline, is the expected benefit.
- The target-native integration PR owns exact private paths and fixtures.

## Relevant Files

- `todo/missions/m-20260710-11431d/mission.md` — safety and privacy contract.
- Target-local overlay entrypoint — resolved privately.
- Target-local validation fixtures — resolved privately.

## Dependencies

- **Blocked by:** t18071
- **Blocks:** t18077
- **External:** existing local Target C and canonical downstream checkout only

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Resolve integration boundary |
| Implementation | 10m | Bounded downstream validation |
| Testing | 10m | Positive and negative fixtures |
| **Total** | **30m** | |
