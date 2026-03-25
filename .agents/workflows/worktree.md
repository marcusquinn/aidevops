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
- **Core principle**: Main repo (`~/Git/{repo}/`) ALWAYS stays on `main`
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

## Why Worktrees?

Standard git has one working directory per clone — `git checkout` in any terminal affects all terminals. Worktrees give each branch its own directory so sessions are fully independent.

**Never use `git checkout -b` in the main repo directory.** Always use worktrees. If the main repo is left on a feature branch, the next session inherits wrong state and parallel workflow assumptions break.

## Workflow Patterns

### Parallel Feature Development

```bash
worktree-helper.sh add feature/user-auth   # ~/Git/myrepo-feature-user-auth/
worktree-helper.sh add feature/api-v2      # ~/Git/myrepo-feature-api-v2/
# Work on each in separate terminals/editors
```

### Quick Bug Fix During Feature Work

```bash
# Don't leave your feature worktree — create a new one
worktree-helper.sh add hotfix/security-patch
cd ~/Git/myrepo-hotfix-security-patch/
# Fix, commit, push, PR — then return to feature work unchanged
```

### Multiple AI Sessions

```bash
opencode ~/Git/myrepo-feature-auth/    # Session 1: feature
opencode ~/Git/myrepo-bugfix-login/    # Session 2: bug
opencode ~/Git/myrepo-chore-docs/      # Session 3: docs
```

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

# Batch cleanup (merged branches)
worktree-helper.sh clean                 # Prompts before removing; runs git fetch --prune
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

Session matching scores: exact branch name in title (+100), branch slug (+80), key terms (+20 each), created within 1h of branch (+40). **Best practice**: use `session-rename_sync_branch` after creating branches.

## Best Practices

### Ownership Safety (t189)

Worktrees are registered to the creating session's PID in a SQLite registry — prevents cross-session removal.

```bash
worktree-helper.sh registry list    # View ownership registry
worktree-helper.sh registry prune   # Prune stale entries (dead PIDs, missing dirs)
worktree-helper.sh remove feature/branch --force  # Override ownership (use with caution)
```

Registry: `~/.aidevops/.agent-workspace/worktree-registry.db`

### Squash Merge Detection

`clean` detects merged branches two ways: `git branch --merged` (traditional) and deleted remote branches after PR merge (squash). Runs `git fetch --prune` automatically.

### Don't Checkout Same Branch Twice

Git prevents this — each branch can only be checked out in one worktree at a time.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Branch is already checked out" | `git worktree list \| grep feature/auth` — use or remove that worktree |
| "Worktree path already exists" | `rm -rf ~/Git/myrepo-feature-auth` if safe, then re-add |
| Stale worktree references | `git worktree prune` |
| Detached HEAD | `cd` into worktree, `git checkout feature/auth` |

### Worktree Deleted Mid-Session

```bash
git branch --list feature/my-feature          # Check if branch still exists
worktree-helper.sh add feature/my-feature     # Recreate worktree
git stash list && git stash pop               # Restore uncommitted changes if any
```

Use `session-rename_sync_branch` to re-sync the session name after recreating. Before closing a PR or deleting a branch, check `worktree-sessions.sh list` for active sessions.

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
