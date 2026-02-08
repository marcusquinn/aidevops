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

- **CLI**: `jj` (Jujutsu) - Git-compatible VCS, written in Rust
- **Install**: `brew install jj` (macOS) | `cargo install jj-cli` (all platforms)
- **Repo**: <https://github.com/jj-vcs/jj> (25k+ stars, Apache-2.0)
- **Docs**: <https://docs.jj-vcs.dev/latest/>
- **Status**: Experimental but daily-driven by core team; Git backend is stable

## Key Advantages Over Git

### Working-Copy-as-Commit

Every file change is automatically recorded as a commit. No staging area, no index.
`jj` snapshots the working copy before every command - eliminates "dirty working
directory" errors, removes the need for `git stash`, and lets you set commit messages
anytime with `jj describe`.

### Operation Log with Undo

Every repository operation is recorded. `jj op log` shows history, `jj undo` reverses
the last operation, `jj op restore <op-id>` restores any previous state.

### First-Class Conflicts

Conflicts are stored in commits, not as blocking errors. No command fails due to
conflicts. Resolve them later at your convenience. Conflict resolutions propagate
automatically to descendant commits, subsuming most `git rerere` use cases.

### Automatic Rebase of Descendants

Modifying any commit automatically rebases all descendants. Edit a parent and children
update in place. Equivalent to transparent `git rebase --update-refs`. Bookmark
(branch) pointers update automatically.

### Anonymous Branches

No need to name every branch. Jujutsu tracks all visible heads of the commit graph.
Commits are never lost while reachable. Use bookmarks (named branches) only when
pushing to remotes.

## Essential Commands

```bash
# Repository setup
jj git init                  # New jj repo with git backend
jj git clone <url>           # Clone a git remote
jj init --git-repo=.         # Colocate: add jj to existing git repo

# Daily workflow
jj new                       # Start a new change on top of current
jj describe -m "message"     # Set/update commit message
jj diff                      # Show changes in working copy
jj log                       # Show commit graph (rich template output)
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

## Colocated Mode (Gradual Adoption)

Run `jj init --git-repo=.` in any existing git repo to use both tools side by side.
Creates `.jj/` alongside `.git/` - both `jj` and `git` commands work in the same repo,
reading/writing the same Git objects and refs. Team members continue using git while
you use jj. Low-risk way to evaluate on real projects.

## Benefits for AI-Assisted Development

- **No staging friction**: File writes are automatically part of the working-copy
  commit. No `git add` needed - eliminates a common source of agent errors.
- **Safe experimentation**: `jj undo` reverses any operation instantly. Agents can
  try approaches and roll back without risk of lost work.
- **Parallel agent conflicts**: Multiple agents modifying overlapping files produce
  committed conflicts rather than blocking errors. Resolve asynchronously.
- **Simpler mental model**: One object type (commits) vs Git's working tree + index +
  HEAD + stash. Fewer concepts means fewer agent mistakes.
- **Audit trail**: `jj op log` provides complete operation history for debugging
  autonomous agent actions in headless workflows.

## Integration with aidevops Worktree Workflow

Colocated mode works alongside `wt` (Worktrunk) worktree workflows. Worktrees created
by `wt switch -c` are standard git worktrees; colocate each with `jj init --git-repo=.`
if desired. `jj git push` replaces `git push` using the same remotes. Bookmarks map
directly to git branches.

**See also**: `tools/git/github-cli.md` (PR and remote workflows),
`tools/git/conflict-resolution.md` (git conflict strategies),
`tools/git/worktrunk.md` (worktree management)

## Resources

- [Tutorial](https://docs.jj-vcs.dev/latest/tutorial/)
- [Git comparison & command table](https://docs.jj-vcs.dev/latest/git-comparison/)
- [Steve Klabnik's Jujutsu Tutorial](https://steveklabnik.github.io/jujutsu-tutorial/)
- [Chris Krycho's jj init essay](https://v5.chriskrycho.com/essays/jj-init/)

<!-- AI-CONTEXT-END -->
