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
  [--output-root <directory>] [--failure-log <file>]

# Verify the manifest, artifact hashes, bundle, and untracked payload safety.
worktree-archive-helper.sh verify <archive-directory>

# Restore to a new linked worktree path. The target must not exist.
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

## Base selection

The caller must select the semantic base in this order:

1. the PR `baseRefName`;
2. dispatch metadata's target branch;
3. the repository integration branch, or its default branch.

Pass that name with `--base-branch`. Pass the already-observed commit with `--base-sha` whenever available. Without `--base-sha`, the helper resolves `origin/<base-branch>` first and then the local branch. It always stores the resolved commit, because the base is not necessarily `main` and a moving branch name is insufficient recovery evidence.

## Restore workflow

1. Run `verify <archive-directory>` before trusting the archive.
2. Ensure the source repository named by `source_git_common_dir` still exists. Incremental commit bundles deliberately depend on that repository's base objects.
3. Run `restore ... --target <new-path>`. The helper imports bundled commits, creates a uniquely named linked branch at the archived `HEAD`, applies the staged patch to the index, applies the unstaged patch, and safely expands the untracked payload.
4. Inspect `git status`, compare the restored `HEAD` and `base_sha`, and publish a branch/PR before deleting either recovery copy.

Restore never overwrites an existing path. If restoration stops after creating a worktree, preserve it for inspection and use normal guarded worktree cleanup after resolving the cause.

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

Pulse uses compact archives before removing stale failed workers, terminal
issue/PR worktrees, and generated auto/review worktrees that have reached their
cleanup age. Clean local-only commits are bundled as well as dirty tracked,
staged, and bounded untracked state. The latest retained worker-failure excerpt
is included when available. Pulse runs `verify` before guarded removal and keeps
an attached branch as an additional recovery path.

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
