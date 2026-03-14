# Worktree Cleanup After Merge

After a PR is merged, clean up the linked worktree and return the canonical repo to a clean state.

## Commands

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

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
