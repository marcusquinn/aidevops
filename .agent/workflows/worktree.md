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

- **Purpose**: Enable parallel work on multiple branches without conflicts
- **Problem solved**: Branch switching affects all terminal tabs/sessions
- **Solution**: Separate working directories, each on its own branch
- **Core principle**: Main repo (`~/Git/{repo}/`) ALWAYS stays on `main`

**Key Commands**:

```bash
# Create worktree for a branch
~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature

# List all worktrees
~/.aidevops/agents/scripts/worktree-helper.sh list

# Remove worktree (keeps branch)
~/.aidevops/agents/scripts/worktree-helper.sh remove feature/my-feature

# Clean up merged worktrees
~/.aidevops/agents/scripts/worktree-helper.sh clean
```

**Directory Structure**:

```text
~/Git/myrepo/                      # Main worktree (main branch)
~/Git/myrepo-feature-auth/         # Linked worktree (feature/auth)
~/Git/myrepo-bugfix-login/         # Linked worktree (bugfix/login)
```

<!-- AI-CONTEXT-END -->

## Why Worktrees?

### The Problem

Standard git workflow has one working directory per clone:

```text
Terminal 1: ~/Git/myrepo (feature/auth)
Terminal 2: ~/Git/myrepo (feature/auth)  ← Same directory!
Terminal 3: ~/Git/myrepo (feature/auth)  ← All affected by branch switch
```

When you `git checkout bugfix/login` in Terminal 1, **all terminals** now see `bugfix/login`. This causes:

- Lost context in other sessions
- Uncommitted changes conflicts
- AI assistants confused about which branch they're on
- Interrupted parallel work

### The Solution

Git worktrees give each branch its own directory:

```text
Terminal 1: ~/Git/myrepo/                  (main)
Terminal 2: ~/Git/myrepo-feature-auth/     (feature/auth)
Terminal 3: ~/Git/myrepo-bugfix-login/     (bugfix/login)
```

Each terminal/session is completely independent. No interference.

## How Worktrees Work

### Shared Git Database

All worktrees share the same `.git` database:

- **Commits** - All commits visible in all worktrees
- **Branches** - All branches accessible from any worktree
- **Stashes** - Shared across worktrees
- **Remotes** - Same remote configuration
- **Hooks** - Shared hooks

### Independent Working Directories

Each worktree has its own:

- **Working files** - Different file states
- **Index/staging** - Independent staging areas
- **HEAD** - Points to different branches
- **Untracked files** - Isolated per worktree

## Workflow Patterns

### Pattern 1: Parallel Feature Development

Working on multiple features simultaneously:

```bash
# Main repo stays on main for reference
cd ~/Git/myrepo
git checkout main

# Create worktree for feature A
worktree-helper.sh add feature/user-auth
# Opens: ~/Git/myrepo-feature-user-auth/

# Create worktree for feature B
worktree-helper.sh add feature/api-v2
# Opens: ~/Git/myrepo-feature-api-v2/

# Work on each in separate terminals/editors
```

### Pattern 2: Quick Bug Fix During Feature Work

Interrupt feature work for urgent bug:

```bash
# Currently in feature worktree
pwd  # ~/Git/myrepo-feature-auth/

# Create worktree for hotfix (don't leave feature)
worktree-helper.sh add hotfix/security-patch

# Open new terminal
cd ~/Git/myrepo-hotfix-security-patch/
# Fix bug, commit, push, PR

# Return to feature work - nothing changed
cd ~/Git/myrepo-feature-auth/
```

### Pattern 3: Code Review While Developing

Review PR without losing your work:

```bash
# Currently working on feature
pwd  # ~/Git/myrepo-feature-auth/

# Create worktree for PR review
git fetch origin
worktree-helper.sh add pr-123-review origin/feature/other-feature

# Review in separate directory
cd ~/Git/myrepo-pr-123-review/
# Review, test, comment

# Clean up after review
worktree-helper.sh remove pr-123-review
```

### Pattern 4: Multiple AI Sessions

Each OpenCode/Claude session in its own worktree:

```bash
# Session 1: Main development
opencode ~/Git/myrepo-feature-auth/

# Session 2: Bug investigation
opencode ~/Git/myrepo-bugfix-login/

# Session 3: Documentation
opencode ~/Git/myrepo-chore-docs/
```

Each AI session has full context of its branch without conflicts.

## Commands Reference

### Create Worktree

```bash
# Auto-generate path from branch name
worktree-helper.sh add feature/my-feature
# Creates: ~/Git/{repo}-feature-my-feature/

# Specify custom path
worktree-helper.sh add feature/my-feature ~/Projects/my-feature

# Create worktree for new branch (branch created automatically)
worktree-helper.sh add feature/new-feature

# Create worktree for existing branch
worktree-helper.sh add bugfix/existing-bug
```

### List Worktrees

```bash
worktree-helper.sh list

# Output:
# Git Worktrees:
#
#   main
#     /Users/you/Git/myrepo
#
#   feature/auth (merged)
#     /Users/you/Git/myrepo-feature-auth
#
#   bugfix/login ← current
#     /Users/you/Git/myrepo-bugfix-login
```

### Remove Worktree

```bash
# By path
worktree-helper.sh remove ~/Git/myrepo-feature-auth

# By branch name
worktree-helper.sh remove feature/auth

# Note: This removes the directory, NOT the branch
# To also delete the branch:
git branch -d feature/auth
```

### Clean Up Merged Worktrees

```bash
worktree-helper.sh clean

# Finds worktrees for branches merged into main
# Prompts before removing
```

### Check Status

```bash
worktree-helper.sh status

# Output:
# Current Worktree Status:
#
#   Repository: myrepo
#   Branch:     feature/auth
#   Path:       /Users/you/Git/myrepo-feature-auth
#   Type:       Linked worktree
#
#   Total worktrees: 3
```

