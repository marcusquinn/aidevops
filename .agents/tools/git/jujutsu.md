---
description: Jujutsu (jj) - Git-compatible VCS with working-copy-as-commit, undo, and first-class conflicts
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Jujutsu (jj) Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `jj` — Git-compatible VCS, written in Rust
- **Install**: `brew install jj` (macOS) | `cargo install jj-cli` (all platforms)
- **Repo**: <https://github.com/jj-vcs/jj> (25k+ stars, Apache-2.0)
- **Docs**: <https://docs.jj-vcs.dev/latest/>
- **Status**: Experimental; Git backend stable, daily-driven by core team

## Key Advantages

| Feature | Behaviour | Agent benefit |
|---------|-----------|--------------|
| **Working-copy-as-commit** | File changes auto-recorded; no staging area; `jj describe` sets message anytime. | No `git add` errors; file writes auto-commit |
| **Operation log + undo** | `jj op log` full history; `jj undo` reverses last op; `jj op restore <id>` any state. | Safe rollback; complete audit trail |
| **First-class conflicts** | Conflicts stored in commits, not blocking errors; resolutions propagate to descendants (subsumes `git rerere`). | Overlapping edits produce committed conflicts, not blocking errors |
| **Auto-rebase descendants** | Modifying any commit rebases all descendants in place. | Simpler object model vs git's working tree + index + HEAD + stash |
| **Anonymous branches** | All visible heads tracked — commits never lost; named bookmarks only needed for remotes. | Safe experimentation without branch management overhead |

## Essential Commands

```bash
# Repository setup
jj git init                  # New jj repo with git backend
jj git clone <url>           # Clone a git remote
jj init --git-repo=.         # Colocate: add jj to existing git repo (creates .jj/ alongside .git/)

# Daily workflow
jj new                       # Start a new change on top of current
jj describe -m "message"     # Set/update commit message
jj diff                      # Show changes in working copy
jj log                       # Show commit graph
jj status                    # Show working copy status

# Rewriting history
jj squash                    # Move working copy changes into parent
jj split                     # Split working copy commit into two
jj edit <rev>                # Edit an earlier commit (descendants auto-rebase)
jj rebase -r <rev> -d <dst>  # Rebase a single commit
jj rebase -s <rev> -d <dst>  # Rebase commit and descendants

# Git interop
jj git fetch                 # Fetch from git remotes
jj git push                  # Push bookmarks to git remote
jj bookmark set main         # Set a bookmark (branch) on current commit
```

## aidevops Worktree Integration

Colocated mode (`jj init --git-repo=.`) works with `wt` worktrees. `jj git push` replaces `git push`; bookmarks map to git branches. Team members can continue using git unchanged.

**See also**: `tools/git/github-cli.md` (PR/remote workflows), `tools/git/conflict-resolution.md` (conflict strategies), `tools/git/worktrunk.md` (worktree management)

## Resources

- [Official docs & tutorial](https://docs.jj-vcs.dev/latest/tutorial/)
- [Git comparison & command table](https://docs.jj-vcs.dev/latest/git-comparison/)

<!-- AI-CONTEXT-END -->
