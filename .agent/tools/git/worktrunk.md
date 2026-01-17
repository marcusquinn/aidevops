---
description: Worktrunk (wt) - Git worktree management for parallel AI agent workflows
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

# Worktrunk Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI Tool**: `wt` (Worktrunk) - Git worktree management for parallel AI workflows
- **Install**: `brew install max-sixty/worktrunk/wt` (macOS/Linux) | `cargo install worktrunk`
- **Shell Integration**: `wt config shell install` (enables directory switching)
- **Docs**: https://worktrunk.dev

**Core Commands**:

```bash
wt switch feat              # Switch/create worktree (with cd)
wt switch -c feat           # Create new branch + worktree
wt switch -c -x claude feat # Create + start Claude Code
wt list                     # List worktrees with CI status + PR links
wt remove                   # Remove current worktree + branch
wt merge                    # Squash/rebase/merge + cleanup
wt select                   # fzf-like worktree selector
```

**Fallback**: `~/.aidevops/agents/scripts/worktree-helper.sh` (no dependencies)
<!-- AI-CONTEXT-END -->

## Overview

Worktrunk makes git worktrees as easy as branches. It's designed for running multiple AI agents in parallel, each in their own working directory.

**Why Worktrunk over raw git worktree?**

| Task | Worktrunk | Plain git |
|------|-----------|-----------|
| Switch worktrees | `wt switch feat` | `cd ../repo.feat` |
| Create + start Claude | `wt switch -c -x claude feat` | `git worktree add -b feat ../repo.feat && cd ../repo.feat && claude` |
| Clean up | `wt remove` | `cd ../repo && git worktree remove ../repo.feat && git branch -d feat` |
| List with status | `wt list` | `git worktree list` (paths only) |

## Installation

```bash
# Homebrew (macOS & Linux) - recommended
brew install max-sixty/worktrunk/wt && wt config shell install

# Cargo (Rust)
cargo install worktrunk && wt config shell install

# Windows (winget)
winget install max-sixty.worktrunk
git-wt config shell install  # Note: 'wt' conflicts with Windows Terminal
```

**Shell integration is required** for `wt switch` to change directories. Without it, commands only print the path.

## Core Commands

### wt switch - Switch/Create Worktrees

```bash
# Switch to existing worktree (or create if branch exists)
wt switch feature/auth

# Create new branch + worktree
wt switch -c feature/new-thing

# Create + execute command (e.g., start Claude Code)
wt switch -c -x claude feature/ai-task
wt switch -c -x "npm install" feature/setup
```

### wt list - List Worktrees

```bash
wt list

# Output includes:
# - Branch name
# - Path
# - CI status (if GitHub Actions configured)
# - PR link (if PR exists)
# - Dirty/clean status
```

### wt remove - Remove Worktree

```bash
# Remove current worktree (prompts for confirmation)
wt remove

# Remove specific worktree
wt remove feature/old-thing

# Force remove (skip confirmation)
wt remove -f feature/old-thing
```

### wt merge - Merge Workflow

```bash
# Interactive merge (choose squash/rebase/merge)
wt merge

# Squash merge directly
wt merge --squash

# Rebase merge
wt merge --rebase
```

After merge, worktrunk:
1. Switches to main/master
2. Pulls latest changes
3. Removes the worktree
4. Deletes the local branch

### wt select - Interactive Selector

```bash
# fzf-like selector for worktrees
wt select
```

## Hooks

Worktrunk supports hooks for automated setup. Create `.worktrunk/hooks/` in your repo:

```bash
# .worktrunk/hooks/post-create
#!/bin/bash
# Runs after creating a new worktree
npm install
```

Available hooks:
- `post-create` - After worktree creation
- `pre-merge` - Before merge
- `post-merge` - After merge
- `pre-remove` - Before removal

## Configuration

```bash
# View current config
wt config show

# Set path template (default: ../repo.branch)
wt config set path_template "../{repo}.{branch}"

# Set default merge strategy
wt config set merge_strategy squash
```

## LLM Commit Messages

Worktrunk integrates with [llm](https://llm.datasette.io/) for AI-generated commit messages:

```bash
# Install llm
pip install llm

# Configure (uses your default LLM)
wt config set llm_commits true

# Now commits auto-generate messages from diffs
git add .
wt commit  # Generates message via LLM
```

## Integration with aidevops

### Recommended Workflow

1. **Use `wt` as primary tool** when installed
2. **Fall back to `worktree-helper.sh`** if wt unavailable

```bash
# Check if wt is available
if command -v wt &>/dev/null; then
    wt switch -c feature/my-feature
else
    ~/.aidevops/agents/scripts/worktree-helper.sh add feature/my-feature
    cd ~/Git/repo-feature-my-feature
fi
```

### Pre-Edit Check Integration

The `pre-edit-check.sh` script works with both tools:
- Detects if on protected branch
- Suggests worktree creation
- In loop mode, auto-creates worktree

### Session Naming

After creating a worktree, sync the session name:
```bash
# Claude Code MCP tool
session-rename_sync_branch
```

## Comparison: Worktrunk vs worktree-helper.sh

| Feature | Worktrunk (`wt`) | worktree-helper.sh |
|---------|------------------|-------------------|
| Shell integration | Built-in (cd support) | Prints path only |
| Hooks | Yes (post-create, etc.) | No |
| CI status | Yes (in `wt list`) | No |
| PR links | Yes (in `wt list`) | No |
| Merge workflow | `wt merge` (squash/rebase) | Manual |
| LLM commits | Yes (via llm) | No |
| Dependencies | Rust binary | Bash only |
| Installation | brew/cargo/winget | Already deployed |

**Recommendation**: Use Worktrunk when available for better UX. Use worktree-helper.sh as fallback or in minimal environments.

## Troubleshooting

### "wt: command not found"

Shell integration not installed:
```bash
wt config shell install
source ~/.zshrc  # or ~/.bashrc
```

### "Branch already checked out"

Each branch can only be in one worktree:
```bash
wt list  # Find where branch is checked out
wt remove feature/auth  # Remove if not needed
```

### Windows: "wt" opens Windows Terminal

On Windows, `wt` is aliased to Windows Terminal. Use `git-wt` instead:
```bash
git-wt switch feature/auth
```

Or disable the Windows Terminal alias in Settings.

## Related

- `workflows/worktree.md` - Full worktree workflow documentation
- `workflows/git-workflow.md` - Branch naming and conventions
- `scripts/worktree-helper.sh` - Fallback bash implementation
- https://worktrunk.dev - Official documentation
