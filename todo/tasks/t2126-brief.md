---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2126: parent — qlty maintainability A-grade file-complexity campaign

## Origin

- **Created:** 2026-04-16
- **Session:** Claude:interactive
- **Created by:** ai-interactive (maintainer directed)
- **Parent task:** (none — this IS the parent)
- **Conversation context:** User asked for next targets to reach and maintain qlty maintainability A. Current state: 20 smells, threshold 22, all 20 are `qlty:file-complexity`, zero headroom. This parent tracks the decomposition campaign that clears those 20 and builds buffer under `QLTY_SMELL_THRESHOLD`.

## What

Planning-only tracker for the file-complexity decomposition campaign. No code is committed against this issue directly — every code change lands under one of the 5 child cluster tasks. This issue is marked `parent-task` so the pulse never dispatches a worker against it.

When all 5 children merge, the aidevops repo should show:

- `qlty:file-complexity` smell count on target files: **0 of 20**
- Overall `qlty smells --all` count: **≤ 10** (20 starting minus 14+ clearable files; conservative — some residual may remain)
- `QLTY_SMELL_THRESHOLD` in `complexity-thresholds.conf`: ratcheted down from 22 to `new_count + 2` (auto-ratchet via t2067)
- Headroom for at least one new medium-complexity file landing without flipping the grade

## Why

**Zero headroom is fragile.** We are at exactly 20 smells and grade-A cutoff is ≤ 20. One new file at complexity >60 (roughly a 600-line module) flips us to B. The last 20 smells are disproportionately concentrated in 4 file families (higgsfield, oauth-pool plugin, email pipeline, doc indexing), each of which can be decomposed using patterns already proven in PR #18893 (claude-proxy), PR #18906 (opencode plugin cluster), PR #18948 (higgsfield cluster partial), and PR #19013 (the 39→20 sweep).

Shipping these 5 cluster tasks:

1. Drops total smell count from 20 to ~5 (estimated, assuming each cluster clears its listed files)
2. Gives `QLTY_SMELL_THRESHOLD` room to ratchet down, which hardens the regression gate
3. Leaves only the smallest/hardest files for a future phase-3 cleanup (none of which are near the grade threshold individually)

## Tier

**Selected tier:** `tier:thinking` (parent-task — never dispatched, tier is documentary only)

**Tier rationale:** Parent tasks are not dispatched by the pulse (`parent-task` label short-circuits the dispatch-dedup guard per t1986). The tier is set to `tier:thinking` only to reflect the complexity of the overall campaign for maintainers browsing the issue list.

## PR Conventions

**This is a `parent-task` — child PRs MUST use `For #19222` or `Ref #19222`, NEVER `Closes`/`Resolves`/`Fixes`.** The final cluster PR (whichever lands last) uses `Closes #19222` to close the parent. Enforced by `.github/workflows/parent-task-keyword-check.yml` and `full-loop-helper.sh commit-and-pr`.

## How (Approach)

### Files to Modify

- `NONE` — this is a planning-only tracker. All file changes happen under the child cluster tasks.

### Implementation Steps

No implementation steps. See children:

- **t2127 (#19223)** — higgsfield residual cluster (4 files)
- **t2128 (#19224)** — oauth-pool plugin cluster (3 files)
- **t2129 (#19225)** — email pipeline python cluster (5 files)
- **t2130 (#19226)** — doc/indexing python cluster (5 files)
- **t2131 (#19227)** — misc scripts cluster (3 files)

### Verification

```bash
# Total smell count should drop from 20 toward ~5 as children merge.
# After ALL five children merge:
qlty smells --all --sarif 2>/dev/null | jq '.runs[0].results | length'
# Expected: ≤ 10 (upper bound; actual likely 3-6)

# QLTY_SMELL_THRESHOLD ratcheted down:
grep '^QLTY_SMELL_THRESHOLD=' .agents/configs/complexity-thresholds.conf
# Expected: value decreased from 22, matching new_count + 2
```

## Acceptance Criteria

- [ ] All 5 child cluster issues closed via merged PR
  ```yaml
  verify:
    method: bash
    run: "for n in 19223 19224 19225 19226 19227; do gh issue view $n --json state -q .state | grep -q CLOSED || exit 1; done"
  ```
- [ ] `qlty smells --all` total count is ≤ 10
  ```yaml
  verify:
    method: bash
    run: "test $(qlty smells --all --sarif 2>/dev/null | jq '.runs[0].results | length') -le 10"
  ```
- [ ] Grade A maintained in `stats-quality-sweep.sh` dashboard (QLTY_GRADE_A_MAX=20, actual ≤ 20)
  ```yaml
  verify:
    method: manual
    prompt: "Check daily quality sweep output — grade is A"
  ```
- [ ] `QLTY_SMELL_THRESHOLD` ratcheted down by at least 10 (from 22 to ≤ 12)
  ```yaml
  verify:
    method: bash
    run: "test $(grep '^QLTY_SMELL_THRESHOLD=' .agents/configs/complexity-thresholds.conf | cut -d= -f2) -le 12"
  ```

## Context & Decisions

- **Cluster-per-task over file-per-task:** PRs #18893, #18906, #18948 all shipped multi-file decompositions in single PRs. Matches the natural coupling (files in `higgsfield/` share state, files in `opencode-aidevops/oauth-pool*` share the rotation layer). One-file-per-task would create 20 worker dispatches and 20 PRs for work that logically belongs in 5 units.
- **tier:thinking for clusters:** decomposition is design work, not transcription. The worker decides the module boundary — no pre-drawn line in the brief. Haiku/Sonnet routinely produce shallow splits that just move complexity around without reducing it.
- **Parent-task pattern:** `#parent` tag keeps this issue out of dispatch rotation while preserving the one-stop audit trail. See t1986 / `reference/planning-detail.md`.
- **Auto-ratchet dependency:** t2067 (auto-ratchet) is already merged. Each cluster merge automatically tightens `QLTY_SMELL_THRESHOLD`, so this campaign is self-enforcing — you cannot ship the first cluster and then silently regress.
- **Non-goal — clearing the residual Python scripts in t2131 completely.** The 3 files there (voice-bridge 95, normalise-markdown 80, tabby-profile-sync 76) are modestly over the threshold. If one proves hard to split cleanly, the worker may leave it and document why; the campaign still succeeds if 17/20 smells clear.

## Relevant Files

- `.agents/configs/complexity-thresholds.conf` — `QLTY_SMELL_THRESHOLD` anchor (auto-ratcheted)
- `.agents/scripts/qlty-regression-helper.sh` — PR regression gate logic
- `.github/workflows/qlty-regression.yml` — PR gate workflow
- `.agents/scripts/higgsfield/verify-cluster.sh` — pattern for post-decomp characterisation test (the higgsfield cluster ships one; other clusters should consider copying the pattern)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** dropping `QLTY_SMELL_THRESHOLD` below 20 (needed for real grade-A enforcement with margin)
- **External:** none — all work is in-repo

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Planning (this brief) | 30m | — |
| Child t2127 (higgsfield) | 3h | largest — 4 files, 914 total complexity |
| Child t2128 (oauth-pool) | 2h | 3 files, 310 total complexity |
| Child t2129 (email) | 3h | 5 files, 590 total complexity |
| Child t2130 (doc-indexing) | 2.5h | 5 files, 514 total complexity |
| Child t2131 (misc) | 1.5h | 3 files, 251 total complexity |
| **Campaign total** | **~12.5h** | across 5 worker dispatches |
