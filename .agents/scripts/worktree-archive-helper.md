<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compact worktree archives

`worktree-archive-helper.sh` preserves recovery evidence without retaining a full worker worktree. Archives default to `~/.aidevops/recovery/archives/` and are recovery artifacts, not backups of remote GitHub state.

## Commands

```bash
# Archive a worker worktree. The command prints the new archive directory.
worktree-archive-helper.sh archive <worktree-path> \
  --repo owner/repo --issue 123 --reason failed-worker \
  --base-branch develop [--base-sha <commit>] \
  [--output-root <directory>] [--failure-log <file>] [--self-contained]

# Verify the manifest, artifact hashes, bundle, and untracked payload safety.
worktree-archive-helper.sh verify <archive-directory>

# Restore to a new path. Self-contained archives create an independent repository;
# incremental archives create a linked worktree. The target must not exist.
worktree-archive-helper.sh restore <archive-directory> \
  --target <new-worktree-path>

# List all archives, or filter by repository and/or issue.
worktree-archive-helper.sh list [--repo owner/repo] [--issue 123] \
  [--output-root <directory>]

# Preview or apply retention. Exactly one mode is required.
worktree-archive-helper.sh prune --older-than 14d --max-total-size 20G \
  [--dry-run|--apply] [--output-root <directory>]
```

`--reason` accepts only `failed-worker` or `post-pr-cleanup`. Untracked capture defaults to at most 10,000 paths and 1 GiB; override those bounds with `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES`. `AIDEVOPS_WORKTREE_ARCHIVE_ROOT` changes the default root.

## Archive layout

The path is `<root>/<owner>__<repo>/<issue>/<UTC timestamp>/`:

| Artifact | Purpose |
|---|---|
| `manifest.json` | Schema, source and Git metadata, artifact sizes/SHA-256 hashes, and restore command |
| `commits.bundle` | Incremental Git bundle when `HEAD` contains commits beyond the exact base SHA |
| `diff.patch` | Binary-safe unstaged tracked changes; present even when empty |
| `staged.patch` | Binary-safe staged changes; present even when empty |
| `untracked-files.txt` | Human-readable escaped inventory; present even when empty |
| `untracked.tar.gz` | Bounded untracked regular files and symlinks, when any exist |
| `failure.log` | Optional final 256 KiB excerpt supplied with `--failure-log` |

The manifest records the repository, issue, reason, creation time, source worktree, source Git common directory, branch, `HEAD`, base branch and exact base SHA, default branch, remote branch state, dirty state, artifacts, and restore instructions. `verify` rejects missing, changed, or unsafe artifacts.

`--self-contained` always includes a complete `HEAD` ancestry bundle, including
when HEAD equals the base. Verification checks it in an empty repository rather
than borrowing source objects. Restoration needs neither the source repository
nor its remote and creates no linked-worktree registration. This costs more space
than an incremental archive; it is not a backup of unrelated branches or refs.

## Base selection

The caller must select the semantic base in this order:

1. the PR `baseRefName`;
2. dispatch metadata's target branch;
3. the repository integration branch, or its default branch.

Pass that name with `--base-branch`. Pass the already-observed commit with `--base-sha` whenever available. Without `--base-sha`, the helper resolves `origin/<base-branch>` first and then the local branch. It always stores the resolved commit, because the base is not necessarily `main` and a moving branch name is insufficient recovery evidence.

## Restore workflow

1. Run `verify <archive-directory>` before trusting the archive.
2. For incremental archives, ensure the source repository named by `source_git_common_dir` still exists. Their bundles deliberately depend on that repository's base objects. Self-contained archives have no such dependency.
3. Run `restore ... --target <new-path>`. The helper imports bundled commits, creates a uniquely named linked branch at the archived `HEAD`, applies the staged patch to the index, applies the unstaged patch, and safely expands the untracked payload.
4. Inspect `git status`, compare the restored `HEAD` and `base_sha`, and publish a branch/PR before deleting either recovery copy.

Restore never overwrites an existing path. If restoration stops after creating a worktree, preserve it for inspection and use normal guarded worktree cleanup after resolving the cause.

### Restore-verified idle archive receipts

