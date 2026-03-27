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

**Directory structure**:

```text
~/Git/myrepo/                      # Main worktree (main branch)
~/Git/myrepo-feature-auth/         # Linked worktree (feature/auth)
~/Git/myrepo-bugfix-login/         # Linked worktree (bugfix/login)
```

**Worktrunk commands** (preferred):

```bash
wt switch -c feature/my-feature   # Create worktree + cd into it
wt list                           # List worktrees with CI status
wt merge                          # Squash/rebase/merge + cleanup
wt remove                         # Remove current worktree
```

**worktree-helper.sh commands** (fallback):

```bash
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean
```

<!-- AI-CONTEXT-END -->

## Commands Reference

```bash
# Create
worktree-helper.sh add feature/my-feature          # Auto-path: ~/Git/{repo}-feature-my-feature/
worktree-helper.sh add feature/my-feature ~/custom  # Custom path

# List / Status
worktree-helper.sh list
worktree-helper.sh status

# Remove
worktree-helper.sh remove feature/auth   # Removes directory, NOT the branch
git branch -d feature/auth               # Delete branch separately if needed

# Batch cleanup (merged branches — interactive only)
# Detects squash-merged branches via deleted remote refs; runs git fetch --prune automatically
worktree-helper.sh clean

# Worker self-cleanup (automated — after PR merge in /full-loop)
# Workers remove their own worktree after merge (GH#6740).
# See full-loop.md Step 4.8 for the full procedure.
```

## Workflow Patterns

```bash
# Parallel features
worktree-helper.sh add feature/user-auth   # ~/Git/myrepo-feature-user-auth/
worktree-helper.sh add feature/api-v2      # ~/Git/myrepo-feature-api-v2/

# Hotfix without leaving feature work
worktree-helper.sh add hotfix/security-patch
cd ~/Git/myrepo-hotfix-security-patch/
# Fix, commit, push, PR — feature worktree unchanged

# Multiple AI sessions
opencode ~/Git/myrepo-feature-auth/    # Session 1
opencode ~/Git/myrepo-bugfix-login/    # Session 2
```

## Integration with aidevops

### Pre-Edit Check

`pre-edit-check.sh` works correctly in any worktree — main or linked.

### Localdev Integration (t1224.8)

For projects registered with `localdev add`, worktree creation auto-sets up branch-specific subdomain routing:

```bash
worktree-helper.sh add feature/auth
# Also runs: localdev branch myapp feature/auth
# Output: https://feature-auth.myapp.local
```

Worktree removal auto-cleans the corresponding branch route.

### Session Recovery

```bash
~/.aidevops/agents/scripts/worktree-sessions.sh list   # List worktrees with matching sessions
~/.aidevops/agents/scripts/worktree-sessions.sh open   # Interactive: select + open in OpenCode
```

**Best practice**: use `session-rename_sync_branch` after creating branches. Before closing a PR or deleting a branch, check `worktree-sessions.sh list` for active sessions.

## Best Practices

### Ownership Safety (t189)

Worktrees are registered to the creating session's PID in a SQLite registry — prevents cross-session removal.

```bash
worktree-helper.sh registry list    # View ownership registry
worktree-helper.sh registry prune   # Prune stale entries (dead PIDs, missing dirs)
worktree-helper.sh remove feature/branch --force  # Override ownership (use with caution)
```

Registry: `~/.aidevops/.agent-workspace/worktree-registry.db`

### Worker Self-Cleanup (GH#6740)

Workers dispatched via `/full-loop` must remove their worktree after successful PR merge. Without this, batch dispatches (50+ workers) accumulate worktrees faster than the pulse cleanup cycle can remove them, eventually blocking new workers. See `full-loop.md` Step 4.8 and `commands/worktree-cleanup.md`.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Branch is already checked out" | `git worktree list \| grep feature/auth` — use or remove that worktree |
| "Worktree path already exists" | `rm -rf ~/Git/myrepo-feature-auth` if safe, then re-add |
| Stale worktree references | `git worktree prune` |
| Detached HEAD | `cd` into worktree, `git checkout feature/auth` |
| Same branch checked out twice | Git prevents this — each branch can only be in one worktree at a time |
| Worktree deleted mid-session | `git branch --list feature/my-feature` → `worktree-helper.sh add feature/my-feature` → `git stash pop` |

Use `session-rename_sync_branch` to re-sync the session name after recreating a worktree.

## Tool Comparison

| Feature | Worktrunk (`wt`) | worktree-helper.sh |
|---------|------------------|-------------------|
| Shell integration (cd support) | Yes | No (prints path only) |
| Hooks (post-create, etc.) | Yes | No |
| CI status + PR links in list | Yes | No |
| Merge workflow | `wt merge` | Manual |
| LLM commits | Yes (via llm) | No |
| Dependencies | Rust binary | Bash only |

Use Worktrunk when available. Use worktree-helper.sh as fallback or in minimal environments. See `tools/git/worktrunk.md` for full Worktrunk docs.

## Related

| File | When to Read |
|------|--------------|
| `git-workflow.md` | Branch naming, commit conventions |
| `branch.md` | Branch type selection |
| `multi-repo-workspace.md` | Multiple repositories |
| `pr.md` | Pull request creation |
