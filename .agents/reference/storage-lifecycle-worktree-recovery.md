---
description: Recovery archive evidence, planning, apply, and automatic maintenance contracts
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Recoverable Worktree Archives

| Need | Contract |
| --- | --- |
| Capture or inspect archives | [Current producers](#current-compact-producers), [legacy evidence](#legacy-full-recovery-buckets) |
| Convert a legacy bucket without deleting it | [Compact migration](#explicit-compact-migration-no-retirement) |
| Remove a verified migrated source | [Confirmed retirement](#confirmed-retirement-of-migrated-buckets) |
| Deploy and verify Pulse compaction | [Host rollout](#pulse-host-rollout-and-verification), [retry scheduling](#archive-migration-retry-scheduling) |
| Review retention candidates, then apply | [Planning](#inventory-and-retention-planning), [confirmation-bound apply](#confirmation-bound-apply) |
| Diagnose legacy retention or cache pruning | [Automatic maintenance](#bounded-automatic-maintenance), [process visibility](#process-visibility-diagnostics) |

## Safety and recovery evidence

Recovery snapshots cannot be deleted on age, size, disk pressure or session history alone. Follow the separate [migration](#explicit-compact-migration-no-retirement), [retirement](#confirmed-retirement-of-migrated-buckets), [planning](#inventory-and-retention-planning), [manual apply](#confirmation-bound-apply) and [maintenance](#bounded-automatic-maintenance) contracts.

Maintenance failures emit JSON with `outcome: failed`, stage and stable reason code even without jq. Async cleanup logs stdout, stderr and actual exit code locally on success and failure; reason codes contain no archive paths or raw errors.

Resume pending transactions once per pass; after three failures, quarantine the exact transaction in unique `quarantined/pending.*` with a mode-0600 reason/attempt receipt, then select fresh work. Quarantine preserves archives, reservations, completion files and retention-trash journals; it grants no apply authority. Identity, journal and lock checks remain required. Symlinked/non-regular retry metadata fails closed; invalid regular records exhaust the budget and remain unchanged. Repair requires the original plan and evidence.

## Current compact producers

Manual removal, classified cleanup, profile publication and Pulse profile cleanup use one verified compact transaction, not full copies. The default is `$HOME/.aidevops/recovery/archives` everywhere; the archive-root override precedes historical trash-root overrides. Discover archives with `list --output-root <effective-root>`. Listing/verification grants no deletion authority; pins and removal guards remain unchanged. The [producer contract](../scripts/worktree-archive-helper.md#recoverable-producer-transactions) defines root precedence, journals, restoration and retries.

## Legacy full recovery buckets

Legacy storage defaults to macOS `$HOME/.Trash` (OS Trash semantics), otherwise framework-owned `$HOME/.aidevops/recovery/worktrees`, protected from normal “Empty Trash”. Override with absolute `AIDEVOPS_WORKTREE_TRASH_ROOT` or legacy `AIDEVOPS_ORPHAN_TRASH_ROOT`.

Historical `aidevops-worktree-recovery-v2` evidence binds Git identity, creation time, producer/context, optional session identity, completion, source-removal outcome, `framework` ownership, `recovery` class and `manual-review` policy. Completion follows integrity/identity validation; successful native removal atomically changes `pending` to `removed`. `manual-review` is format compatibility, not deletion authority: manual confirmation or a policy-bound automatic plan must revalidate the exact bucket.

Readers accept complete platform-storage-transition v1 buckets and markerless legacy v1 buckets with valid original Git recovery structure. Never reinterpret partial v2 evidence as v1. Older readers reject v2, failing closed without archive damage.

Historical full-copy producers reserve one attempt per physical source identity. Interrupted attempts stay reserved: retries neither duplicate buckets nor erase partial snapshots. Incomplete reservations require operator review and preservation proof before discarding data. Reuse requires matching Git identity, non-cache contents and index; changed/unreadable sources preserve both copies. Markerless buckets remain unknown, never automatically adopted.

## Explicit compact migration (no retirement)

For one complete, attributed bucket in the configured recovery root:

```bash
bash .agents/scripts/worktree-recovery-lifecycle-helper.sh migrate \
  --bucket /absolute/recovery-root/aidevops-worktree-cleanup-example \
  --repo owner/repo --base-branch main
```

New captures use the [single compact format](../scripts/worktree-archive-helper.md#recoverable-producer-transactions): exact base/HEAD, incremental commits, staged/unstaged patches and ordinary untracked files. Standard Git ignores apply; raw administration is excluded. Capture reports `archived`, not restore-verified, and never retires, rewrites or moves the source. Retain the exact shared base; deletion requires guarded manual retirement or automatic compaction. Existing receipts retain their policy; `AIDEVOPS_WORKTREE_RECOVERY_POLICY=preserve-v1` is read-only compatibility, not a new-capture option.

The private journal is `<recovery-root>/.compact-migrations/<bucket>/journal.json`. It binds physical identities, the source snapshot, opaque recovery provenance, the archive manifest digest, capture outcome and available allocated byte counts.
The archive remains in the existing archive store beneath `.legacy-migrations/<source-path-digest>/`, pinned against expiry. Path-bearing provenance is historical evidence, not live Git configuration or process ownership authority.
Journals and archive artifacts are fsynced before completion is reported; only verified, identity-fenced restore scratch is removed.

Legacy-preservation receipts reserve private scratch with a journaled inode and inherited writer lock; pre-existing repositories are never adopted. Cleanup journals a random quarantine name, renames the reserved container and rechecks identity/content before removal. Replacements, late writes and interrupted removal remain for review. These are not user workspaces; sampling cannot fence malicious same-user writers.

Retries reuse the reservation and completed capture; source drift, changed manifest or invalid identity fails closed.
Captures lacking a complete manifest stay incomplete: retry never allocates another copy. Do not delete journals or partial artifacts to force retry.
Complete captures can resume restoration/verification; completed receipts require fresh source/archive verification before reuse.

Unsupported untracked metadata and unknown administrative state remain protected; tracked changes use Git's modes. Git-only capture preserves current HEAD history, changes and ordinary untracked data, excluding abandoned reflog-only and non-merge previous-HEAD history. Legacy preserve-v1 still retains raw history.
Missing objects or incomplete completion/ownership metadata block verification. Markerless v1 compatibility does not confer migration eligibility.

### Standalone AUTO_MERGE preservation

The unified format supports a standalone `AUTO_MERGE` diagnostic tree: a regular, non-symlink administrative file with a complete object ID referencing an existing tree.
The source fingerprint's optional `auto_merge` binds required `auto-merge-v1.json` metadata (`schema: 1`, matching `tree`) in the normal artifact size/hash inventory.
Older readers reject this unknown required artifact rather than restore incompletely. Archives without it retain their existing read path; no migration, backfill or alternate archive mode is needed.
The existing `commits.bundle` retains recursive trees/blobs through named preservation tips, excluding objects reachable from the recorded base. Capture adds no shared-repository objects or refs.
Independent verification imports only the retained base graph and bundle, checks tree type and complete object closure, and refuses unavailable dependencies.
Restore imports preservation tips and writes `AUTO_MERGE` to actual target Git administration, never its working-file tree. Imported tips survive GC.
Measure per-archive bundle bytes separately from base bytes. Pruning another archive cannot remove this bundle; the recorded base must remain available.
Standalone AUTO_MERGE is diagnostic state, not a resumability claim. Supported unfinished merges use the required structured contract below.
Private-ref, process, source-drift and retirement guards remain enforced; AUTO_MERGE alone grants no removal authority.

### Resumable interrupted merges

Supported merge captures remain in the single compact format. Required manifest fields are `merge_policy: structured-v1`, schema-4 source fingerprint and `self_contained: true`.
The size/hash inventory requires `merge-state-v1.json` and `commits.bundle`; the two patch artifacts are empty. Older readers reject schema 4/unknown required artifacts rather than restoring incompletely.
Existing schema-2/3, standalone AUTO_MERGE and legacy preservation archives retain their read paths; no bulk conversion or second archive mode is introduced.

| State | Support |
| --- | --- |
| HEAD, ordered MERGE_HEAD parents, MERGE_MSG, required ORIG_HEAD | Preserved byte-for-byte; object IDs and commit types validated |
| MERGE_MODE absent, empty or `no-ff` | Preserved; unfamiliar modes refused |
| AUTO_MERGE present or absent | Optional validated comparison tree and full closure |
| Content, add/add, modify/delete, ordinary rename, binary conflicts | Structured index stages 1/2/3 and exact working bytes |
| Partial resolutions, staged files/deletions, resolve-undo | Stage 0 and REUC rebuilt through Git update-index; no raw index copy |
| Regular files, executable modes, ordinary untracked files | Captured independently of index stages; untracked payload remains fingerprint-bound |
| Symlinks in HEAD/index/working paths, submodules, directory/file conflicts | Refused conservatively, retaining source |
| Rebase, cherry-pick, revert, sequencer, autostash, unknown admin state | Refused, retaining source |
| Split/special index flags, intent-to-add, filters, shallow history | Refused |
| Private refs/config, unique message drafts, nonempty FETCH_HEAD | Refused until separately preservable |

Paths use hex-encoded Git bytes, not newline parsing. The bundle retains the complete closure of HEAD, merge parents, required ORIG_HEAD, AUTO_MERGE and index/resolve-undo blobs through named preservation tips.
It deliberately does not subtract the shared base: merge parents and required operation objects need not be ancestors of HEAD. Source loss and subsequent ordinary GC therefore do not remove required objects.
Measure archive bytes separately from incremental shared-base bytes (capture adds zero shared-base bytes).

The schema-4 guarantee is **current-state preservation**, not arbitrary historical reflog recovery. It preserves unpublished current HEAD history and required operation objects even when otherwise reachable only through operation references or reflog; it does not preserve raw reflogs or abandoned historical states.
Ordinary Git-only capture uses that current-state history policy too; legacy preserve-v1 comparisons and required structured merge history are unchanged.

Restore validates artifacts/object closure before modifying a new target, reconstructs files/index with hooks disabled, and writes validated metadata to target Git administration. It never executes hooks or `merge --continue` itself.
Self-contained merge restores work without the original common repository. The user completes remaining resolutions and runs `git merge --continue` normally.
Managed removal compares an independent restored snapshot and unchanged source; schema-4 migration retirement additionally performs a fresh isolated restore/comparison under its operation lock.
Corruption, missing objects, unsupported metadata, failed comparison or source drift retain source/journals. No production deletion, historical reflog deletion or forced production GC is authorized by capture or these disposable tests.

An existing migration reservation makes legacy planning and stale-plan revalidation return `compact-migration-protected`.
Maintenance counts that reason separately instead of treating migration as expiry authority. A receipt's `verified` phase is point-in-time evidence, never sufficient removal permission.
The command reports `bucket_bytes` (null when not measured), `archive_bytes`, `source_retired: false` and
`reclaimed_bytes: 0`; creating an archive alone does not reclaim disk space.

## Confirmed retirement of migrated buckets

Use `worktree-recovery-lifecycle-helper.sh` with the configured recovery root:

1. Run `retire-plan --bucket <absolute-bucket-path>` and inspect the report.
2. Run `retire --bucket <same-path> --confirm <confirmation_token>` with that exact token.
3. Inspect `retire-status --bucket <same-path>`, even after the original bucket disappears.

Require verified migration, unchanged source identity/content, and fresh bound-archive verification against the recorded manifest and available base. Legacy self-contained receipts remain readable.
Registry, interactive-claim and Git worktree-reference guards must be clear. Positive CWD matches block, including matches in the private removal transaction. For a recognized complete v2 recovery bucket with recorded original source removal, `archive-migration` permits degraded CWD visibility without historical worker-lifetime proof. Initial capture validates the physical storage contract, completion marker and Git recovery identity; the private migration journal binds that provenance and source snapshot. Failed observation (rather than degraded visibility), live references and conflicting ownership still block. Active worktree-to-archive transitions retain their existing process/lifetime guards; arbitrary directories and incomplete buckets gain no eligibility.

Under producer and migration locks, journal a randomized private transaction and rename the bucket into it. Compare physical content again without rewriting relocated Git pointers; recheck archive and ownership/process evidence before descriptor-anchored removal.
A replacement at the original name is never a deletion target. As with migration scratch, transaction directories exclude cooperating writers; content sampling cannot exclude malicious same-user writers.

Git-only retirement, producer source-removal checks and managed archive construction run ordinary restore, including integrity/object validation and payload application, into an owned detached verification worktree.
`--registered-verification-copy` uses shared registered creation without issue claiming, dependency installation or hooks; it does **not** skip validation. Default and older `--verification-copy` behavior are unchanged.
Git snapshots compare HEAD, index, patches, ordinary untracked contents and supported merge/AUTO_MERGE state.

Canonical policy continues to reject both `fetch` and `bundle unbundle` against the canonical checkout. Shared restoration creates its owned linked worktree at the recorded base before importing the bundle through that target, using the normal Git shim. `bundle verify` and object-only `bundle unbundle` import all preservation objects without updating shared `refs/archive/*` or `FETCH_HEAD`; the owned worktree then moves to the saved HEAD before payload application. Structured merge and AUTO_MERGE restoration use the same ref-free preservation import. Artifact/object-closure verification, creation receipts, snapshot comparison, dependency seals and exact-owner cleanup remain required.

The existing retirement/producer journal or managed registry `archive_operation` stores `canonical_restore`: operation, source generation/identity/snapshot, archive location/inode/content digest, manifest/capture schema, base identity and scratch registration.
Creation records the actual creating PID, unique verification task and exact registry/owner generation before applying payloads. Sealing and cleanup must still match that receipt; they never adopt a replacement registration.
States are restoring, compared, cleanup-pending and cleaned. Unsealed partial restores stay accounted for in private slots for inspection, never adopted as deletion baselines.
Sealed cleanup checks exact registry/owner rows and target identity/content inside a SQLite write transaction, removes Git administration through Git and removes matching registry rows. After native removal, retries can finish registry/empty-container cleanup without deleting replacement targets.

Only one uninterrupted automatic-retirement invocation shares its in-memory proof between planning and claim/removal barriers. Each barrier rehashes archive and physical base object-store contents, never trusting `verified=true`, a pathname or an inode alone.
Existing dependency files must remain unchanged across restoration; imports may add archived objects. External alternates and symlinked object stores are unsupported, including additions during verification. Producer/migration invocations restore again after restart, not load receipts as authority.
Managed native-removal gates may hold SQLite's writer lock: they require the bound cleaned canonical receipt and freshly revalidate all artifact hashes/object dependencies and source state, without trying to register another worktree inside that lock. Same-invocation construction reuses its process-local proof instead of repeating graph preparation.
Source fingerprints, source/writer/admission guards, secure claim and descriptor-anchored removal remain independent. Neither advisory locks nor content comparisons exclude arbitrary same-UID mutation or already-open writers.
No performance improvement is implied: measure base hashing and source scans separately.

| Interrupted/historical state | Conservative transition |
| --- | --- |
| Planning or restoring, owned empty slot | Revalidate source/identities and retry; no duplicate archive |
| Restoring with unsealed mutable copy | Retain source, archive and accounted scratch for inspection; never adopt it as proof |
| Compared or cleanup-pending | Finish exact-owner cleanup, then restore/revalidate before authority resumes |
| Cleaned producer/migration proof in another invocation | Fresh canonical restore; no persistent cross-operation verified cache |
| Managed verified Git-only journal without canonical receipt | Native removal refuses; explicit prepare may reconstruct proof for unchanged source |
| Old restore-verified scratch or unsupported preserve-v1 retirement | Retain originals; public archive readers/restores remain compatible |
| Claimed/removing source | Revalidate archive/dependencies, writer guards and physical claim fingerprint; uncertain partial removal stays unresolved |
| Retired | Historical receipt only; status/retry is not newly reclaimed storage |

Timings propagate attempt and parent-stage identity into Git preparation/base-import subprocesses. Canonical restore, comparison, dependency seals, source fingerprints, safety guards, claim/removal and verification cleanup remain distinct stages. Durations are inclusive: subtract direct children for exclusive stage totals; never add overlapping parent/child durations. Timing failure never changes authority.

The journal is `.compact-migrations/<bucket>/retirement.json`. Retain reservations and archive pins for audit/recovery, not expiry. Interrupted claims resume with the same token only after revalidation.
Before removal, persist a bounded physical entry inventory in the exact retirement journal. Failed removal remains incomplete and retryable: a `removing` retry requires the same private container and bucket identity and accepts only unchanged surviving entries from that inventory. New or modified entries, missing inventory and substituted identities stay incomplete for review. A missing staged bucket can finish only from the journaled `removing` state in its unchanged, empty private container, after fresh restoration and safety checks; absence alone never proves retirement. Inventories exceeding the journal budget retain the claimed source. Never delete journals or alter receipts to force continuation.

Reports separate measured `bucket_bytes`, `archive_bytes` and `retired`: allocated-size observations, not free-space proof on shared, compressed or snapshotting storage. Archive expiry needs separate authority.

### Automatic verified compaction

Pulse invokes `worktree-recovery-maintenance-helper.sh compact`; see the
[compaction contract](../scripts/worktree-archive-helper.md) for bounds, journals and controls.
It reuses migration/retirement guards across all named recovery buckets, not only Pulse sources.
The caller chain is maintenance `compact` → `worktree_recovery_compact.py` → lifecycle `compact` → `worktree-recovery-migrate-helper.sh`. New work enters `worktree_recovery_migrate.py --retire-automatic` after producer-locked physical validation; existing retirement journals enter `worktree_recovery_retire.py retire-automatic`. Both converge on `automatic_retire`, canonical independent restoration and the private claim/removal transaction. `worktree_recovery_legacy_policy.guards` selects the scoped archive-migration guard for completed v2 copies. Managed active-source producers continue through `worktree_lifetime_archive.py` and `worktree_archive_receipt.py`; this transition does not change their receipt or lifecycle contract.
Authority `verified-git-changes/v1` requires schema-3/4 untracked preservation, completed original
removal and an available external base. Manual plans are not adopted; interrupted automatic
journals resume without treating missing paths as success. Unsupported/active sources remain intact.
Deploy on each machine and measure actual reclaimed space; merge alone does neither. Use the [Pulse host rollout procedure](#pulse-host-rollout-and-verification).

## Pulse host rollout and verification

A merged PR, matching `VERSION` or successful service exit is not rollout acceptance. Verify each approved Pulse host independently; keep host aliases, paths, logs and task content in private operational storage, never in public issues or this file.

1. **Source and inventory:** every dependency merge commit must be an ancestor of the deployment revision (`git merge-base --is-ancestor <merge-commit> <deploy-rev>`); never deploy unmerged branch code. Take hosts only from operator-approved secure configuration: SSH config entries, GitHub runner logins and claim comments are not approval or access evidence. Unlisted or unreachable hosts stay `unverified`.
2. **Baseline (read-only):** `~/.aidevops/.deployed-sha` versus the deployment revision; sha256 of installed lifecycle scripts versus the source worktree; `worktree-lifecycle-helper.sh report --summary` (registry states, archive bytes, free bytes, scheduler); user scheduler status (`systemctl --user list-timers` on Linux, launchd elsewhere); `df` and user quota where the host provides `quota`.
3. **Deploy:** use the existing auto-update or `setup.sh --non-interactive` / `--stage agents` from a linked worktree of the merged revision. Never patch installed files, restart or kill running workers, or delete their runtime bundles to force adoption.
4. **Canary:** on one capable host run the focused dependency tests from the merged source (`test-dispatch-single-issue-helper.sh`, `test-worktree-managed-lifetime.py`, `test-worktree-archive-lifecycle.py`). In an isolated disposable repository, verify automatic and manual launches, process identity, provenance/generation, verified completion/sealing, archive-location receipt, independent restore and source removal. A registry sample or passing fixture alone is not installed-runtime acceptance. Older launches keep their recorded generation and bundles.
5. **Cleanup route and fleet:** confirm in `cleanup_worktrees.log` that the normal Pulse cycle runs `lifecycle-reconcile` and `recovery-maintenance` (`aidevops.worktree-recovery-compaction-pass/v1`) with durable outcomes. Report `source_bytes_retired` and per-pass reclaimed bytes separately from concurrent growth; never lower age thresholds or bypass guards to show progress. After canary acceptance roll out sequentially; stop at the first reproducible regression and record remaining hosts plus the resume condition.

**Rollback:** redeploy the previous merged revision with the same tooling. Keep registry rows, archives, journals, receipts and quarantined transactions; older readers fail closed on newer schemas rather than discarding them. **Status:** `verified` (every step evidenced on the host), `partial` (deployed and observed, criteria open) or `unverified` (no approved access or evidence); only `verified` counts toward completion.

**GH#35298 / GH#35359 record:** on 2026-10-22, reverified all three dependency PRs merged and their revisions ancestors of selected merged source `d9f581f89`: GH#35295 (`7e8d6e485`), GH#35296 (`07eed271a`), GH#35314 (`b7e8cbdfd`). Installed revision remains `25ed1c4f3`; managed-lifetime, lifetime-archive and archive-helper SHA-256 values match selected source. Local configuration enables Pulse but supplies no approved fleet inventory/access. This checkpoint does not authorize inferred hosts, resolve earlier archive timeouts or complete GH#35359; resume remote rollout only with approved targets/access or explicit operator narrowing, after canary acceptance.

| Host | Platform / scheduler | Status | Evidence summary |
| --- | --- | --- | --- |
| canary-1 (dispatching Pulse host) | Linux, user systemd | partial | Historical: archive lifecycle 98/101, with compact, automatic-retirement and manual-removal fixtures exceeding 60s under host load; scheduled launch provenance, generation and systemd-user-service binding; running/sealed registry samples; scheduled reconcile/compaction emitted durable `retained` outcomes and 0 source bytes retired. GH#35359 recheck: installed SHA/checksums unchanged; dispatch 94/94; managed lifetime 25 tests, 2 skipped; full archive suite exceeded a 300s bounded invocation, not a pass. User scheduler observed; `quota` still unavailable (`df` only), no reclamation measured. Open: installed-runtime canary acceptance, retention backlog (hard-link/special-permission and process-unavailable reasons, deadline-bounded passes, timed-out dry run) and preserved failed compact capture; timeout/backlog implementation investigation remains separate from this rollout |
| Other Pulse hosts | Unknown | unverified | No approved host inventory or remote access in secure local configuration; operator input required |

#### Archive migration retry scheduling

Each bucket's private `.compact-migrations/<bucket>/retry.json` is a scheduling hint, separate from worker lifecycle and the authoritative migration/retirement journals. Atomic `publish`/`load` and a distinct `retry.lock` protect `pending`, `running`, `retry_wait`, `blocked` and `completed` records. Fields bind input identity and `migration_revision`, with `last_attempt_at`, `next_attempt_at`, `consecutive_failures`, `failure_code` and `failure_stage`; no transaction phase or verification authority is duplicated.

Before expensive compaction, inspect bounded provenance, root/bucket/journal/base identity, working-root/HEAD/index and archive artifact stat evidence. Invalid or replaced scheduling data fails closed. This is not a content-preservation proof: nested working-file edits can require explicit retry. All physical validation, positive-use checks and producer/migration locks still run for due work. A persisted `running` status or elapsed deadline never proves a writer dead or authorizes breaking its locks.

Known transient codes back off 15 minutes, 1 hour, 6 hours and 24 hours, with up to 10% positive jitter capped at 24 hours. Proven lock contention waits 10–15 minutes without increasing failures. Unsupported state, corruption, restore mismatch and unmapped failures block until observed input identity or the content hash of the explicitly listed migration implementation files changes, or an operator requests retry. Generic framework version/release changes do not reset schedules. Expensive work still uses at most ten rotating entries/120 seconds and one retirement per pass; advancing the cursor past not-due entries preserves coverage.

Failed restore reports and maintenance entries include the outer/child exit status, captured child-stderr SHA-256, recognized Git operation and fixed error hints when available. Raw stderr, commands and private paths are not copied into these diagnostics. A reference-lock or ownership-transaction hint is diagnostic only: unknown failures remain blocked, and hints never justify lock removal or retirement. The digest correlates failures without retaining their raw contents; it cannot reconstruct previously discarded stderr.

Space admission uses cheap free-space observations on the recovery/archive filesystems (64 MiB minimum headroom, not a capacity guarantee). After ENOSPC, require at least 64 MiB more observed headroom before another expensive attempt; due low-space checks defer without recapture or increasing failures. Existing capture/retirement reservations resume through the original CLI; retry scheduling never deletes partial artifacts, reopens a completed capture or supplies restore/removal proof. If the final scheduling write is interrupted after retirement, reconcile from the exact bound retired receipt without running compaction or reporting newly reclaimed bytes; path absence alone is insufficient.

To reset scheduling only, run `python3 .agents/scripts/worktree_recovery_compact.py --root /absolute/recovery-root --state /absolute/maintenance-state/compaction --retry-bucket aidevops-worktree-cleanup-example`. It writes `pending` and exits without compacting; the next maintenance pass must pass every ordinary gate. Invalid/symlinked journals require inspection rather than forced replacement. No retry command authorizes production cleanup by itself.

## Inventory and retention planning

### Fast legacy Pulse eligibility statistics

`worktree-helper.sh recovery legacy-report` (also exposed by the lifecycle helper) reads bounded metadata from the default recovery root:

- `--details`: local bucket/source paths, source inode, creation date and reasons.
- `--root`, `--registry`, `--ledger`: alternate local evidence.
- No recursive sizing, source reads, Git/network calls, process scans, restores or mutations. Byte totals are unmeasured; elapsed time excludes interpreter/shell startup.

Existing lifecycle records use the lifecycle path; unknown/profile origin is retained. Name-classified legacy Pulse requires a UTC creation time at least seven days old: a prefilter, not verification or deletion authority.

**Provenance limitation:** `producer`, `producer-context` and `session-id` identify the archiver, not the creator. Separately counted dispatch path matches do not bind a generation. Legacy classification uses the actual Pulse dispatcher name pattern shared with [legacy Pulse compaction](legacy-pulse-compaction.md), without extra flags. Names are policy conventions, not lifecycle evidence. Raw-copy expiry is unchanged; recorded state is not successful `proof`. Manual data and final compact archives gain no expiry.

Historical copying excluded proven ignored, untracked cache roots before IO, including roots nested below broader ignored directories. Git evidence failure stops copying, never falls back to an enormous unfiltered copy. Tracked files, symlinks and unknown ignored content stay protected. This prevents bounded cleanup timeouts from repeatedly copying dependency trees before pruning them.

Run `worktree-helper.sh recovery` for read-only legacy-bucket counts/bytes and protected/unknown reasons. Shared storage status exposes the same summary as one `worktree-recovery` record; `reclaimable_bytes` is zero because inventory grants no deletion authority.
Non-macOS inventory also includes attributable legacy `$HOME/.Trash/aidevops-worktree-cleanup-*` buckets. Keep framework defaults distinct from joint OS Trash and operator-selected roots.
Incomplete, symlinked, unrecognised or unsized buckets are `unknown`; inventory never migrates, rewrites or deletes them. Entry-local `sizing_error` is not structural `error`. Any unsized entry makes aggregate bytes unavailable, without invalidating independently exact entries.

Run `worktree-helper.sh recovery plan --output <absolute-path>` for a versioned `aidevops.worktree-recovery-plan/v2` JSON review artifact. Publish a complete mode-0600 temporary file atomically beside a new absolute, non-symlinked, writable output path; never replace an existing path. Generation never moves, rewrites or deletes recovery buckets/archives.

Planning inventories structure first, then checks full evidence and exact size only within a bounded window:

| Control | Default / behavior |
| --- | --- |
| `--max-classify <1-1000>` | 100 entries |
| `--offset <non-negative-integer>` | Continue from `next_classification_offset` |
| `--deadline-seconds <1-3600>` | 120 seconds, checked between entries |
| Outside window / timed out | `unknown`: `classification-deferred` / `classification-deadline-exhausted` |

Plans record completeness, classified/deferred counts, deadline state and both offsets for independent inspection/reclamation windows, not an unbounded pass or authoritative size cache. Deferred entries grant no deletion authority.

The envelope binds producer, generation time, deterministic plan ID, inventory completeness/errors, source roots, reconciled entry/byte totals and ordered `candidate`, `protected`, `unknown` entries. Incomplete global inventory yields no candidates; local sizing failure downgrades only its entry.
Each attributable entry binds physical bucket/archive paths, format, Git HEAD/branch, source/admin/common identity, archive index/completion-marker digests, expected allocated bytes, observed local/remote evidence, disposition and reason codes.
Unchanged evidence yields identical entries/plan ID; generation time is observational. The v2 token binds plan ID, exact candidate count, expected allocated bytes, schema and permanent-delete action. Never upgrade earlier or tokenless plans into destructive authority.

Candidate status requires a complete valid archive, completed source removal, clean tracked/untracked/user-ignored Git state, an exact terminal commit, no open PR or live Git worktree/registry/claim/process reference, and exact readable sizing.

Ignored, untracked directories with these regenerable-cache identities do not dirty an otherwise clean legacy archive:

| Location / identity requirement | Approved roots |
| --- | --- |
| Any depth | `node_modules`, `.pnpm-store`, `.yarn/cache`, `.next/cache`, `.nuxt/cache`, `.turbo`, `.parcel-cache`, `.vite`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` |
| Regular `pyvenv.cfg` required | `.venv`/`venv` |
| Regular `PKG-INFO` required | `*.egg-info` |
| Repository root only | `.codegraph`, `.astro` |

Ignored, untracked aidevops state at exact root paths (`.agents/loop-state/`, `.agents/tmp/`, `.agents/.full-loop-cleanup-deferred`, `todo/batches/*.json.lock`) is not user data; remove it only with its whole bucket. Generic `dist/` and `build/` lack identity evidence and stay protected.

Positive live/unfinished evidence is `protected`; missing APIs, process visibility, identity, validation or sizing is `unknown`. Reread identity and allocated bytes immediately before emitting each entry; concurrent drift downgrades only that entry. Age, size and OpenCode/Claude session history never prove reclaimability. Plans alone grant no deletion authority.

### Terminal publication evidence

Branch-backed archives require an exact merged PR head and closed linked task. Detached archives lack branch-keyed claims/linked tasks and use these publication contracts:

| Detached archive | Required evidence / disposition |
| --- | --- |
| Profile publication scratch-worktree, exact v2 producer identity | GitHub independently proves archived HEAD is the merge base of the current default-branch tip. Changed producer/context, unavailable API, non-ancestor commit, dirty state or live local reference preserves the bucket |
| Other v2, any producer with recorded `created-at` | `protected` / `detached-within-retention` until `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS` (default seven days, manual and automatic paths). Missing/unparsable creation evidence is `unknown` / `retention-evidence-unavailable`; never substitute bucket mtime |
| Other v2 after retention | `candidate` / `detached-head-published-retention-elapsed` only with the same GitHub merge-base publication proof, completed source removal, clean Git state and clear worktree/registry/process evidence. Unpublished HEAD: `exact-commit-not-published`; unavailable APIs/process visibility: `unknown` |
| Legacy detached, no v2 creation evidence | `detached-or-unresolved-branch` |

Confirmation-bound and automatic apply accept both detached candidate reasons and revalidate all evidence before moving anything. Recognise exact producer identity before external publication proof: early failures report their owning stage (for example `process-evidence-unavailable`), not an unsupported detached branch. Recognition grants no deletion authority; candidacy still requires provenance and publication proof.

### Protected mixed archives

Automatic maintenance may prune the same approved cache roots without deleting a protected mixed archive. Require dirty state, completed source removal, elapsed maintenance retention (default 7 days) and clear worktree/registry/claim/process evidence. Unmerged commits and open tasks may remain; PR evidence must be clear.

Each root must be an exact ignored, untracked approved directory without symlink components, tracked paths or hard-linked regular files. A bounded manifest binds device/inode identity and allocated bytes. Uncertainty, deadline exhaustion, Git output beyond the fixed capture ceiling or drift preserves the root.

Ordinary planning short-circuits on dirty state; automatic maintenance completes downstream evidence even for unmerged commits, and cache apply repeats the snapshot. Age uses created-at or legacy bucket mtime; unknown age retains roots. Whole-archive rules are unchanged.

## Confirmation-bound apply

After reviewing a v2 plan, an operator may run:

```bash
worktree-helper.sh recovery apply \
  --plan <absolute-path> \
  --receipt <absolute-new-path> \
  --confirm <manifest-token>
```

Apply requires the exact supported producer manifest and bound token. Reject relative/symlinked inputs, mismatched existing receipts/reservations, unsupported schemas, duplicate paths/identities, candidates outside attributable recovery roots, and summary/digest mismatches. Creation and apply share an exclusive producer lock binding PID, process start time and owner token. Live, malformed, ambiguous or unverifiable ownership blocks mutation; reclaim only conclusively stale ownership.

Under lock:

1. Create/validate a mode-0600, plan-bound `aidevops.worktree-recovery-apply-reservation/v1` at the requested receipt path, preventing concurrent-plan collisions from losing the post-deletion receipt. Bind a uniquely allocated mode-0600 completion file before mutation; never claim/remove predictable adjacent paths. Exact retries may resume incomplete reservations; different plans or replaced completion files fail before mutation.
2. Revalidate every candidate and all mutable evidence before any move. Recheck exact identity/allocated bytes immediately before each same-filesystem rename into the root's `.retention-trash/<transaction-id>/`.
3. Atomically replace the journal listing permitted original/staged paths. Remove only those entries, never wildcards or newly discovered archives. Empty initialization directories and deterministic journal-next files are recoverable; unrelated artifacts fail closed. Interrupted initialization, rename, journal update or removal resumes only from the exact attributable plan/journal.
4. On success, atomically replace the exact reservation with a mode-0600 `aidevops.worktree-recovery-apply-receipt/v1` binding plan/transaction identities, confirmation, times, exact paths/archive identities, expected/observed bytes and terminal outcomes.

Replaying the same complete receipt is a no-op; conflicting receipts/reservations fail closed. Protected, unknown, unrelated Trash and new content remain untouched. This command remains the operator-reviewed apply path.

## Bounded automatic maintenance

Legacy `worktree-recovery-maintenance-helper.sh run` retains this policy; Pulse now calls `compact` instead. Legacy retention mutates only the default framework-owned non-macOS recovery root, excluding macOS Trash, configured roots and attributable legacy Trash buckets. Use the manual path's exact classifier/apply transaction: age/pressure selects only candidates meeting every terminal, clean-state, identity, reference and sizing requirement.

| Default limit / trigger | Behavior |
| --- | --- |
| Seven days; earlier above 5 GiB store size or below 10 GiB / 10 percent filesystem free space | Select only evidence-qualified candidates |
| Aggregate-sizing timeout | Conservative `aggregate-size-unavailable` pressure mode, not a disabled store limit; exact per-bucket sizing and terminal evidence still required |
| 50 rotating entries / 120 seconds after cheap enumeration | Validation/classification, including expensive Git checks, shares the cursor window/deadline |
| 20 candidates / 5 GiB | Maximum apply selection |

Classify evidence before whole-archive sizing; candidate-only exact probes use remaining pass budget, and apply revalidates identity/allocated bytes. Protected mixed archives can reach approved cache-root pruning without whole-archive `du`.

### Advisory size index and selection limits

The default framework store writes mode-0600 `.size-index` advisory records at archive
completion and after exact candidate sizing. A separate bounded backfill cursor advances
even on sizing timeout. Fresh hints avoid recursive aggregate scans; `store_size_source`
distinguishes `indexed-estimate`, `exact` and `unavailable` even during filesystem pressure.
Estimates exclude small reservation/index overhead and prove neither exact filesystem
usage nor deletion eligibility. Incomplete indexing or root-level staged transactions
fall back to bounded exact-store measurement, then conservative pressure if unavailable.
Hints expire after 24 hours; completed transactions (including resumed cache pruning)
invalidate affected records. Exclude missing/replaced buckets from the next census.
A broken index never grants mutation authority.

Order inventory largest-estimated-first before cursor rotation and selected exact
candidates largest-first. Include scheduling order in the coverage digest so changed
hints cannot falsely complete old cycles. Rotation still reaches protected/unindexed
entries rather than only the largest protected archive. Seven-day retention and 5 GiB
store limits are evidence-gated soft bounds, never hard quotas authorizing deletion of
unique, active, unreadable or otherwise protected data. Tune with:

- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT`
- `AIDEVOPS_WORKTREE_RECOVERY_AGGREGATE_SIZE_TIMEOUT_TENTHS`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS`
- `AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_ROOTS`
- `AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_BYTES`

Set `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED=0` to disable the automatic
pass. Invalid limits fall back to defaults. Maintenance uses a separate
owner-validated lock and records a policy-bound `automatic-sha256:` authority in
its plan, journal, and receipt; it never synthesizes the manual confirmation
token. Pending transactions under the maintenance state directory resume before
new inventory is scanned, while completed plans and receipts remain available
for audit. Each run result includes bounded diagnostics outside the signed v1
automatic-policy object: inventory/scanned counts, cursor movement, deadline
state, pass coverage, and fixed-cardinality reason counts for unknown and
protected entries.
Exact safe reason buckets distinguish sizing, identity drift, unavailable
evidence, live references, unfinished tasks, retention policy, and selection
limits without exposing archive paths. A private state record accumulates those
counts across bounded cursor windows and resets if the inventory or pressure
state changes. Exact-inventory coverage resets on inventory change, so it never
claims that an old partial scan covered a new inventory. Separately, while
pressure remains active, persistent sustained accounting survives inventory
churn and selected removals or cache prunes (it also totals their selected
bytes); only an empty inventory or the end of pressure resets it. Once its
scanned work reaches the current inventory size, the read-only plan is requested.

### Cache-prune transactions

When protected mixed archives contain approved cache roots, one pass selects at
most 100 roots and 5 GiB by default inside the same scan and deadline budget.
Cache pruning takes precedence over whole-bucket deletion for that pass and uses
its own `aidevops.worktree-recovery-cache-prune-plan/v2` plan (v1 is rejected) and
`cache-automatic-sha256:` authority. Apply revalidates archive and root
identities, ignored/untracked state, allocated bytes, symlink and hard-link
safety, bound retention age/source, and all claim, process, task, PR, and commit evidence
both before the transaction and immediately before each rename. The initial
apply receives the scan's absolute deadline rather than starting a new budget;
an exhausted pass defers every selected cache root without mutation. A pending
transaction receives one fresh bounded deadline only when a later maintenance
pass resumes it. Apply stages only the exact root into an archive-local
`.retention-trash` transaction. Its journal survives interruption before or
after rename or bounded removal. A `removing` journal state permits a timed-out
delete to continue only while the isolated root identity and remaining
allocation stay within the original bound. Pending cache plans resume before
new inventory. Receipts retain the expected allocation, an independent exact
staged-root measurement, and a zero post-delete allocation observation before
reporting those namespace bytes as reclaimed; they do not infer global
filesystem free-space changes from concurrent `df` activity. Run outcomes report
`cache-pruned` or `resumed-and-pruned`. User files and the protected archive
remain untouched.

### Zero-candidate escalation

After pressure-active scanning covers at least one current-inventory's worth of bounded
work, set `escalation.required:true`: reason `pressure-sustained-no-candidates` on
`no-candidates`, or `pressure-sustained-insufficient-reclaim` on `removed`/`cache-pruned`.
A stable full scan records `zero_candidate_cycle.completed_this_run:true`; churn leaves
coverage explicitly incomplete while separate sustained accounting triggers the warning.
The fixed command array directs operators to
`worktree-helper.sh recovery plan --output <absolute-new-path>`: bounded, read-only
remediation, not deletion authority. Retain protected/uncertain buckets; only separately
reviewed manual plans can reach confirmation-bound apply. Maintenance failure preserves
the affected archive and does not fail an otherwise successful broader cleanup cycle.

The escalation records `dominant_reason` and `dominant_reason_count`: the fixed-cardinality
retained reason with the highest count across this run and the accumulated zero-candidate
cycle (ties resolve by reason key). While an escalation is required, maintenance also writes
`~/.aidevops/advisories/worktree-recovery-retention.advisory` with the inventory count,
measured store size, dominant reason, and read-only plan command. It contains no archive
paths or process details, grants no deletion authority, and is removed once escalation
clears; a small reclaim under sustained pressure does not clear it. `preparation-failed`
records add a fixed step `detail` (for example `cycle-state-invalid` or `scan-failed`).

### Process-visibility diagnostics

Only when `process-evidence-unavailable` is dominant, report `outcome:"operator-intervention-required"` with `unsupported-process-visibility`. Minority observations must not override a larger blocker such as detached or dirty archives.
Return only a bounded scan-observation count and fixed guidance: inspect the read-only plan locally and check saved managed-lifetime evidence before diagnosing visibility. Never report process names, command lines, CWDs, usernames or archive paths in this result.

For rootless proof, the classifier accepts a sealed generation matching the archived source path and inode:

1. Check `worktree-lifecycle-helper.sh report --summary` and the source's `worktree-managed-lifetime.py status` record.
2. Repair missing enrollment, unfinished sealing or invalid receipts at the owning lifecycle transition; never fabricate receipts or infer a need for sudo.
3. See `reference/worktree-cwd-visibility.md` for the proof contract and limitations; [shared launch](worktree-registry.md#shared-pulse-and-manual-launch-gh35295) covers Pulse/manual provenance.

The sole operator-invoked output exception is `worktree-helper.sh recovery unreadable-processes` (GH#32853). On a `/proc` host it prints `<pid>\t<comm>\t<remedy>` for each live, non-zombie process not provably foreign-UID whose CWD neither direct read nor the opt-in inspector can read: exactly the entries degrading visibility.

| Platform / UID evidence | `<remedy>` |
| --- | --- |
| Supported non-NixOS Linux; real UID is caller, other UIDs caller or root | `inspector` |
| Supported non-NixOS Linux; inspector UID rule rejects process | `stop-only` (GH#32871) |
| NixOS | `unprivileged-review`; never invoke inspector |
| No `/proc` | Exit 3: `lsof` cannot identify denied processes |

This read-only diagnostic prints only to the terminal, never through automatic maintenance, advisories, logs or plans. The escalation advisory names the command, never its output. Labels do not instruct stopping login/session services; names identify processes, never exempt them.
Without complete visibility or valid managed-lifetime proof, retain affected archives; degraded visibility alone does not block every archive on the host. No deletion authority, root access, weaker kernel protections or trust in process names follows from this outcome. Readable CWD matches still block as live references; all other candidacy/apply invariants remain unchanged.

## Session-history limitations

An originating OpenCode/Claude session identifier guides recovery, not deletion. History may reconstruct text edits/intent but can be archived, unavailable or incomplete; it never proves preservation of ignored/binary files, permissions, symlinks, index state or detached Git metadata. Archive integrity, lock, identity, late-write, detached-HEAD and interruption checks remain authoritative.
