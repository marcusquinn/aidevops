---
description: Parallel branch development with git worktrees
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Git Worktree Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Separate working directories per branch — no branch-switching conflicts
- **Core principle**: Main repo (`~/Git/{repo}/`) ALWAYS stays on `main`. **Never `git checkout -b` in the main repo** — the next session inherits wrong state.
- **Preferred tool**: [Worktrunk](https://worktrunk.dev) (`brew install max-sixty/worktrunk/wt`)
- **Fallback**: `~/.aidevops/agents/scripts/worktree-helper.sh`
- **Paths**: `~/Git/myrepo/` (main) | `~/Git/myrepo-feature-auth/` (linked) | `~/Git/myrepo-bugfix-login/` (linked)

<!-- AI-CONTEXT-END -->

## Commands

**Worktrunk** (preferred — shell cd, hooks, CI status, merge workflow):

```bash
wt switch -c feature/my-feature   # Create worktree + cd into it
wt list                           # List worktrees with CI status
wt merge                          # Squash/rebase/merge + cleanup
wt remove                         # Remove current worktree
```

**worktree-helper.sh** (fallback — no cd support):

```bash
worktree-helper.sh add feature/my-feature          # Auto-path: ~/Git/{repo}-feature-my-feature/
worktree-helper.sh add feature/my-feature ~/custom  # Custom path
worktree-helper.sh list                             # List worktrees
worktree-helper.sh status                           # Status overview
worktree-helper.sh remove feature/auth              # Removes directory, NOT the branch
worktree-helper.sh clean                            # Batch cleanup merged branches (interactive, runs git fetch --prune)
```

Full Worktrunk docs: `tools/git/worktrunk.md`.

## Workflow Patterns

```bash
# Hotfix without leaving feature work
worktree-helper.sh add hotfix/security-patch
# Fix, commit, push, PR in ~/Git/myrepo-hotfix-security-patch/ — feature worktree unchanged

# Multiple AI sessions on separate worktrees
opencode ~/Git/myrepo-feature-auth/    # Session 1
opencode ~/Git/myrepo-bugfix-login/    # Session 2
```

## Integration

`pre-edit-check.sh` works in any worktree — main or linked.

**Localdev (t1224.8):** Worktree creation auto-sets branch-specific subdomain routing (`https://feature-auth.myapp.local`) for `localdev add` projects. Removal auto-cleans the route.

**Session recovery:**

```bash
worktree-sessions.sh list   # List worktrees with matching sessions
worktree-sessions.sh open   # Interactive: select + open
```

Use `session-rename_sync_branch` after creating branches. Check `worktree-sessions.sh list` before closing PRs or deleting branches.

## Ownership Safety (t189)

Worktrees registered to creating session's PID in SQLite (`~/.aidevops/.agent-workspace/worktree-registry.db`) — prevents cross-session removal.

```bash
worktree-helper.sh registry list    # View ownership
worktree-helper.sh registry prune   # Prune stale entries (dead PIDs, missing dirs)
worktree-helper.sh remove feature/branch --force  # Override ownership (use with caution)
```

## Worker Self-Cleanup (GH#6740)

Workers must remove their worktree after PR merge — batch dispatches (50+ workers) accumulate worktrees faster than pulse cleanup. See `full-loop.md` Step 4.8 and `commands/worktree-cleanup.md`.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Branch is already checked out" | `git worktree list \| grep feature/auth` — use or remove that worktree |
| "Worktree path already exists" | `rm -rf ~/Git/myrepo-feature-auth` if safe, then re-add |
| Stale worktree references | `git worktree prune` |
| Detached HEAD | `cd` into worktree, `git checkout feature/auth` |
| Worktree deleted mid-session | `git branch --list feature/my-feature` → `worktree-helper.sh add feature/my-feature` → `git stash pop` |

## Related

| File | When to Read |
|------|--------------|
| `git-workflow.md` | Branch naming, commit conventions |
| `branch.md` | Branch type selection |
| `multi-repo-workspace.md` | Multiple repositories |
| `pr.md` | Pull request creation |
