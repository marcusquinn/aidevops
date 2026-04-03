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

# Jujutsu (jj) Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `jj` — Git-compatible VCS, written in Rust
- **Install**: `brew install jj` (macOS) | `cargo install jj-cli` (all platforms)
- **Repo**: <https://github.com/jj-vcs/jj> (25k+ stars, Apache-2.0)
- **Docs**: <https://docs.jj-vcs.dev/latest/>
- **Status**: Experimental; Git backend stable, daily-driven by core team

## Key Advantages Over Git

| Feature | How it works |
|---------|-------------|
| **Working-copy-as-commit** | File changes auto-recorded; no staging area. Snapshots before every command — no dirty-directory errors, no `git stash`. Message anytime: `jj describe`. |
| **Operation log + undo** | `jj op log` shows full history; `jj undo` reverses last op; `jj op restore <id>` restores any state. |
| **First-class conflicts** | Conflicts stored in commits, not blocking errors. Resolve later; resolutions propagate to descendants (subsumes `git rerere`). |
| **Auto-rebase descendants** | Modifying any commit rebases all descendants in place. Equivalent to transparent `git rebase --update-refs`. |
| **Anonymous branches** | All visible heads tracked — commits never lost while reachable. Named bookmarks only needed for remotes. |

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

## Benefits for AI-Assisted Development

- **No staging friction** — file writes auto-commit; no `git add` errors
- **Safe experimentation** — `jj undo` reverses any op instantly; agents try and roll back freely
- **Parallel agent conflicts** — overlapping edits produce committed conflicts, not blocking errors
- **Simpler mental model** — one object type (commits) vs git's working tree + index + HEAD + stash
- **Audit trail** — `jj op log` provides complete operation history for headless workflow debugging

## aidevops Worktree Integration

Colocated mode (`jj init --git-repo=.`) works with `wt` (Worktrunk) worktrees. `jj git push` replaces `git push` using the same remotes; bookmarks map directly to git branches. Team members can continue using git unchanged.

**See also**: `tools/git/github-cli.md` (PR/remote workflows), `tools/git/conflict-resolution.md` (conflict strategies), `tools/git/worktrunk.md` (worktree management)

## Resources

- [Tutorial](https://docs.jj-vcs.dev/latest/tutorial/)
- [Git comparison & command table](https://docs.jj-vcs.dev/latest/git-comparison/)
- [Steve Klabnik's Jujutsu Tutorial](https://steveklabnik.github.io/jujutsu-tutorial/)
- [Chris Krycho's jj init essay](https://v5.chriskrycho.com/essays/jj-init/)

<!-- AI-CONTEXT-END -->
