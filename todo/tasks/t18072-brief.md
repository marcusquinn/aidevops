---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18072: Fix changed-file coverage, deduplicate discovery, and fail closed on timeouts

## Pre-flight

- [x] Memory recall: `linter discovery timeout cache ratchet` → 0 hits — no relevant lesson found
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs surfaced for the target files in the prework window
- [x] File refs verified: 6 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — bounded multi-file shell optimisation with existing patterns
- [x] Seeded draft PR decision recorded: skipped — t18071 evidence must identify the actual duplicate work first

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode:ses_0b6078816ffebb5VUpgvjShRvx
- **Created by:** AI DevOps (ai-interactive)
- **Parent mission:** m-20260710-11431d
- **Blocked by:** t18071
- **Conversation context:** Framework linting already supports changed/full modes and caching. Mission validation also confirmed that unstaged changed mode scanned 1 tracked file while a temporary-index representation scanned all 9 intended files, so untracked non-ignored files currently miss safety checks.

## What

Include untracked non-ignored files in changed-mode safety coverage, reuse a single deduplicated lint inventory or run fingerprint where t18071 proves repeated traversal, and ensure timed-out broad gates cannot be reported as complete or successful.

## Why

Omitting new files from secret and quality checks is a confirmed reliability and security gap. Repeated repository scans waste CPU and memory, while false-success timeout semantics undermine trust in results.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** No — discovery, gates, and tests may change.
- [x] **Every target file under 500 lines?** No — gate modules require selective reading.
- [x] **Exact replacements available?** No — t18071 selects measured hotspots.
- [x] **No judgment or design decisions?** No — intentional cross-platform duplication must be retained.
- [x] **No fallback logic to design?** No — timeout policy has blocking and advisory paths.
- [x] **No cross-module changes?** No — shared discovery feeds multiple gates.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification checked?** Yes — no self-hosting dispatch file is targeted.

**Selected tier:** `tier:standard`

**Tier rationale:** Existing discovery and timeout patterns constrain the design, but several shell modules and negative fixtures are involved.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The untracked-file fix is confirmed, but the performance optimisation remains conditional on the F1 baseline.
- **Status:** `blocked`
- **Freshness evidence:** Current orchestrator, discovery helper, gates, and cache fixtures were verified at HEAD.
- **Verification run:** Planning-only.
- **Stale-assumption warning:** If F1 finds no material repeated traversal, omit the deduplication portion but still fix the confirmed untracked-file coverage gap.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/lint-file-discovery.sh` — expose one normalized inventory when supported by evidence.
- `EDIT: .agents/scripts/linters-local-gates.sh` — consume shared inventory and preserve fail-closed timeout outcomes.
- `EDIT: .agents/scripts/linters-local.sh` — compute run state once without expanding orchestration complexity.
- `EDIT: .agents/scripts/tests/test-linters-local-cache.sh` — cover fingerprint reuse and invalidation.
- `NEW: .agents/scripts/tests/test-linters-local-untracked-mode.sh` — prove unstaged non-ignored files receive changed-mode safety checks.
- `EDIT: .agents/scripts/tests/test-linters-local-ratchet-timeout.sh` — prove timeout cannot pass.
- `EDIT: .agents/scripts/tests/test-linters-local-changed-mode.sh` — preserve tracked, staged, and full-mode coverage while adding untracked fixtures.

### Implementation Steps

1. Characterize the confirmed tracked/staged/untracked discovery difference and add untracked non-ignored files without including ignored or generated content.
2. Use the F1 process and traversal evidence to select only proven duplicate scans.
3. Add a normalized inventory interface following this shape:

```bash
build_lint_inventory() {
	local scope="$1"
	# Resolve tracked/changed files once, normalize, deduplicate, and expose arrays.
	return 0
}
```

4. Reuse the inventory without sharing mutable cache output between concurrent processes.
5. Preserve authoritative full/strict failure; changed mode may delegate only with an explicit incomplete-coverage result.
6. Reject the patch if coverage digest shrinks or performance misses the mission threshold.

### Verification

```bash
bash .agents/scripts/tests/test-linters-local-cache.sh
bash .agents/scripts/tests/test-linters-local-untracked-mode.sh
bash .agents/scripts/tests/test-linters-local-ratchet-timeout.sh
bash .agents/scripts/tests/test-linters-local-changed-mode.sh
shellcheck .agents/scripts/lint-file-discovery.sh .agents/scripts/linters-local-gates.sh .agents/scripts/linters-local.sh
```

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-linters-local-cache.sh`
- [ ] WIP commit created before broad gates: `wip: deduplicate bounded lint discovery`
- [ ] Broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/lint-file-discovery.sh`
- `.agents/scripts/linters-local-gates.sh`
- `.agents/scripts/linters-local.sh`
- `.agents/scripts/tests/test-linters-local-cache.sh`
- `.agents/scripts/tests/test-linters-local-untracked-mode.sh`
- `.agents/scripts/tests/test-linters-local-ratchet-timeout.sh`
- `.agents/scripts/tests/test-linters-local-changed-mode.sh`

## Acceptance Criteria

- [ ] Changed mode covers tracked edits, staged files, and untracked non-ignored files while excluding ignored/generated content; full coverage remains unchanged.
- [ ] Duplicate inventory entries are zero and measured repeated traversal is reduced.
- [ ] Timeout fixtures fail closed and cannot print an all-passed summary.
- [ ] The retained change meets a mission performance threshold or is rolled back.

## Context & Decisions

- Cross-platform checks are not duplicates merely because they inspect similar files.
- Security gates remain independent when independence is defence-in-depth.
- No baseline ratchet may be loosened for performance.

## Relevant Files

- `.agents/scripts/linters-local.sh:112-173` — current shell and changed-file collection.
- `.agents/scripts/lint-file-discovery.sh` — shared inventory source.
- `.agents/scripts/linters-local-gates.sh` — gate scheduling and timeout semantics.
- `.agents/scripts/tests/test-linters-local-cache.sh` — cache behaviour.
- `.agents/scripts/tests/test-linters-local-changed-mode.sh` — existing changed-file fixture pattern.
- `.agents/scripts/tests/test-linters-local-ratchet-timeout.sh` — timeout pattern.

## Dependencies

- **Blocked by:** t18071
- **Blocks:** t18076, t18077
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Match F1 evidence to exact scans |
| Implementation | 20m | Inventory reuse and timeout semantics |
| Testing | 15m | Cache, changed mode, timeout, ShellCheck |
| **Total** | **45m** | |
