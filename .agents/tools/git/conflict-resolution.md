---
description: Git merge, rebase, and cherry-pick conflict resolution strategies and workflows
mode: subagent
tools:
  read: true
  write: false
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Git Conflict Resolution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommended config**: `git config --global merge.conflictstyle diff3` + `git config --global rerere.enabled true`
- **Conflict markers**: `<<<<<<<` (ours), `|||||||` (base, with diff3), `=======`, `>>>>>>>` (theirs)
- **Key commands**: `git merge --abort`, `git checkout --ours/--theirs <file>`, `git log --merge -p`

**Decision Tree** -- when you hit a conflict:

```text
Conflict detected
  |
  +-- Can you abort safely?
  |     YES --> git merge/rebase/cherry-pick --abort
  |     NO  --> continue below
  |
  +-- Is it a single file, clear which side wins?
  |     YES --> git checkout --ours/--theirs <file> && git add <file>
  |     NO  --> continue below
  |
  +-- Is it a code conflict needing both changes?
  |     YES --> Edit file manually, combine both intents, git add <file>
  |     NO  --> continue below
  |
  +-- Is it a binary or lock file?
        YES --> git checkout --ours/--theirs <file> && git add <file>
               (then regenerate lock file if needed)
```

**Quick resolution commands**:

```bash
git status                          # see conflicted files
git diff                            # see conflict details
git log --merge -p                  # commits touching conflicted files
git checkout --conflict=diff3 <f>   # re-show markers with base version
git checkout --ours <file>          # take our version
git checkout --theirs <file>        # take their version
git add <file>                      # mark as resolved
git merge --continue                # finish merge (or rebase/cherry-pick --continue)
```

<!-- AI-CONTEXT-END -->

## Understanding Conflict Markers

When git cannot auto-merge, it inserts markers into the file:

```text
<<<<<<< HEAD (or ours)
Your changes
||||||| base (only with diff3 conflictstyle)
Original version before either change
=======
Their changes
>>>>>>> branch-name (or theirs)
```

The `diff3` style (showing the base) is critical for understanding intent. Without it, you only see two versions and must guess what the original looked like.

**Enable diff3 globally** (strongly recommended):

```bash
git config --global merge.conflictstyle diff3
```

To re-generate markers with diff3 on an already-conflicted file:

```bash
git checkout --conflict=diff3 <file>
```

## Resolution Strategies

### Strategy options for merge (`-X`)

| Option | Effect | When to use |
|--------|--------|-------------|
| `-Xours` | Our side wins on conflicts (non-conflicting theirs still merges) | Your branch is authoritative |
| `-Xtheirs` | Their side wins on conflicts | Accepting incoming as authoritative |
| `-Xignore-space-change` | Treat whitespace-only changes as identical | Mixed line endings, reformatting |
| `-Xpatience` | Use patience diff algorithm | Better alignment when matching lines cause misalignment |

**Important**: `-Xours` (strategy option) is different from `-s ours` (strategy). The strategy discards the other branch entirely. The option only resolves conflicts in your favor while still merging non-conflicting changes.

### Per-file resolution

```bash
# Take one side entirely for a specific file
git checkout --ours <file>          # keep your version
git checkout --theirs <file>        # keep their version
git add <file>

# Manual 3-way merge (extract all versions)
git show :1:<file> > file.base      # common ancestor
git show :2:<file> > file.ours      # our version
git show :3:<file> > file.theirs    # their version
git merge-file -p file.ours file.base file.theirs > <file>
```

### Investigating conflicts

```bash
# Show only commits that touch conflicted files
git log --merge -p

# See which commits are on which side
git log --left-right HEAD...MERGE_HEAD

# Compare merge result against each side
git diff --ours                     # vs our version
git diff --theirs                   # vs their version
git diff --base                     # vs common ancestor

# List all unmerged files with stage numbers
git ls-files -u
```

## Scenario-Specific Workflows

### Merge conflicts (`git merge main`)

```bash
git merge main
# If conflicts:
git status                          # identify conflicted files
git diff                            # review conflicts
# Edit files to resolve, then:
git add <resolved-files>
git merge --continue
# Or abort:
git merge --abort
```

### Rebase conflicts (`git rebase main`)

Rebase replays commits one at a time, so you may resolve multiple conflicts:

```bash
git rebase main
# For each conflicted commit:
git status                          # see conflicts
# Resolve, then:
git add <resolved-files>
git rebase --continue               # move to next commit
# Or skip this commit:
git rebase --skip
# Or abort entirely:
git rebase --abort
```

### Cherry-pick conflicts

```bash
git cherry-pick <commit>
# If conflicts:
git status
# Resolve, then:
git add <resolved-files>
git cherry-pick --continue
# Or abort:
git cherry-pick --abort
```

Useful cherry-pick flags:

