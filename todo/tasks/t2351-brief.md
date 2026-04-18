<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2351 Brief — pulse: periodic canonical-repo fast-forward + stale worktree cleanup

**Issue:** GH#TBD (filed alongside this brief).

## Session origin

Discovered 2026-04-18 during board-clearing session: (a) canonical `~/Git/aidevops` was 2 commits behind `origin/main` at session start — no harness keeps it current; (b) `git worktree list` reported 169 total worktrees, with ~30 dating from 2026-04-15 (3 days stale) whose branches were already merged. The existing `worktree-helper.sh clean --auto --force-merged` handles the cleanup but isn't scheduled, and nothing keeps canonical main fresh for interactive sessions that land on it by default.

## What

Add two scheduled maintenance tasks to the pulse:

1. **Canonical-repo fast-forward**: for every repo in `~/.config/aidevops/repos.json`, run `git fetch origin && git checkout main && git pull --ff-only origin main` if the working tree is clean and no active session is mid-edit.
2. **Stale worktree sweep**: for every repo, invoke `worktree-helper.sh clean --auto --force-merged` to drop worktrees whose branch is merged or PR is closed.

Both run on a cadence (every ~30min is sufficient — not per-cycle).

## Why

- Interactive sessions start on canonical main by default. Stale main causes false `pre-edit-check.sh` decisions and requires manual `git pull`.
- Stale worktrees consume disk, clutter `git worktree list`, and confuse the cross-session ownership check (`pre-edit-check.sh` "ownership conflict" logic).
- Both operations are deterministic and safe with the right gates (fail-open on uncommitted changes, respect active-session stamps).
- Agent doesn't need to remember to run these — the harness should.

## How

**NEW**: `.agents/scripts/pulse-canonical-maintenance.sh` — new pulse stage combining both operations.

**EDIT**: `.agents/scripts/pulse-wrapper.sh` — register after existing merge/dispatch passes (runs once every ~30min via cadence counter).

**Reference pattern**: follow `.agents/scripts/pulse-simplification.sh` lifecycle (state file, cadence gate, per-repo loop, audit log).

### Fast-forward logic

For each repo in `repos.json` where `pulse: true`:

1. Skip if repo is `local_only: true`.
2. `git -C $repo status --porcelain` — skip if any output (dirty tree).
3. `git -C $repo stash list` — skip if stash non-empty (session in-flight).
4. Check `.agents/active-session-stamps/` or equivalent — skip if active session owns canonical.
5. `git -C $repo fetch origin --prune --quiet`.
6. Check `git -C $repo rev-list --count HEAD..origin/main`. If 0, done. Otherwise:
7. `git -C $repo checkout main && git -C $repo pull --ff-only origin main`.
8. Log result via `audit-log-helper.sh log canonical-maintenance`.

### Worktree cleanup logic

For each repo in `repos.json`:

1. Skip if `local_only: true`.
2. `worktree-helper.sh clean --auto --force-merged` — the existing helper handles eligibility (merged branches, closed PRs via `gh pr list`, squash-merge detection).
3. Log summary via audit log.

### Timeout + safety

- Hard timeout per repo (60s each) — the worktree cleanup was observed to spawn 13 runaway processes during manual run (2026-04-18); add `timeout 60 worktree-helper.sh ...` or equivalent and track why it was slow (likely per-worktree `gh pr list` network round-trips).
- Before scheduling, investigate why `worktree-helper.sh clean --auto --force-merged` ran >3min on a 166-worktree checkout — may be a linear scan without batching. File as follow-up if so.

## Acceptance criteria

1. `pulse-canonical-maintenance.sh --dry-run` lists repos needing fast-forward and stale worktrees without mutating state.
2. Real run fast-forwards canonical main for every clean repo and removes every merged worktree.
3. Dirty tree → skip (no stash, no reset).
4. Active session stamp → skip (no clobber).
5. Audit log entries for every action.
6. Test harness `tests/test-pulse-canonical-maintenance.sh` covers skip-on-dirty, skip-on-session-active, successful fast-forward, worktree cleanup integration.
7. Registered in `pulse-wrapper.sh` on a 30min cadence — not per-cycle.
8. Per-repo hard timeout prevents runaway (60s per repo is a generous default).

## Tier

`tier:standard` — well-defined mechanics, one new pulse stage, clear safety gates.

## Related

- Existing `worktree-helper.sh clean --auto --force-merged` handles the cleanup mechanics — this task only schedules and gates it.
- `pulse-simplification.sh` is the cadence-gated template to copy.
- Canonical repo was 2 commits behind origin at 2026-04-18 21:30 UTC — caught manually during board-clearing session.
