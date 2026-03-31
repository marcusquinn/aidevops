# Worktree Cleanup After Merge

Clean up the linked worktree and return the canonical repo to a clean state after a PR merge.

## Automated (workers — GH#6740)

Workers MUST self-cleanup after merge (full-loop Step 4.9). Prevents worktree accumulation during batch dispatch.

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

Cleanup failures are non-fatal — the PR is already merged. The pulse `cleanup_worktrees()` acts as a safety net.

## Manual (interactive sessions)

```bash
gh pr merge --squash                              # no --delete-branch from worktrees
cd ~/Git/$(basename "$PWD" | cut -d. -f1)         # return to canonical repo
git pull origin main
wt prune                                          # remove merged worktrees
```

**Key rules:**

- **No `--delete-branch`** — fails from inside a worktree (branch is checked out there, not in canonical repo).
- **`wt prune`** — run from canonical repo on `main`. Falls back: `git worktree prune` + manual directory removal.

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
- `full-loop.md` Step 4.9 — worker self-cleanup specification
