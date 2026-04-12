<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2003: Phase 12 — split `cleanup_worktrees()` (250 lines) AND fix GH#18346 silent-skip bug

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #5 — explicitly listed with the GH#18346 fix in same PR)
- **Function location:** `.agents/scripts/pulse-cleanup.sh:53` (extracted in Phase 5, t1973 / #18381)

## What

Two changes in one PR:

1. **Split `cleanup_worktrees()`** into per-worktree processing helpers. Currently 250 lines combining: discovery, age check, ownership check, lock check, removal action, registry update.
2. **Fix GH#18346** — `cleanup_worktrees` silently skips worktrees in some condition (the bug is documented in plan §6 Phase 5 notes: "cleanup_worktrees is 250 lines and has its own known silent-skip bug (GH#18346). Do not fix during extraction — file a follow-up.").

The plan explicitly bundles these into one PR because the fix is easier to apply *during* the split (when the logic is being audited line by line) than as a separate retrofit.

## Why

- 250 lines, tied for fourth-largest survivor.
- The silent-skip bug (GH#18346) means stale worktrees accumulate in `~/Git/` over time. Observed: dozens of `feature/auto-2026*` worktrees from killed workers that should have been reaped.
- Splitting + fixing simultaneously is safer than two passes (the second pass would have to re-derive context the first pass already had).

## Tier

`tier:standard`. The split is mechanical, but the bug fix requires understanding the silent-skip path. Worker should read GH#18346 first to understand the failure mode before splitting.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-cleanup.sh:53-302` — `cleanup_worktrees()` body
- **VERIFY:** any test that exercises cleanup_worktrees — likely none directly, but the live pulse exercises it every cycle (check pulse.log after merge)

### Step 0 — read GH#18346

```bash
gh issue view 18346 --repo marcusquinn/aidevops
```

Understand the exact silent-skip condition. The fix is probably 2-5 lines in the right place. Apply the fix as part of the split, mention it explicitly in the commit message.

### Recommended split

1. Identify the per-worktree loop body. Extract into `_cleanup_single_worktree()`.
2. The new function should: take a worktree path, decide skip-or-remove, perform the action, return 0/1.
3. Parent becomes: enumerate worktrees → for each → `_cleanup_single_worktree`.

Optionally extract:
- `_worktree_age_seconds()` — age computation helper
- `_worktree_owner_alive()` — ownership/lock check helper

These are small but separable.

### Fix GH#18346 in the same PR

After extracting the loop body, the silent-skip path becomes obvious (it's now isolated in `_cleanup_single_worktree`). Apply the fix in the same commit. Mention `Fixes #18346` in the PR body.

### Verification

```bash
bash -n .agents/scripts/pulse-cleanup.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-cleanup.sh
# Sandbox dry-run
# Then post-merge: monitor pulse.log for cleanup_worktrees lines, verify the silent-skip is gone
```

## Acceptance Criteria

- [ ] `cleanup_worktrees()` reduced to under 80 lines
- [ ] `_cleanup_single_worktree()` extracted, under 180 lines
- [ ] **GH#18346 fixed** — PR body explains the silent-skip root cause and the fix in 2-3 sentences
- [ ] All existing pulse tests pass
- [ ] `--self-check` clean
- [ ] `shellcheck` no new findings
- [ ] **Post-merge verification:** monitor live pulse for 2-3 cycles, confirm orphan worktrees that previously survived now get cleaned. Document in PR comment.

## Relevant Files

- `.agents/scripts/pulse-cleanup.sh:53`
- GH#18346 (the silent-skip bug — read this first)
- `~/Git/aidevops-feature-auto-*` directories (the visible symptom — many of these on the canonical machine right now)

## Dependencies

- **Blocked by:** none
- **Blocks:** clean worktree state on every developer machine (currently piling up)

## Estimate

~3h. Slightly larger because of the bug-fix component requiring understanding of GH#18346 root cause.
