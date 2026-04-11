<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worktree Cleanup After Merge

After a PR merges, clean up the linked worktree and return the canonical repo to a clean state.

**Key constraint:** Never pass `--delete-branch` to `gh pr merge` from inside a worktree — the branch is checked out there, not in the canonical repo.

## Automated Cleanup (workers — GH#6740)

Workers dispatched via `/full-loop` MUST self-cleanup after successful merge (Step 4.9). The pulse `cleanup_worktrees()` stage is a safety net — workers must not rely on it; self-cleanup prevents accumulation during batch dispatch.

```bash
# After gh pr merge --squash succeeds:
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
CANONICAL_DIR="${WORKTREE_PATH%%.*}"

cd "$CANONICAL_DIR" || cd "$HOME"
git pull origin main 2>/dev/null || true

HELPER="$HOME/.aidevops/agents/scripts/worktree-helper.sh"
if [[ -x "$HELPER" ]]; then
  WORKTREE_FORCE_REMOVE=true "$HELPER" remove "$BRANCH_NAME" --force 2>/dev/null || true
else
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi

git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
```

Cleanup failures are non-fatal — the PR is already merged.

## Manual Cleanup (interactive sessions)

```bash
# Merge without --delete-branch (required from inside a worktree)
gh pr merge --squash

# Return to canonical repo and pull
cd ~/Git/$(basename "$PWD" | cut -d. -f1)
git pull origin main

# Remove merged worktrees
wt prune
```

`wt prune` removes worktrees whose branches have been merged and deleted on the remote. Run from the canonical repo (on `main`). If unavailable: `git worktree prune` then delete the worktree directory manually.

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
- `full-loop.md` Step 4.9 — worker self-cleanup specification