## Integration with aidevops

### Pre-Edit Check Awareness

The `pre-edit-check.sh` script works in any worktree:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
# Works correctly whether in main or linked worktree
```

### Session Naming

When using OpenCode with worktrees, session names auto-sync:

```bash
# In ~/Git/myrepo-feature-auth/
# Session name: myrepo/feature/auth

# In ~/Git/myrepo-bugfix-login/
# Session name: myrepo/bugfix/login
```

### Terminal Tab Titles

Terminal tabs show repo/branch context:

```text
Tab 1: myrepo/main
Tab 2: myrepo/feature/auth
Tab 3: myrepo/bugfix/login
```

### Session Recovery

Find OpenCode sessions associated with worktrees:

```bash
# List worktrees with likely matching sessions
~/.aidevops/agents/scripts/worktree-sessions.sh list

# Interactive: select worktree and open in OpenCode
~/.aidevops/agents/scripts/worktree-sessions.sh open
```

**How session matching works**:

Sessions are scored based on:
- **+100 pts**: Exact branch name in session title
- **+80 pts**: Branch slug (e.g., `feature-auth`) in title
- **+60 pts**: Branch name without type prefix in title
- **+20 pts**: Each key term from branch name found in title
- **+40 pts**: Session created within 1 hour of branch creation
- **+20 pts**: Session created within 4 hours of branch creation

**Confidence levels**:
- **High (80+)**: Very likely the correct session
- **Medium (40-79)**: Probably related
- **Low (<40)**: Possible match

**Best practice**: Always use `session-rename_sync_branch` tool after creating branches. This syncs the session name with the branch name, making future lookups reliable.

## Best Practices

### 1. ALWAYS Keep Main Repo on Main (Critical)

```bash
# Main repo directory MUST stay on main branch
~/Git/myrepo/  → main branch ONLY (never checkout feature branches here)

# All feature work in linked worktrees
~/Git/myrepo-feature-*/  → feature branches
```

**Why this is critical**: If the main repo is left on a feature branch:
- Next session inherits wrong branch state
- Uncommitted changes block branch switches
- "Your local changes would be overwritten" errors occur
- Parallel workflow assumptions break

**Never use `git checkout -b` in the main repo directory.** Always use worktrees.

### 2. Name Worktrees Consistently

The helper auto-generates paths:

```text
Branch: feature/user-auth
Path:   ~/Git/{repo}-feature-user-auth/

Branch: bugfix/login-timeout
Path:   ~/Git/{repo}-bugfix-login-timeout/
```

### 3. Clean Up After Merging

```bash
# After PR merged
worktree-helper.sh remove feature/completed
git branch -d feature/completed

# Or batch cleanup
worktree-helper.sh clean
```

### Squash Merge Detection

The `clean` command detects merged branches two ways:

1. **Traditional merges**: Uses `git branch --merged`
2. **Squash merges**: Checks if remote branch was deleted after PR merge

The command runs `git fetch --prune` automatically to detect deleted remote branches.

**Manual cleanup** if needed:

```bash
# Force remove worktree
git worktree remove --force ~/Git/myrepo-feature-old

# Delete local branch
git branch -D feature/old
```

### 4. Don't Checkout Same Branch in Multiple Worktrees

Git prevents this - each branch can only be checked out in one worktree:

```bash
worktree-helper.sh add feature/auth
# Creates worktree

worktree-helper.sh add feature/auth
# Error: branch already checked out in another worktree
```

## Troubleshooting

### "Branch is already checked out"

```bash
# Find where branch is checked out
git worktree list | grep feature/auth

# Either use that worktree or remove it first
worktree-helper.sh remove feature/auth
```

### "Worktree path already exists"

```bash
# Directory exists but isn't a worktree
rm -rf ~/Git/myrepo-feature-auth  # If safe to delete
worktree-helper.sh add feature/auth
```

### Stale Worktree References

```bash
# If worktree directory was deleted manually
git worktree prune

# Then recreate if needed
worktree-helper.sh add feature/auth
```

### Worktree in Detached HEAD

```bash
# Check status
cd ~/Git/myrepo-feature-auth
git status  # Shows detached HEAD

# Reattach to branch
git checkout feature/auth
```

### Worktree Deleted Mid-Session

If a worktree directory is removed (e.g., PR closed, manual deletion, cleanup script):

```bash
# 1. Check if branch still exists locally
git branch --list feature/my-feature

# 2. If branch exists, recreate worktree
worktree-helper.sh add feature/my-feature

# 3. If branch was deleted remotely but you have local changes
git fetch origin
git checkout -b feature/my-feature origin/feature/my-feature 2>/dev/null || \
  git checkout -b feature/my-feature
worktree-helper.sh add feature/my-feature

# 4. Restore uncommitted changes from stash (if any were saved)
git stash list
git stash pop
```

**Session continuity**: After recreating the worktree, use `session-rename_sync_branch` tool to re-sync the OpenCode session name with the branch.

**Prevention**: Before closing a PR or deleting a branch, ensure no active sessions are using that worktree. Use `worktree-sessions.sh list` to check.

## Comparison: Worktrees vs Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **Worktrees** | Shared history, disk efficient, native git | Learning curve |
| **Multiple clones** | Simple, fully isolated | Disk heavy, history not shared |
| **Stashing** | Quick, no extra directories | Easy to lose work, context switching |
| **Branch switching** | Simple | Affects all sessions |

## Related Workflows

| Workflow | When to Read |
|----------|--------------|
| `git-workflow.md` | Branch naming, commit conventions |
| `branch.md` | Branch type selection |
| `multi-repo-workspace.md` | Multiple repositories |
| `pr.md` | Pull request creation |
