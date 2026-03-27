# Worktree Cleanup After Merge

After a PR is merged, clean up the linked worktree and return the canonical repo to a clean state.

## Automated Cleanup (workers — GH#6740)

Workers dispatched via `/full-loop` MUST self-cleanup after successful merge (Step 4.8). This prevents worktree accumulation during batch dispatch.

```bash
# After gh pr merge --squash succeeds:
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
CANONICAL_DIR="${WORKTREE_PATH%%.*}"

# Return to canonical repo, pull, remove worktree
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

Cleanup failures are non-fatal — the PR is already merged. The pulse `cleanup_worktrees()` stage acts as a safety net for any worktrees workers fail to clean up.

## Manual Cleanup (interactive sessions)

```bash
# Merge the PR without --delete-branch (required when working from a worktree)
gh pr merge --squash

# Return to the canonical repo directory
cd ~/Git/$(basename "$PWD" | cut -d. -f1)

# Pull the merged changes into main
git pull origin main

# Remove merged worktrees
wt prune
```

## Notes

- **Do not use `--delete-branch`** with `gh pr merge` when running from inside a worktree — it will fail because the branch is checked out in the worktree, not the canonical repo.
- `wt prune` removes worktrees whose branches have been merged and deleted on the remote. Run it from the canonical repo directory (on `main`), not from inside the worktree.
- If `wt prune` is unavailable, use `git worktree prune` to remove stale worktree entries, then manually delete the worktree directory.
- The pulse runs `cleanup_worktrees()` every cycle as a safety net, but workers should not rely on it — self-cleanup prevents accumulation during batch operations.

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
- `full-loop.md` Step 4.8 — worker self-cleanup specification
