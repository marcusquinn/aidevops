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
- **Fallback**: `~/.aidevops/agents/scripts/worktree-helper.sh` (no dependencies)

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

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Homebrew (macOS & Linux) - recommended
brew install max-sixty/worktrunk/wt && wt config shell install

# Cargo (Rust)
cargo install worktrunk && wt config shell install

# Windows (winget) — 'wt' conflicts with Windows Terminal, use 'git-wt'
winget install max-sixty.worktrunk
git-wt config shell install
```

**Shell integration is required** for `wt switch` to change directories. Without it, commands only print the path.

## Commands

### wt switch

```bash
wt switch feature/auth              # Switch to existing (or create if branch exists)
wt switch -c feature/new-thing      # Create new branch + worktree
wt switch -c -x claude feature/task # Create + execute command (e.g., start Claude Code)
wt switch -c -x "npm install" feature/setup
```

### wt list

Shows branch name, path, CI status, PR link, and dirty/clean status.

### wt remove

```bash
wt remove                       # Remove current worktree (prompts confirmation)
wt remove feature/old-thing     # Remove specific worktree
wt remove -f feature/old-thing  # Force (skip confirmation)
```

### wt merge

```bash
wt merge           # Interactive (choose squash/rebase/merge)
wt merge --squash  # Squash merge directly
wt merge --rebase  # Rebase merge
```

After merge, Worktrunk: switches to main/master, pulls latest, removes the worktree, deletes the local branch.

### wt select

Interactive fzf-like worktree selector.

## Hooks

Create `.worktrunk/hooks/` in your repo. Available hooks: `post-create`, `pre-merge`, `post-merge`, `pre-remove`.

```bash
# .worktrunk/hooks/post-create
#!/bin/bash
npm install
```

### Localdev Hooks (t1224.8)

Route creation is automatic with `worktree-helper.sh` but requires explicit hooks for Worktrunk. **Route removal is only automatic with `worktree-helper.sh`** — Worktrunk users must add a `pre-remove` hook.

```bash
# .worktrunk/hooks/post-create — add to your project repo
#!/bin/bash
branch="$(git branch --show-current)"
project="$(basename "$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)")"
LOCALDEV_HELPER="${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/scripts/localdev-helper.sh"
"$LOCALDEV_HELPER" branch "$project" "$branch" 2>/dev/null || true
```

```bash
# .worktrunk/hooks/pre-remove — add to your project repo
#!/bin/bash
branch="$(git branch --show-current)"
project="$(basename "$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)")"
LOCALDEV_HELPER="${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/scripts/localdev-helper.sh"
"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>/dev/null || true
```

## Configuration

```bash
wt config show                                    # View current config
wt config set path_template "../{repo}.{branch}"  # Path template (default: ../repo.branch)
wt config set merge_strategy squash               # Default merge strategy
```

## LLM Commit Messages

Integrates with [llm](https://llm.datasette.io/) for AI-generated commit messages:

```bash
pip install llm
wt config set llm_commits true
git add . && wt commit  # Generates message via LLM from diff
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `wt: command not found` | `wt config shell install && source ~/.zshrc` |
| "Branch already checked out" | `wt list` to find it, `wt remove` if not needed |
| Windows: `wt` opens Terminal | Use `git-wt` instead, or disable the Windows Terminal alias |

## Related

- `workflows/worktree.md` — Full worktree workflow, comparison table, integration patterns
- `workflows/git-workflow.md` — Branch naming and conventions
- `scripts/worktree-helper.sh` — Fallback bash implementation
- https://worktrunk.dev — Official documentation