`worktree_lifetime_archive.py` adds verification phases to the existing managed
lifetime record; it does not create a second registry or remove source trees.
It requires a sealed, generation-bound idle authorization (at least 24 hours), creates a
self-contained archive, restores it independently, and compares source and
restored HEAD, index, file contents, modes and symlinks. Native removal proofs
reject incomplete operations and recheck the archive and source snapshot.

Artifacts and their directory ancestry are fsynced before the durable SQLite
restore receipt is committed. Filesystems without the required fsync semantics
are unsupported. Interrupted construction retains one reservation and the source,
without allocating duplicate copies. A completed restore receipt permits retrying
identity-checked scratch cleanup. Archive expiry remains a separate opt-in policy.
The manifest digest is captured before restoration and checked again after
durability flushing; the receipt refers to that same verified archive.

The capacity preflight includes compressed Git objects, expanded HEAD and index
contents, and current dirty/untracked file sizes, with conservative working-space
overhead and a 1 GiB free-space reserve. Insufficient or unavailable capacity
prevents a new reservation; it never authorizes deleting protected recovery data.
Concurrent disk consumption can still cause ENOSPC, which preserves the source.

The automatic verifier has a deliberately narrow Git working-tree contract, not
a full filesystem-backup contract. It preserves standard 0644/0755 files, 0755
directories and symlink targets owned by the current UID/GID; timestamps are not
preserved. It protects rather than discards ignored data, ACLs/xattrs, special
permissions, foreign ownership, hard links, empty directories, nested repositories,
Git filters/LFS, private worktree refs, reflog-only history, unfinished operations,
intent-to-add index entries, per-worktree config, squash/message drafts and unknown
worktree administrative entries. Missing inspection evidence
also prevents authorization. The cooperative ownership/cgroup fence is required:
a fingerprint by itself cannot exclude arbitrary unregistered same-user writers.

### Rootless reporting and reconciliation

```bash
# Read recorded state, archive locations, available space and scheduler status.
bash .agents/scripts/worktree-lifecycle-helper.sh report --summary

# Complete verified receipts only when source and Git registration are absent.
bash .agents/scripts/worktree-lifecycle-helper.sh reconcile

# Run guarded cleanup under its existing lock and cadence, without recovery expiry.
bash .agents/scripts/worktree-lifecycle-helper.sh run

# Optional, after deploying the framework: install a Linux user-systemd timer.
bash .agents/scripts/worktree-lifecycle-helper.sh install-scheduler
```

The timer runs independently of Pulse every ten minutes. It uses the existing
generic scheduler installer, a 900-second service limit and control-group cleanup;
no sudo, system service or second supervisor is involved. Installation is explicit,
not a side effect of reporting. Unsupported user-systemd environments fail closed.

Reports label records `recorded-not-revalidated`: they are not removal authority.
Unavailable sizes remain unknown, not zero. `cleanup_last_success` is the shared
cleanup timestamp, not proof every candidate completed. Managed archives live
under `<archive-root>/.lifecycle/<operation-id>/archives/`; use the reported path
for verification/restoration. Automatic archive expiry does not select this store.

Reconciliation updates only receipts and a rotating traversal cursor in the same
ownership database. It reserves a bounded batch before checking it, so failed and
ineligible rows cannot monopolize later runs. Interruptions defer that batch until
wraparound. Missing repositories, changed identities, unavailable evidence and
unverified archives remain deferred; reconciliation never removes source data.

### Ignore rules and secrets

Untracked capture uses Git's standard ignore rules (`git ls-files --others --exclude-standard`), not a second cache allowlist. Ignored dependencies and build caches are rebuilt from tracked manifests/lockfiles. Keep `.env.example` tracked with placeholders; supply real values from a persistent protected config or secret store at launch, rather than duplicating them in every worktree archive. A worktree does not automatically inherit the canonical checkout's `.env`. Before removing legacy worktrees or full recovery copies, check for unique ignored data and move any needed values to their durable owner without printing them. Archive directories are private (0700).

## Retention

The recommended policy is `--older-than 14d --max-total-size 20G`. `prune` selects verified archives older than the age limit, then oldest remaining eligible archives until their retained size is at or below the cap. This is irreversible expiry: it can destroy the last copy of unpublished work. Always inspect `--dry-run` output before using `--apply` in a manual operation.

