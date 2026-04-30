# Git Hygiene Reference

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Common git state problems that cause confusing failures in the aidevops workflow,
and the recovery steps to resolve them.

---

## Shallow Clone — add/add Conflict Cascade

**Memory lesson:** "Shallow git clones masquerade as force-pushed history" (stored 2026-04-30)

### Symptom

Running `full-loop-helper.sh commit-and-pr` (or any bare `git rebase origin/main`)
produces a wall of add/add conflicts across hundreds of files — even when your change
touches only one file.  Example output:

```text
CONFLICT (add/add): Merge conflict in .agents/scripts/full-loop-helper-commit.sh
CONFLICT (add/add): Merge conflict in .agents/scripts/pulse-wrapper.sh
... (200 more lines)
Rebase conflict. Resolve conflicts, then run: git rebase --continue ...
```

The conflicts **cannot be resolved by editing** — they are not semantic conflicts.
The merge-base is genuinely absent locally because the clone was depth-limited.

### Diagnosis

```bash
git rev-parse --is-shallow-repository
# returns "true" if the clone is shallow
```

If it returns `true`, the fix is to fetch the missing history, not to resolve conflicts.

### Auto-recovery (GH#21900)

As of GH#21900, `_rebase_and_push` in `full-loop-helper-commit.sh` automatically
detects a shallow clone and runs `git fetch --unshallow origin` before the rebase.
The default behaviour is to auto-unshallow.  To disable auto-unshallow and receive
an error message instead, set:

```bash
export AIDEVOPS_SHALLOW_UNSHALLOW=0
```

### Manual Recovery

If the auto-unshallow fails or you need to recover mid-conflict:

```bash
# Step 1: abort any in-progress rebase
git rebase --abort 2>/dev/null || true

# Step 2: unshallow the clone
git fetch --unshallow origin

# Step 3: retry the rebase
git rebase origin/main
```

### Save-patch Recovery (work was committed before the rebase attempt)

If you had commits that got clobbered:

```bash
# Save the top commit as a patch
git format-patch -1 HEAD --stdout > /tmp/save.patch

# Reset to a clean state
git reset --hard origin/main

# Re-apply the saved patch
git am /tmp/save.patch
```

### Root Cause

Multi-runner aidevops setups and CI environments frequently produce shallow clones
(`git clone --depth=1`) for speed.  When `git rebase origin/main` runs, git needs
the common ancestor between your branch and `origin/main`.  On a shallow clone that
ancestor is absent, so git treats every file as simultaneously "added by us" and
"added by them" — the add/add cascade.

`git fetch origin main` (called first in `_rebase_and_push`) fetches the tip but
does NOT un-shallow the repo.  Only `git fetch --unshallow origin` restores the
full commit graph.

### Pre-edit-check Warning

`pre-edit-check.sh` emits a `WARNING: This git clone is shallow` advisory when it
detects a shallow repo.  This fires at session-start so the operator can fix
proactively before attempting a commit-and-pr.
