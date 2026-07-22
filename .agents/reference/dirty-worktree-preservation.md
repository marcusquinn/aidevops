<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dirty Canonical Worktree Preservation

Use when a canonical checkout contains unexpected tracked, staged, untracked,
or local-commit state. Canonical checkouts are read-only service mirrors on any
branch name; implementation sessions belong in linked worktrees.

## Safety rule

Do not stash, reset, clean, or include unexpected files in another PR. Process
cwd does not make a canonical checkout session-owned. Preserve and verify every
byte before removing only the matching state.

## Preserve without mutation

```bash
.agents/scripts/dirty-worktree-backup-helper.sh backup \
  --repo /path/to/repo \
  --reason "unexpected canonical mirror state" \
  --issue <issue-if-known> \
  --task <task-id-if-known>
```

The backup command does not mutate the checkout. It records the original HEAD,
index tree, full worktree tree, status fingerprint, binary patches, copied
untracked files, and stable `refs/aidevops/dirty-worktree-backups/<id>` commits.
It prints the backup ID and exact restore command. Use `verify` and `matches`
before any explicit `clean` operation.

## Audited mirror synchronization

An explicit request to synchronize the canonical mirror authorizes this route:

```bash
.agents/scripts/canonical-recovery-helper.sh sync-mirror \
  --repo /path/to/canonical-checkout \
  --issue 123 \
  --confirm SYNCHRONIZE_CANONICAL_MIRROR
```

The helper structurally refuses linked worktrees. It resolves the allowed branch
from registered repository config, committed `HEAD:.aidevops.json`, or
`origin/HEAD`; an untracked/modified project config and arbitrary `--branch`
cannot select the target. Under the canonical recovery lock it:

1. fetches and pins the exact allowed `origin/<branch>` tip;
2. creates and verifies a lossless backup before cleaning matching noise;
3. removes only structurally canonical ownership rows without signalling PIDs;
4. preserves divergent/local-only commits at an audited recovery ref;
5. compare-and-swaps the local ref and updates the worktree to the pinned tip;
6. verifies branch, HEAD, remote ref, worktree cleanliness, and the audit chain.

If synchronization stops after cleanup, the old ref remains unchanged and the
printed backup ID/restore command remains valid. Retry the same command: stable
operation IDs reuse matching evidence rather than overwriting it. A failed
compare-and-swap rolls the local ref back. Never bypass the helper with direct
`git pull`, reset, or clean.

## Converged stale rebase recovery

When a clean canonical checkout has completed an interactive rebase but stale
metadata still blocks `restore-default`, use the separately confirmed cleanup:

```bash
.agents/scripts/canonical-recovery-helper.sh clear-stale-rebase \
  --repo /path/to/canonical-checkout \
  --issue 123 \
  --confirm CLEAR_CONVERGED_STALE_REBASE
```

Under the canonical recovery lock, the helper fetches and pins the configured
default branch, verifies the audit chain, and requires `HEAD`, the local default
ref, and the pinned remote tip to be identical. It accepts only a completed,
clean, structurally valid `rebase-merge` state for that default branch. Active,
dirty, divergent, branch-mismatched, malformed, or changing state fails closed.

Before cleanup, the helper copies and fingerprints all rebase metadata under
`~/.aidevops/.agent-workspace/recovery/canonical/` and creates durable
`refs/aidevops/canonical-recovery/issue-<N>/stale-rebase/<sha>` refs for commit
IDs found in that metadata. It then proves cleanup did not change HEAD, local or
remote refs, the index tree, or worktree content. Run `restore-default` with its
own confirmation token after this command succeeds. Never use direct
`git rebase --quit`, reset, clean, or metadata deletion on a canonical checkout.

Restore preserved state only to a clean checkout on the recorded branch:

```bash
.agents/scripts/dirty-worktree-backup-helper.sh restore \
  --repo /path/to/repo \
  --backup <backup-id> \
  --confirm RESTORE_DIRTY_WORKTREE_BACKUP
```

## Backup retention

Backups live under:

```text
~/.aidevops/.agent-workspace/tmp/dirty-main-backups/
```

Open backups are never pruned automatically, including when a linked PR closes.
Only explicitly acknowledged or restored evidence becomes eligible for terminal
PR/age pruning. Use `.keep` inside a backup directory for indefinite retention.

Manual prune:

```bash
.agents/scripts/dirty-worktree-backup-helper.sh prune --dry-run
.agents/scripts/dirty-worktree-backup-helper.sh acknowledge \
  --backup <backup-id> --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP
.agents/scripts/dirty-worktree-backup-helper.sh prune --force
```