Create `.aidevops-archive-pin` inside an archive directory to retain it regardless of age or size. Remove the marker only when expiry is appropriate. Pinned, corrupt, incomplete, unknown-content, invalid-date and symlinked archives are kept with a diagnostic; these protected bytes are outside the eligible-size cap and require investigation rather than forced deletion. Verification requires the complete artifact inventory, mandatory patches and untracked inventory, matching hashes, and no symlinked artifacts. Apply rechecks verification, manifest, pin and directory identity, using no-follow directory descriptors to anchor removal inside the selected store. Platforms without symlink-resistant removal fail closed.

Archives are immutable after publication. Set pins before retention claims an archive: apply atomically moves the selected directory into a private `.prune-<id>/archive` transaction, revalidates it there, then removes it. A replacement created at its old name is never deleted. A failed/interrupted transaction is retained outside normal retention selection and reported for recovery inspection; it is not silently considered successfully pruned. Do not modify a claimed transaction concurrently. Pin and manifest changes observed during final verification preserve that transaction.

After successful asynchronous worktree cleanup, Pulse runs compact retention once under the existing cleanup lock and a 120-second budget. It defaults to **dry-run**, not irreversible deletion. Explicitly enable expiry with `storage.worktree_archive_retention_mode: "apply"` in the normal aidevops user config; `"off"` disables the pass. `AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_MODE` overrides config (`off`, `dry-run`, `apply`); `AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_DAYS` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_TOTAL_SIZE` override 14 days and 20G. Invalid policy preserves archives. Outcomes and failures appear as `compact-retention mode=... rc=...` in `cleanup_worktrees.log`; a retention failure does not block independent worktree cleanup.

### Lifecycle verification

Completed worktrees end either in verified deletion with no unique data, or in a verified compact archive followed by source removal. Active ownership, open work and safety blockers are temporary states, not permission for unconditional deletion. Full recovery copies are a separate store: compact retention never deletes or migrates them. Migration must account for ignored files, Git administrative state and base-object availability before discarding the full copy.

Run `bash .agents/scripts/tests/test-worktree-archive-helper.sh` and `python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py`. The latter restores 33 local commits including a merge into a repository containing only the `develop` base, after removing the original fixture worktree. It compares HEAD, parent topology, index, binary staged/unstaged patches, status, executable modes, symlinks and untracked contents, and checks retention preview/apply, age/size limits, pins and unsafe/corrupt archives. Ignored files are deliberately excluded; the common repository's base objects must remain available. `test-cleanup-worktrees-async.sh` covers scheduling policy and failure isolation.

## Pulse cleanup integration

Ordinary worktrees require at least 24 hours of confirmed idle in the managed-lifetime
registry, or a longer configured window, followed by the independent restoration
checks above. Each attempt captures its configured window at entry; overlapping
classes use the longest applicable window. A later attempt requesting a window
beyond the operation's authorization retains source and recovery for a new
preservation decision. Directory age,
generated branch names, detached HEADs and absent registry rows never substitute
for idle evidence. Terminal issue/PR worktrees retain their separate existing
policy path. Clean local-only commits are bundled as well as dirty tracked,
staged, and bounded untracked state. Pulse verifies recovery before guarded
removal and keeps an attached branch as an additional recovery path.

Cleanup requires exact repository and issue/PR attribution. It fails closed
rather than falling back to an in-repository stash when attribution or remote
policy labels cannot be verified. Archived removals use the
`archived-failed-worker` or `archived-post-pr-cleanup` audit reason with
`mode=compact-archive`, archive location, verification outcome, and delete
outcome. The asynchronous cleanup summary reports removed, archived, and failed
archive counts.

Any compact archive creation or verification failure records a skipped cleanup
event and preserves the worktree and branch. The failure stops only that
worktree's deletion and must not fall through to a less protective cleanup path
or stop broader safe cleanup. Interactive/manual owners, security incidents,
`.aidevops-preserve-forensics`, `.preserve-forensics`, or
`.aidevops-security-incident` markers, protected task labels, repeated
zero-session failures, and other protected evidence retain full worktrees.
