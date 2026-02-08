---
description: Git merge, cherry-pick, and rebase conflict resolution
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

- **Detect**: `git status` shows "both modified", `git diff --check` finds markers
- **Markers**: `<<<<<<<` (ours), `=======` (divider), `>>>>>>>` (theirs)
- **Resolve**: Edit file, remove markers, `git add`, continue operation
- **Abort**: `git merge --abort`, `git cherry-pick --abort`, `git rebase --abort`

<!-- AI-CONTEXT-END -->

## Detecting Conflicts

```bash
# Check for conflicted files
git status                          # Shows "both modified" entries
git diff --name-only --diff-filter=U # List only conflicted files
git diff --check                     # Find remaining conflict markers
```

Search for unresolved markers in the working tree:

```bash
rg '<<<<<<<' --files-with-matches
```

## Understanding Conflict Markers

```text
<<<<<<< HEAD
// Your current branch's version (ours)
const timeout = 5000;
=======
// Incoming branch's version (theirs)
const timeout = 10000;
>>>>>>> feature/new-timeouts
```

| Marker | Meaning |
|--------|---------|
| `<<<<<<< HEAD` | Start of current branch content |
| `=======` | Divider between the two versions |
| `>>>>>>> branch` | End of incoming branch content |

In a **rebase**, the meaning is inverted: HEAD is the branch being rebased onto (upstream), and the named ref is your commit being replayed.

## Resolution Strategies

### Accept one side entirely

```bash
# Accept current branch version for specific file
git checkout --ours path/to/file
git add path/to/file

# Accept incoming branch version for specific file
git checkout --theirs path/to/file
git add path/to/file
```

### Accept one side for entire merge

```bash
git merge feature-branch -X ours    # Prefer current on conflicts
git merge feature-branch -X theirs  # Prefer incoming on conflicts
```

### Manual merge (most common for AI agents)

1. Read the conflicted file
2. Understand **intent** of both sides (check commit messages with `git log`)
3. Edit: combine changes or choose the correct version
4. Remove all conflict markers
5. `git add` the resolved file

### 3-way merge with merge base

```bash
# See the common ancestor version
git show :1:path/to/file    # Base (common ancestor)
git show :2:path/to/file    # Ours (current branch)
git show :3:path/to/file    # Theirs (incoming branch)
```

## Cherry-Pick Conflicts

Cherry-pick applies a single commit onto a different base, so conflicts are common when surrounding code differs.

```bash
git cherry-pick abc1234
# ... conflicts arise ...

# Resolve each file, then:
git add path/to/resolved-file
git cherry-pick --continue

# Or abort:
git cherry-pick --abort
```

**Tip**: Use `git log --oneline abc1234 -1` to review the original commit's intent before resolving.

## Rebase Conflicts

Rebase replays commits one at a time. You may need to resolve conflicts at each step.

```bash
git rebase main
# ... conflict at commit N ...

# Resolve, then:
git add path/to/resolved-file
git rebase --continue

# Skip this commit entirely:
git rebase --skip

# Abort the whole rebase:
git rebase --abort
```

**Important**: During rebase, "ours" is the upstream branch (main) and "theirs" is your commit being replayed. This is the opposite of merge.

## Common Conflict Patterns

### Same function modified on both sides

Both branches edited the same function. Read both versions, merge the logic manually. Often both changes are needed.

### Import / require conflicts

Both branches added imports. Usually combine both sets and deduplicate. Sort order may need adjustment to match project conventions.

### Lockfile conflicts (package-lock.json, yarn.lock, Cargo.lock)

Never manually resolve lockfiles. Regenerate instead:

```bash
# Accept one side, then regenerate
git checkout --theirs package-lock.json
npm install
git add package-lock.json

# Or delete and regenerate
rm package-lock.json
npm install
git add package-lock.json
```

### Adjacent line changes

Git cannot auto-merge when both sides modify nearby (not identical) lines. Review the diff carefully; these are usually safe to combine.

### File deleted on one side, modified on the other

```bash
# Keep the file (accept the modification)
git add path/to/file

# Remove it (accept the deletion)
git rm path/to/file
```

## Post-Resolution Verification

After resolving all conflicts:

```bash
# Ensure no conflict markers remain
git diff --check
rg '<<<<<<<|=======|>>>>>>>' --files-with-matches

# Review what you resolved
git diff --staged

# Run tests before completing
npm test        # or project-appropriate test command

# Complete the operation
git merge --continue     # or
git cherry-pick --continue  # or
git rebase --continue
```

## AI-Assisted Resolution Tips

1. **Read both sides fully** before editing. Understand the intent, not just the text.
2. **Check commit messages**: `git log --oneline main..HEAD` and `git log --oneline HEAD..feature` to understand what each side was trying to achieve.
3. **Prefer combining** over choosing. If both sides add valid code, merge both contributions.
4. **Watch for semantic conflicts**: Code may merge cleanly but break at runtime (e.g., a renamed function called with the old name). Run tests.
5. **Resolve one file at a time**: `git add` each file after resolving, then verify with `git diff --check`.
6. **When unsure, abort**: It is always safe to `--abort` and start over. Never push a broken merge.
7. **Lockfiles are never hand-merged**: Always regenerate from the package manager.