| Flag | Purpose |
|------|---------|
| `--no-commit` (`-n`) | Apply without committing (inspect first) |
| `-x` | Append "(cherry picked from ...)" to message |
| `-m 1` | Cherry-pick a merge commit (specify mainline parent) |
| `--strategy-option=theirs` | Their side wins on conflicts |

### Stash pop conflicts

```bash
git stash pop
# If conflicts:
git status
# Resolve, then:
git add <resolved-files>
# Note: stash is NOT dropped on conflict. After resolving:
git stash drop
```

## Common Conflict Patterns

### Both sides modified the same function

Use `git log --merge -p` to understand what each side changed. Read the base version (with diff3), understand both intents, combine manually.

### File renamed on one side, modified on the other

Git's `ort` strategy detects renames automatically. If it fails:

```bash
git merge -Xfind-renames=30 <branch>   # lower threshold = more aggressive detection
```

### File deleted on one side, modified on the other

Git reports `CONFLICT (modify/delete)`:

```bash
git add <file>      # keep the modified version
git rm <file>       # accept the deletion
```

### Both sides added a file with the same name (add/add)

```bash
git checkout --ours <file>      # or --theirs
git add <file>
```

### Lock files (package-lock.json, yarn.lock, pnpm-lock.yaml)

Never manually merge lock files. Choose one side and regenerate:

```bash
git checkout --theirs package-lock.json   # or --ours
npm install                                # regenerate
git add package-lock.json
```

For npm, you can also use `.gitattributes`:

```text
package-lock.json merge=ours
```

### Binary files

Git cannot merge binary files:

```bash
git checkout --ours <file>      # or --theirs
git add <file>
```

## git rerere (Reuse Recorded Resolution)

Rerere records how you resolve conflicts and auto-applies the same resolution next time.

### Setup

```bash
git config --global rerere.enabled true
```

### How it works

1. On conflict, rerere saves the **preimage** (conflict markers)
2. After you resolve and commit, it saves the **postimage** (your resolution)
3. Next time the same conflict occurs, it auto-applies your resolution to the working tree
4. You still need to `git add` and verify -- rerere does not auto-stage

### Commands

```bash
git rerere status               # files with recorded preimages
git rerere diff                 # current state vs recorded resolution
git rerere remaining            # files still unresolved
git rerere forget <path>        # delete a bad recorded resolution
git rerere gc                   # prune old records
```

### GC configuration

```bash
git config gc.rerereUnresolved 15   # days to keep unresolved (default 15)
git config gc.rerereResolved 60     # days to keep resolved (default 60)
```

### Best use cases

- Long-lived topic branches repeatedly rebased against main
- Test merges: merge to test, `reset --hard HEAD^`, later rebase -- rerere remembers
- Integration branches merging many topic branches for CI

### Safety

```bash
# Review rerere's auto-resolution before staging
git cherry-pick --no-rerere-autoupdate <commit>
git rerere diff                 # inspect what rerere did
git add .                       # stage only if satisfied
```

## AI-Assisted Conflict Resolution

When using AI coding tools to resolve conflicts:

1. **Enable diff3** -- gives the AI the base version for reasoning about intent
2. **Provide context** -- run `git log --merge -p` and share the output
3. **Review carefully** -- AI may not understand project conventions, build implications, or runtime behavior

AI works well for:
- Code conflicts where both sides add different features
- Import/export statement conflicts
- Configuration file conflicts

AI needs human review for:
- Generated files (schemas, lock files) -- regenerate instead
- Database migrations -- ordering matters
- Security-sensitive code

## Prevention

### Recommended git configuration

```bash
git config --global merge.conflictstyle diff3
git config --global rerere.enabled true
git config --global pull.rebase true
git config --global diff.algorithm histogram
```

### Workflow practices

| Practice | Effect |
|----------|--------|
| Frequent integration | Merge/rebase from main often -- small conflicts early |
| Small PRs | Fewer files changed = fewer conflicts |
| Rebase before PR | `git rebase main` surfaces conflicts in your branch |
| Worktrees | Parallel work without stash conflicts (see `tools/git/worktrunk.md`) |
| Feature flags | Ship disabled features to main early -- avoid long-lived branches |

## Error Recovery

```bash
# Abort any in-progress operation
git merge --abort
git rebase --abort
git cherry-pick --abort

# Undo a completed merge (before push)
git reset --hard HEAD^

# Undo a completed merge (after push) -- creates a revert commit
git revert -m 1 <merge-commit>

# Find lost commits after a bad reset
git reflog
git checkout <lost-commit-sha>
```

## Related

- `tools/git/worktrunk.md` -- Worktree management (conflict prevention)
- `workflows/git-workflow.md` -- Branch-first development
- `workflows/pr.md` -- PR creation and merge
- `workflows/branch.md` -- Branch management
- `workflows/branch/release.md` -- Cherry-pick for releases
