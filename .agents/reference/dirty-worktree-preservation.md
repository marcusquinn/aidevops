<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dirty Canonical Worktree Preservation

Use when canonical `main`/`master` is dirty with unrelated files while another
session may still be active, especially before release, setup, cleanup, or PR
merge work.

## Safety rule

Do not stash, reset, clean, or include unrelated files in the current PR just to
make progress. Those actions can hide or remove another live session's work.

## Progress path

1. Preserve first:

   ```bash
   .agents/scripts/dirty-worktree-backup-helper.sh backup \
     --repo /path/to/repo \
     --reason "release blocked by unrelated dirty canonical worktree" \
     --pr <current-pr-if-any> \
     --task <task-id-if-known>
   ```

2. Notify/coordinate with the likely owner using the mailbox when available:

   ```bash
   .agents/scripts/mail-helper.sh send --type request --to broadcast \
     --subject "Dirty canonical worktree needs owner checkpoint" \
     --body "Please checkpoint/commit/clear <safe summary>; backup recorded locally."
   ```

3. Continue only from a clean linked worktree, or wait until canonical `main` is
   clean before release/setup commands that must run from canonical.

4. If the dirty files are complete and intentional, commit them in a separate
   task/PR. Do not mix them into an unrelated PR/release.

## Backup retention

Backups live under:

```text
~/.aidevops/.agent-workspace/tmp/dirty-main-backups/
```

Each backup contains tracked/staged patches, copied untracked files, status, and
`manifest.tsv` metadata. The async cleanup pass prunes backups whose linked PR is
closed/merged, and stale backups after the retention window. Use `.keep` inside a
backup directory to preserve it manually.

Manual prune:

```bash
.agents/scripts/dirty-worktree-backup-helper.sh prune --dry-run
.agents/scripts/dirty-worktree-backup-helper.sh prune --force
```
