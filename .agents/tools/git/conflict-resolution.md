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

- **Recommended config**: `git config --global merge.conflictstyle diff3` (or zdiff3 on Git 2.35+) + `git config --global rerere.enabled true`
- **Conflict markers**: `<<<<<<<` (ours), `|||||||` (base, with diff3), `=======`, `>>>>>>>` (theirs)
- **Strategy options**: `-Xours` (our side wins conflicts), `-Xtheirs` (their side wins), `-Xignore-space-change`
- **Resolution rules**: Diff is truth, surgical resolution, structure vs values, check migrations, escalate ambiguity

**Decision Tree** — when you hit a conflict:

```text
Conflict detected
  |
  +-- Can you abort safely?
  |     YES --> git merge/rebase/cherry-pick --abort
  |
  +-- Single file, clear which side wins?
  |     YES --> git checkout --ours/--theirs <file> && git add <file>
  |
  +-- Code conflict needing both changes?
  |     YES --> Edit file manually, combine both intents, git add <file>
  |
  +-- Binary or lock file?
        YES --> git checkout --ours/--theirs <file> && git add <file>
               (regenerate lock file if needed)
```

**Quick commands**:

```bash
git status                          # see conflicted files
git diff                            # see conflict details
git log --merge -p                  # commits touching conflicted files
git log --left-right HEAD...MERGE_HEAD  # commits on each side
git diff --ours/--theirs/--base     # compare vs each side
git ls-files -u                     # list unmerged files with stage numbers
git checkout --conflict=diff3 <f>   # re-show markers with base version
git checkout --ours <file>          # take our version
git checkout --theirs <file>        # take their version
git add <file>                      # mark as resolved
git merge --continue                # finish merge (or rebase/cherry-pick --continue)
```

<!-- AI-CONTEXT-END -->

## Conflict Markers

```text
<<<<<<< HEAD (or ours)
Your changes
||||||| base (only with diff3 conflictstyle)
Original version before either change
=======
Their changes
>>>>>>> branch-name (or theirs)
```

The `diff3` style (showing the base) is critical for understanding intent. Without it, you only see two versions and must guess the original. Git 2.35+ supports `zdiff3`, which produces shorter markers by removing common prefix/suffix lines.

```bash
git config --global merge.conflictstyle diff3   # enable globally (strongly recommended)
git checkout --conflict=diff3 <file>            # re-generate markers on already-conflicted file
```

## Resolution Strategies

### Strategy options (`-X`)

| Option                  | Effect                                                           | When to use                                             |
| ----------------------- | ---------------------------------------------------------------- | ------------------------------------------------------- |
| `-Xours`                | Our side wins on conflicts (non-conflicting theirs still merges) | Your branch is authoritative                            |
| `-Xtheirs`              | Their side wins on conflicts                                     | Accepting incoming as authoritative                     |
| `-Xignore-space-change` | Treat whitespace-only changes as identical                       | Mixed line endings, reformatting                        |
| `-Xpatience`            | Use patience diff algorithm                                      | Better alignment when matching lines cause misalignment |

**Important**: `-Xours` (strategy option) differs from `-s ours` (strategy). The strategy discards the other branch entirely; the option only resolves conflicts in your favor while still merging non-conflicting changes.

### Per-file resolution

```bash
git checkout --ours <file>          # keep your version
git checkout --theirs <file>        # keep their version
git add <file>

# Manual 3-way merge (extract all versions)
git show :1:<file> > file.base      # common ancestor
git show :2:<file> > file.ours      # our version
git show :3:<file> > file.theirs    # their version
git merge-file -p file.ours file.base file.theirs > <file>
```

## Scenario Workflows

All scenarios follow the same pattern: resolve → `git add <resolved>` → `--continue` or `--abort`.

### Merge (`git merge main`)

```bash
git merge main
git status && git diff              # identify and review conflicts
# resolve, then:
git add <resolved-files> && git merge --continue
# or: git merge --abort
```

### Rebase (`git rebase main`)

Rebase replays commits one at a time — you may resolve multiple conflicts.

```bash
git rebase main
# for each conflicted commit: resolve, then:
git add <resolved-files> && git rebase --continue
# git rebase --skip   (skip this commit)
# git rebase --abort  (abort entirely)
```

### Cherry-pick

```bash
git cherry-pick <commit>
# resolve, then:
git add <resolved-files> && git cherry-pick --continue
# or: git cherry-pick --abort
```

Cherry-pick flags:

| Flag                       | Purpose                                              |
| -------------------------- | ---------------------------------------------------- |
| `--no-commit` (`-n`)       | Apply without committing (inspect first)             |
| `-x`                       | Append "(cherry picked from ...)" to message         |
| `-m 1`                     | Cherry-pick a merge commit (specify mainline parent) |
| `--strategy-option=theirs` | Their side wins on conflicts                         |

### Stash pop

```bash
git stash pop
# resolve, then:
git add <resolved-files>
git stash drop   # stash is NOT dropped automatically on conflict
```

## Common Conflict Patterns

