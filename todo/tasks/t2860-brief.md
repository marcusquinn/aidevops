<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2860: pulse-cleanup destroys worktrees without calling unregister_worktree, leaking SQLite registry entries

## Pre-flight

- [x] Memory recall: "worktree registry cleanup unregister" — no directly-relevant lessons; closest is t2859 unbound-var pattern
- [x] Discovery pass: t2859 (PR #20915) currently in-flight on the same file (`pulse-cleanup.sh`); coordinate via base-rebase after it merges
- [x] File refs verified: `pulse-cleanup.sh:459-463` and `worktree-helper.sh:1196` checked at HEAD
- [x] Tier: `tier:standard` — single function modification with clear pattern to copy from `worktree-helper.sh:1196`

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (surfaced during t2859 investigation)
- **Parent task:** none (independent bug, not a child of t2840)
- **Conversation context:** While debugging t2859 (unbound `ORPHAN_WORKTREE_GRACE_SECS` causing 49 worktree destructions in 1h), inspected the SQLite worktree registry at `~/.aidevops/.agent-workspace/worktree-registry.db`. Found 815 April entries with stale PIDs — the cleanup pass deletes worktrees but never deregisters them from the ownership registry, so entries accumulate forever.

## What

`_cleanup_single_worktree` in `pulse-cleanup.sh` must call `unregister_worktree "$wt_path_age"` immediately after the worktree directory is destroyed (after `_trash_or_remove` succeeds). This mirrors the pattern already established in `worktree-helper.sh:1196` (the `cmd_remove` path).

After the fix:

- Pulse cleanup destroys a worktree → SQLite registry entry is removed in the same operation.
- `is_worktree_owned_by_others` cannot return false-positives for paths that no longer exist on disk.
- Registry size stays proportional to live worktrees, not lifetime cumulative.

## Why

The SQLite worktree registry (`worktree_owners` table) is the source of truth for `is_worktree_owned_by_others`, `check_worktree_owner`, and the conflict-detection that prevents two sessions from owning the same path. When pulse-cleanup destroys a worktree without deregistering it, the registry retains a row pointing to a path that no longer exists, with a PID that may have been long since recycled.

Concrete impact:

1. **Registry bloat:** 815 entries currently exist for ~7 live worktrees. The deployed registry contains entries dating from late March that should have been removed when the underlying worktrees were destroyed.
2. **PID-collision false positives:** if a stale entry's `owner_pid` happens to match a currently-running process (PIDs are reused), `check_worktree_owner` will report the path as actively owned even though it doesn't exist. The blast radius depends on how often PIDs collide on the user's machine — low probability per entry but probability rises with registry size.
3. **Diagnostic noise:** `prune_worktree_registry` (called only from `wt clean`, line 1921) is the only mechanism that removes stale entries, and it runs only on user invocation. Users who never run `wt clean` accumulate registry rot indefinitely.

`worktree-helper.sh::cmd_remove` already gets this right at line 1196 (`unregister_worktree "$path_to_remove"`). `pulse-cleanup.sh` is the divergent code path that needs to match.

## Tier

**Selected tier:** `tier:standard`

**Rationale:** Single-function edit in shell, but `pulse-cleanup.sh` is in `.agents/configs/self-hosting-files.conf` (dispatch-path file). Per build.txt §"Dispatch-Path Default (t2821)", dispatch-path tasks default to `no-auto-dispatch` + `#interactive` regardless of complexity. The fix itself is mechanical — copy a single line of pattern from a sibling file — but the file's blast radius (broken pulse cleanup → cascading worker damage like t2859) means this should land via maintainer review, not auto-dispatch.

## PR Conventions

Leaf task. PR body uses `Resolves #NNN` (where NNN is the GH issue number filed alongside this brief).

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-cleanup.sh:459-463` — add `unregister_worktree` call after `_trash_or_remove` succeeds.

### Implementation Steps

1. Read the current cleanup block:

```bash
# Step 5b: perform removal (trash worktree dir + deregister + branch cleanup)
# ...
# Then deregister from git. Falls back to git worktree remove if trash fails.
_trash_or_remove "$wt_path_age" || git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null || true
```

The comment claims "deregister from git" — but only the git-worktree-prune side is handled. The SQLite ownership registry is never touched.

2. Add the registry deregistration after the directory is destroyed. Model on `worktree-helper.sh:1196`:

```bash
# Source pattern at worktree-helper.sh:1196
unregister_worktree "$path_to_remove"
```

3. Apply to `pulse-cleanup.sh`. After the existing `_trash_or_remove` line (around line 462), add:

```bash
_trash_or_remove "$wt_path_age" || git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null || true

# t2860: deregister from SQLite ownership registry to prevent stale entries.
# Mirrors the pattern in worktree-helper.sh:1196 (cmd_remove path).
unregister_worktree "$wt_path_age" 2>/dev/null || true
```

The `2>/dev/null || true` matches the existing tolerance — registry deregistration must never block cleanup.

4. Confirm `unregister_worktree` is in scope. `pulse-cleanup.sh` already sources `shared-constants.sh` which sources `shared-worktree-registry.sh`. If `command -v unregister_worktree` is empty in the cleanup context, source `shared-worktree-registry.sh` directly (mirror what `worktree-helper.sh` does).

5. Add a regression test at `.agents/scripts/test-pulse-cleanup-unregister.sh` modeled on `test-pulse-cleanup-config-defaults.sh` (just landed in t2859):
   - Create a temporary worktree in a sandbox repo
   - Register it via `register_worktree`
   - Trigger `_cleanup_single_worktree` (or its inner removal block)
   - Assert the SQLite entry is gone after cleanup completes

### Complexity Impact

- **Target function:** `_cleanup_single_worktree` in `.agents/scripts/pulse-cleanup.sh`
- **Current line count:** approximately 60-80 lines (verify before editing)
- **Estimated growth:** +3 lines (one comment + one function call + one tolerance)
- **Projected post-change:** still well under 100-line function-complexity threshold
- **Action required:** None — well below threshold.

### Verification

```bash
# 1. Source compile cleanly
shellcheck .agents/scripts/pulse-cleanup.sh

# 2. Pattern verification
grep -n 'unregister_worktree' .agents/scripts/pulse-cleanup.sh
# Expected: at least one match in the _cleanup_single_worktree block

# 3. Behavioral test
.agents/scripts/test-pulse-cleanup-unregister.sh
# Expected: PASS — registry entry removed after cleanup

# 4. End-to-end verification (after merge): live registry should stop growing
# Baseline: sqlite3 ~/.aidevops/.agent-workspace/worktree-registry.db "SELECT COUNT(*) FROM worktree_owners;"
# After 24h with cleanup running: count should be proportional to live worktrees, not cumulative.
```

### Files Scope

- `.agents/scripts/pulse-cleanup.sh`
- `.agents/scripts/test-pulse-cleanup-unregister.sh`

## Acceptance Criteria

- [ ] `_cleanup_single_worktree` calls `unregister_worktree` after the worktree directory is destroyed.
- [ ] `shellcheck .agents/scripts/pulse-cleanup.sh` clean.
- [ ] New regression test `test-pulse-cleanup-unregister.sh` PASSes.
- [ ] Manual verification on running pulse: a destroyed worktree's row is gone from `worktree-registry.db` within 1 cleanup cycle.

## Context & Decisions

- **Why this is a real bug, not just cosmetic:** PID reuse on macOS within a 32-bit PID space means stale entries can become live false-positives. With 815 entries currently in the registry, the probability of collision is non-zero on a busy machine.
- **Why not retroactively prune?** That's a separate concern — `prune_worktree_registry` already exists and works. This task fixes the leak at source so the registry stops accumulating in the first place.
- **Why `tier:standard` not `tier:simple`:** the file is on the dispatch-path list. Even mechanical edits to dispatch-path files require maintainer eyes per t2821.
- **Coordination with t2859:** t2859 (PR #20915) is currently in flight on the same file. Land t2859 first; rebase this onto the post-merge default branch.

## Relevant Files

- `.agents/scripts/pulse-cleanup.sh:459-463` — the `_trash_or_remove` call site that needs registry deregistration added.
- `.agents/scripts/worktree-helper.sh:1196` — reference pattern: `unregister_worktree "$path_to_remove"` in `cmd_remove`.
- `.agents/scripts/shared-worktree-registry.sh` — defines `register_worktree`, `unregister_worktree`, `prune_worktree_registry`.
- `~/.aidevops/.agent-workspace/worktree-registry.db` — current registry state (815 stale-looking April entries).
- `.agents/scripts/test-pulse-cleanup-config-defaults.sh` — model for the new regression test (t2859 pattern).

## Dependencies

- **Blocked by:** t2859 / PR #20915 (same file currently in flight)
- **Blocks:** none directly; closes a long-standing registry accuracy gap
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | re-read pulse-cleanup.sh:430-480 and worktree-helper.sh:1180-1210 |
| Implementation | 15m | one comment + one call + one source guard |
| Testing | 30m | write regression test modelled on t2859's test |
| **Total** | **~50m** | |
