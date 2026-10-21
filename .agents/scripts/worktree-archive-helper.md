<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compact worktree archives

`worktree-archive-helper.sh` preserves recovery evidence without retaining a full worker worktree. Archives default to `~/.aidevops/recovery/archives/` and are recovery artifacts, not backups of remote GitHub state.

For legacy full recovery buckets, use the explicit
[migration transition](../reference/storage-lifecycle-worktree-recovery.md#explicit-compact-migration-no-retirement).
It reuses this format, records its capture policy, preserves provenance in
a durable journal and pins the resulting archive. It does not retire the source
or change ordinary recovery producers.
Manual source retirement uses the separate operator-confirmed
[verified retirement transition](../reference/storage-lifecycle-worktree-recovery.md#confirmed-retirement-of-migrated-buckets).
Archive verification or migration success alone is still not removal authority.

Pulse's scheduled cleanup also runs `worktree-recovery-maintenance-helper.sh compact`.
It rotates through existing full recovery buckets and resumes automatic retirement
journals. Each pass examines at most ten candidates for up to 120 seconds and retires
at most one verified copy. The lifecycle command `compact --bucket <absolute-path>`
uses the same capture, verification and retirement functions; it is not another
archive format. Ownership, process, source-removal, identity and archive checks
must pass. Unknown or active sources remain untouched, including after interruption.
Automatic retirement requires schema-3 untracked preservation and an available
base repository outside the retired bucket. Source bytes retired and archive bytes
are reported separately; neither is a measurement of free disk space.

The maintenance state's private `compaction/last.json` records cursor, outcomes and
source/archive byte counts. A portable command-group timeout contains writers.
`AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED=0` disables the pass. Authority
`verified-git-changes/v1` is not a manual confirmation token; manual plans are never
adopted. Claimed automatic journals remain discoverable after their buckets move.
Deploy updated scripts on each Pulse machine; no sudo or new scheduler is required.
Measure actual retirement and free-space changes after deployment; merge alone does
not deploy or reclaim space. Compaction does not enable archive expiry.

## Commands

```bash
# Archive a worker worktree. The command prints the new archive directory.
worktree-archive-helper.sh archive <worktree-path> \
  --repo owner/repo --issue 123 --reason failed-worker \
  --base-branch develop [--base-sha <commit>] \
  [--output-root <directory>] [--failure-log <file>]

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

`--reason` accepts `failed-worker`, `post-pr-cleanup` or `unattributed-worktree`. Use `--unattributed` instead of `--issue` when no issue is proven. Untracked capture defaults to at most 10,000 paths and 1 GiB; override those bounds with `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES`. `AIDEVOPS_WORKTREE_ARCHIVE_ROOT` changes the default root.

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

Historical self-contained archives include a complete `HEAD` ancestry bundle, including
when HEAD equals the base. Verification checks it in an empty repository rather
than borrowing source objects. Restoration needs neither the source repository
nor its remote and creates no linked-worktree registration. This costs more space
than an incremental archive; it is not a backup of unrelated branches or refs.
These archives remain readable, but new creation uses only the incremental format.

## Recoverable producer transactions

`archive_worktree_path_recoverably` now creates Git-only compact recovery, not a
new full recovery directory. Its four callers are manual removal in
`worktree-helper-cmds.sh`, classified cleanup in `worktree-clean-lib.sh`, profile
publication in `profile-readme-helper.sh`, and Pulse profile cleanup in
`pulse-cleanup-worktree-removal-profile.sh`. Other managed-idle and legacy
migration/retirement paths retain their own contracts.

Producer root precedence is the first nonempty value of
`AIDEVOPS_WORKTREE_ARCHIVE_ROOT`, `AIDEVOPS_WORKTREE_TRASH_ROOT`, then the legacy
`AIDEVOPS_ORPHAN_TRASH_ROOT`; otherwise it is `$HOME/.aidevops/recovery/archives`
on every platform. Roots must be absolute, host-local and outside the source and
its Git administration. The archive CLI itself uses its archive-root override;
when a producer uses a legacy override, pass that root explicitly to `list` with
`--output-root`.

One physical source identity reserves `<root>/.producer-transactions/<id>/journal.json`
and captures beneath `<root>/.producer-archives/<id>/<owner>__<repo>/unattributed/<timestamp>/`.
No issue is guessed from the path. Every new archive contains exact base/HEAD,
incremental commits, staged and unstaged binary patches, and ordinary untracked
files. Git defines the inventory with `ls-files --others --exclude-standard`;
ignored files and raw Git administration are excluded. `git-only` is the retained
manifest policy name, not an alternative creation mode. There are no
project-specific or directory-specific exclusions.
The shared repository must retain the recorded base. An empty delta needs no bundle.
Unmerged and intent-to-add index entries fail closed because two patches cannot
preserve their index state. Patch output explicitly overrides color and path-prefix
preferences so user Git display settings cannot make the archive unappliable.

Capture writes artifacts and its durable receipt, then reports `phase: archived`.
It does not invoke archive verification, a trial restore, or repeated whole-tree
hashing. Its saved Git identity is captured before the patches, not sampled later
and substituted as evidence for earlier data. The source must be quiescent during
capture. Ownership and pre-removal guards remain outside the capture function;
archive completion alone is not deletion authority or a claim of verified restoration.

Git-only restore imports the bundle and calls `worktree-helper.sh add` with the
saved HEAD SHA, a new branch and target path: the same creation/registration API
called by Pulse. It then applies `staged.patch` with `git apply --index`, followed
by `diff.patch` without updating the index. No worker is dispatched. Dependency
provisioning is separate and must use the restored lockfiles, not the base versions.

Existing receipts keep their original policy; retries never silently downgrade
them. Legacy readers and already-captured transaction recovery remain available.
New capture rejects `AIDEVOPS_WORKTREE_RECOVERY_POLICY=preserve-v1` and the obsolete
`--self-contained`, `--include-ignored`, and `--preserve-git-admin` creation options.
Schema-2 receipts do not prove preservation of untracked files and cannot authorize
automatic retirement. Remove obsolete capture-policy overrides when deploying.

Manual `worktree-helper.sh remove` prints `Recovery archive: <path>` after capture,
including when a later guard refuses removal. That line is not proof of retirement;
inspect `source_removal_outcome`. Run `worktree-archive-helper.sh verify <path>` and
`python3 worktree_recovery_producer.py verify <path>` to check artifact and producer
receipt evidence, then restore with `worktree-archive-helper.sh restore <path>
--target <new-path>`. Keep archives private; committed and patched data may be sensitive.

`list` discovers standalone and producer archives through their exact layouts and
schema. It excludes transaction scratch, legacy full-copy directories and symlinked
entries. Listing is discovery, not verification or removal authority. Legacy
`worktree-helper.sh recovery` inventory remains a report of the separate full-copy store.
Producer archives retain `.aidevops-archive-pin`; this discovery change does not
expand retention selection, remove pins or enable automatic expiry.

Retries reuse a valid reservation; drift, unsupported input or incomplete evidence
preserves the source and existing artifacts without a full-copy fallback. Do not
delete journals to force another capture. Git-only recovery preserves Git file modes,
not filesystem metadata. An unmerged index cannot be represented by two patches.
The legacy full-preservation comparison still refuses unsupported filesystem state.
Code delivery does not deploy these changes or migrate/retire installed recovery stores.

### External regression test

The archive regression test runs outside capture. It checks capture artifacts and
then runs the real restore CLI, comparing HEAD, the index, staged/unstaged binary
patches and file contents. Its disposable repository drops the archived commit
before restoration to prove the bundle supplies it. Capture itself never invokes
this test or a trial restore.

```bash
python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py ArchiveLifecycle.test_git_only_capture_contains_commits_and_two_patches_without_verification
```

### Stage timings

Producer capture and explicit legacy migration append private, best-effort JSONL
events to `~/.aidevops/logs/worktree-recovery-timings.jsonl` (0600). Override the
destination with `AIDEVOPS_RECOVERY_TIMING_LOG`. Logging failure warns once per
attempt but does not replace or bypass archive safety checks.

```bash
python3 ~/.aidevops/agents/scripts/worktree_recovery_timing.py report
# Read a separately retained timing log:
python3 ~/.aidevops/agents/scripts/worktree_recovery_timing.py report --log <file>
```

Schema `aidevops.recovery-timing/v1` records UTC timestamps, monotonic durations,
attempt/stage/parent IDs, operation, available repository/source context, success
or failure, and known archive/receipt locations and sizes. It covers source
snapshots, reservation, capture, archive CLI verification/restoration, comparison,
and verification-scratch cleanup where those phases execute. Early failures may
have an unknown repository. Interrupted attempts may have starts without finishes.

The read-only report groups completed stage durations by repository, operation
and status, with count/minimum/median/maximum. Malformed records and unmatched
starts/finishes are counted explicitly; missing durations are not reported as zero.
Report input is bounded to 64 MiB and fewer than 100,000 records; use a separately
retained log when that bound is exceeded. This logger does not rotate or expire
logs. Keep them private and manage retention separately.

Durations are **inclusive**, so do not sum a parent and its children. `total`
measures the Python transaction, not outer shell locking/preflight, subsequent
native removal, or the whole scheduled cleanup pass. Managed-idle archives and
permanent-removal paths are not instrumented by this logger. A successful capture
is not proof of source removal or reclaimed bytes. Timing records are diagnostics,
never restoration evidence, retirement authority, or replacements for durable
manifests and journals. Legacy incremental and self-contained producer archives
retain their distinct recovery dependencies and policies.

## Base selection

The caller must select the semantic base in this order:

1. the PR `baseRefName`;
2. dispatch metadata's target branch;
3. the repository integration branch, or its default branch.

Pass that name with `--base-branch`. Prefer the recorded fork commit via `--base-sha` when available. Otherwise the helper resolves `origin/<base-branch>` (falling back to the local branch) and records its unique merge-base with HEAD. Multiple merge bases require an explicit SHA. The manifest stores the exact commit, never just a moving branch name.

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
incremental archive, restores a private verification copy from the recorded base,
and compares source and
restored HEAD, index, file contents, modes and symlinks. Native removal proofs
reject incomplete operations and recheck the archive and source snapshot.

The internal `restore --verification-copy` path reuses base seeding and payload
restoration without registering a user worktree or creating shared repository
branches. Normal restoration still uses the common public worktree creation API.

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

The automatic verifier has a narrow Git working-tree contract, not a full
filesystem-backup contract. Tracked files use Git's content and executable modes;
ordinary untracked files retain supported modes and symlink targets. Ignored data,
timestamps and empty directories are not captured. Unsupported untracked metadata,
private worktree refs, reflog-only history, unfinished operations, hidden index
changes, intent-to-add entries, squash/message drafts and unknown administrative
entries prevent capture rather than permitting loss. Missing inspection evidence
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

Previously created archives can contain ignored payloads. Their recorded capture
policy remains authoritative for verification and restore; new archives never
include ignored files. Move any needed ignored data to durable storage separately.

### Historical Git administration archives (read/restore compatibility only)

Previously created archives using `--preserve-git-admin` record
`git_admin_policy: "preserve-v1"` and a hashed `git-admin.json` artifact. It
preserves byte contents of HEAD, the index (including intent-to-add), ORIG_HEAD, FETCH_HEAD,
HEAD's reflog, COMMIT_EDITMSG, SQUASH_MSG, MERGE_MSG and config.worktree, plus
private `refs/worktree/*`, `refs/bisect/*` and `refs/rewritten/*`. Required objects
include both old/new reflog endpoints, ORIG_HEAD, all FETCH_HEAD objects
(including `not-for-merge` entries), private ref objects,
and index-only blobs. Only objects outside the recorded base graph are bundled;
when the base covers everything, no bundle is created. Scratch refs are temporary;
capture never writes source refs or objects. Source matching is bound to this
policy and detects changed admin bytes as well as ordinary working-tree changes.
FETCH_HEAD records must contain a valid SHA-1/SHA-256 object ID and Git's tab-separated
merge marker/description fields. Malformed records and unavailable objects block
preservation; the file is never silently discarded. Its descriptions are retained
as data, not used as remote addresses or commands.

Capture traverses the objects reachable from the required history roots once.
Index and resolve-undo objects receive extra preservation refs only if that graph
does not already cover them; a clean index needs no separate per-file refs.
The remaining refs are written in one `update-ref --stdin` call after object-ID
validation. Verification still checks every required admin/index object, not
just the reduced set of bundle tips. This changes neither the archive format nor
the requirement for a verified restore. The existing separate `staged.patch`,
`diff.patch` and untracked payload remain unchanged. `--self-contained` is an
explicit full-history option, not required by metadata preservation or migration.

The same artifact preserves the known readiness records
`aidevops/js-readiness.json`, `aidevops/js-restore.json`,
`aidevops/js-readiness-entry` and `aidevops/js-prepare.json`, as opaque bytes
limited to 1 MiB per file. These records are not ownership, quiescence or removal
authority. Restore creates their metadata directory privately (0700).
Other entries under `aidevops/` remain unsupported; the
`aidevops/js-install-partial` marker blocks capture as an unfinished operation.
Symlinks and oversized readiness records fail closed during capture, and the
artifact reader also enforces the size limit before restoring them.

The known `aidevops-profile-publication.json` record is also preserved as opaque
bytes under the same 1 MiB limit. It is historical metadata, not fresh publication
or removal authority; restore does not rewrite its original path bindings.
Special working-file permissions (for example, a tracked file with mode 0600)
remain unsupported and block migration rather than being normalized or discarded.

Incremental verification imports only the recorded base graph from the existing
common repository into an empty scratch repository, then imports the delta and
checks all admin/index dependencies. Missing base evidence blocks verification,
restore and retirement. Keep the base repository and commit available for the
archive's lifetime; there is no new shared-base store or remote-fetch fallback.
Metadata-preserving restore creates a separate repository from base plus delta,
without changing source branches or borrowing source objects through alternates.
It imports preservation refs, reconstructs
the original branch/HEAD and private refs, and writes the saved admin bytes after
applying patches and untracked files. `extensions.worktreeConfig` is enabled when
needed. Preservation tips remain under `refs/archive/*` to keep recovery objects
reachable. Only explicit self-contained archives are independent of the base. Config and
drafts may contain sensitive data; keep the archive's 0700 protection and review
restored config before running tools in the recovered repository.

Unfinished operations and unknown admin entries remain unsupported: errors have
the stable form `git_admin:unfinished_operation:NAME` or
`git_admin:unknown_entry:PATH`. `index.lock` always fails with
`git_admin:index_locked:index.lock`. Symlinks and split indexes also fail closed.
Location-dependent `core.worktree` and config includes are rejected with
`git_admin:location_dependent_config:KEY`, rather than activating source paths
in an independent restore. Private symbolic refs targeting unrelated shared refs
fail with `git_admin:external_symbolic_ref:REF`; targets within the private ref
namespaces or the original HEAD branch are supported.
Special index flags, unmerged entries, submodules and filters remain unsupported.
This option can combine with `--include-ignored`; it does not enable that policy
implicitly. No-flag archives keep their existing representation, and manifests
without `git_admin_policy` retain their existing verify/restore behavior.
Automatic idle archival does **not** opt in; its narrow contract is unchanged.

For read-only source/restore comparison, run
`python3 worktree_archive_snapshot.py --preserve-git-admin --include-ignored WORKTREE`
on each tree. The optional ignored-file inventory includes contents in the
fingerprint and detects ignored-file drift. Without `--include-ignored`,
snapshots still reject ignored data. All filesystem restrictions (including
empty directories, unsupported permissions, ACLs/xattrs and hard links) remain
enforced. Matching fingerprints do not establish quiescence or authorize
retiring a recovery bucket; its preservation metadata and removal guards are
separate requirements.

## Retention

The recommended policy is `--older-than 14d --max-total-size 20G`. `prune` selects verified archives older than the age limit, then oldest remaining eligible archives until their retained size is at or below the cap. This is irreversible expiry: it can destroy the last copy of unpublished work. Always inspect `--dry-run` output before using `--apply` in a manual operation.

Create `.aidevops-archive-pin` inside an archive directory to retain it regardless of age or size. Remove the marker only when expiry is appropriate. Pinned, corrupt, incomplete, unknown-content, invalid-date and symlinked archives are kept with a diagnostic; these protected bytes are outside the eligible-size cap and require investigation rather than forced deletion. Verification requires the complete artifact inventory, mandatory patches and untracked inventory, matching hashes, and no symlinked artifacts. Apply rechecks verification, manifest, pin and directory identity, using no-follow directory descriptors to anchor removal inside the selected store. Platforms without symlink-resistant removal fail closed.

Archives are immutable after publication. Set pins before retention claims an archive: apply atomically moves the selected directory into a private `.prune-<id>/archive` transaction, revalidates it there, then removes it. A replacement created at its old name is never deleted. A failed/interrupted transaction is retained outside normal retention selection and reported for recovery inspection; it is not silently considered successfully pruned. Do not modify a claimed transaction concurrently. Pin and manifest changes observed during final verification preserve that transaction.

After successful asynchronous worktree cleanup, Pulse runs compact retention once under the existing cleanup lock and a 120-second budget. It defaults to **dry-run**, not irreversible deletion. Explicitly enable expiry with `storage.worktree_archive_retention_mode: "apply"` in the normal aidevops user config; `"off"` disables the pass. `AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_MODE` overrides config (`off`, `dry-run`, `apply`); `AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_DAYS` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_TOTAL_SIZE` override 14 days and 20G. Invalid policy preserves archives. Outcomes and failures appear as `compact-retention mode=... rc=...` in `cleanup_worktrees.log`; a retention failure does not block independent worktree cleanup.

### Lifecycle verification

Completed worktrees end either in verified deletion with no unique data, or in a verified compact archive followed by source removal. Active ownership, open work and safety blockers are temporary states, not permission for unconditional deletion. Full recovery copies are a separate store: compact retention never deletes or migrates them. Migration must account for ignored files, Git administrative state and base-object availability before discarding the full copy.

Run `bash .agents/scripts/tests/test-worktree-archive-helper.sh` and `python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py`. The latter restores 33 local commits including a merge into a repository containing only the `develop` base, after removing the original fixture worktree. It compares HEAD, parent topology, index, binary staged/unstaged patches, status, executable modes, symlinks and untracked contents, and checks retention preview/apply, age/size limits, pins and unsafe/corrupt archives. Ignored files are deliberately excluded; the common repository's base objects must remain available. `test-cleanup-worktrees-async.sh` covers scheduling policy and failure isolation.

The separate producer CLI fixture includes ignored data and exact HEAD/index/draft
bytes, removes its disposable source, then restores after making the original
repository unavailable. It reports source, archive and transaction metadata allocated
bytes separately (`du -sk` multiplied by 1024); these are not installed-store savings.
Incomplete host CWD visibility produces an explicit skip with the source preserved.
On Linux, an isolated user/PID namespace can exercise the native guard without
changing observer policy: run the existing suite through
`unshare --user --map-root-user --pid --fork --mount-proc`, with native tools on PATH.
Never use namespace isolation to hide processes holding real operator worktrees.

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