| Pattern | Resolution |
| ------- | ---------- |
| Both sides modified same function | Use `git log --merge -p` to understand each side's intent; combine manually with diff3 base |
| File renamed on one side, modified on other | Git `ort` strategy (default since 2.34) detects renames; if it fails: `git merge -Xfind-renames=30 <branch>` |
| Modify/delete conflict | `git add <file>` to keep modified version; `git rm <file>` to accept deletion. Check `git log --follow -- <file>` — deleted file may have been renamed/moved |
| Add/add (same filename, both sides) | Per-file resolution: pick one version |
| Lock files (package-lock.json, yarn.lock) | Never manually merge. Pick one side, then regenerate: `npm install && git add package-lock.json` |
| Binary files | Cannot merge. Use per-file resolution to pick one version |

## git rerere (Reuse Recorded Resolution)

Records conflict resolutions and auto-applies them next time the same conflict occurs.

```bash
git config --global rerere.enabled true
```

**How it works**: On conflict, rerere saves the preimage (conflict markers). After you resolve and commit, it saves the postimage. Next time the same conflict occurs, it auto-applies your resolution — but you still need to `git add` and verify.

```bash
git rerere status               # files with recorded preimages
git rerere diff                 # current state vs recorded resolution
git rerere remaining            # files still unresolved
git rerere forget <path>        # delete a bad recorded resolution
git rerere gc                   # prune old records

# GC configuration
git config gc.rerereUnresolved 15   # days to keep unresolved (default 15)
git config gc.rerereResolved 60     # days to keep resolved (default 60)
```

**Best use cases**: long-lived topic branches repeatedly rebased against main; test merges (merge to test, `reset --hard HEAD^`, later rebase); integration branches merging many topic branches for CI.

**Safety**: Use `git cherry-pick --no-rerere-autoupdate <commit>` then `git rerere diff` to inspect before staging.

## Intent-Based Resolution Rules

Before resolving, understand what each side changed: `git log --merge -p`. Check for migrations: `git log --oneline --follow -- <file>`.

1. **Diff is truth** — a conflict block shows ENTIRE content from each side, not just changes. Compare against actual diffs (`git diff --ours`, `git diff --theirs`) to identify which lines were modified vs unchanged context.

2. **Surgical resolution** — resolve only lines actually changed by each side. Never accept an entire conflict block without verifying each line. Unchanged surrounding lines stay as-is.

3. **Structure from one side, values from the other** — when conflicts arise from infrastructure changes (package renames, import paths) on one side and business logic on the other: keep infrastructure from the side that made them, apply business values from the other.

4. **Modify/delete — check for migration** — do NOT blindly accept either side. Check `git log --follow -- <file>` — a deleted file may have been renamed, moved, or refactored. If so, apply modifications to its successor instead.

5. **Custom values win over upstream defaults (rebase)** — when rebasing over upstream, custom values (sizes, colors, copy) take priority over upstream defaults. Upstream provides structure; customizations provide intent.

6. **Clean up after resolution** — remove orphaned imports and unused variables left behind after replacing code from one side.

7. **Escalate ambiguous resolutions** — when not confident, DO NOT guess. Resolve what you can and escalate the rest.

   **Escalate when**: you cannot confidently map a diff change to a specific location (code was refactored/split/reformatted); resolution would require adding content from neither side; you feel the need to modify a file git did not mark as conflicted.

   **Format**:
   ```text
   ESCALATE: <file> | <description of ambiguity> | <options you see>
   ```
   Continue resolving all non-ambiguous conflicts normally. Return escalations at the end so the caller can collect user decisions and resume.

## AI-Assisted Resolution

| AI works well for | Needs human review |
| ----------------- | ------------------ |
| Code conflicts where both sides add different features | Generated files (schemas, lock files) — regenerate instead |
| Import/export statement conflicts | Database migrations — ordering matters |
| Configuration file conflicts | Security-sensitive code |

Enable diff3 before using AI — it gives the model the base version for reasoning about intent. Provide `git log --merge -p` output as context. Review carefully — AI may not understand project conventions, build implications, or runtime behavior.

## Prevention

```bash
git config --global merge.conflictstyle diff3
git config --global rerere.enabled true
git config --global pull.rebase true
git config --global diff.algorithm histogram
```

| Practice             | Effect                                                               |
| -------------------- | -------------------------------------------------------------------- |
| Frequent integration | Merge/rebase from main often — small conflicts early                 |
| Small PRs            | Fewer files changed = fewer conflicts                                |
| Rebase before PR     | `git rebase main` surfaces conflicts in your branch                  |
| Worktrees            | Parallel work without stash conflicts (see `tools/git/worktrunk.md`) |
| Feature flags        | Ship disabled features to main early — avoid long-lived branches     |

## Error Recovery

```bash
# Undo a completed merge (before push)
git reset --hard HEAD^

# Undo a completed merge (after push) — creates a revert commit
git revert -m 1 <merge-commit>

# Find lost commits after a bad reset
git reflog
git checkout <lost-commit-sha>
```

## Related

- `tools/git/worktrunk.md` — Worktree management (conflict prevention)
- `workflows/git-workflow.md` — Branch-first development
- `workflows/pr.md` — PR creation and merge
- `workflows/branch.md` — Branch management
- `workflows/branch/release.md` — Cherry-pick for releases
- `tools/git/lumen.md` — Visual diff viewer for conflict review
