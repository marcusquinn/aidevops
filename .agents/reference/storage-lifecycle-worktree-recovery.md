---
description: Recovery archive evidence, planning, apply, and automatic maintenance contracts
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Recoverable Worktree Archives

## Safety and recovery evidence

Recovery archives are safety snapshots, not generic discarded files. Age, size,
disk pressure and session history never authorize deletion. Use the separate
[migration](#explicit-compact-migration-no-retirement),
[retirement](#confirmed-retirement-of-migrated-buckets),
[planning](#inventory-and-retention-planning),
[manual apply](#confirmation-bound-apply) and
[automatic maintenance](#bounded-automatic-maintenance) contracts below.

Maintenance failures emit JSON with `outcome: failed`, stage and stable reason
code even without jq. Async cleanup logs stdout, stderr and actual exit code
locally on success and failure; reason codes contain no archive paths or raw errors.

Resume pending transactions once per maintenance pass. After three failures, move
the exact transaction into a unique `quarantined/pending.*` state directory with a
mode-0600 reason/attempt-count receipt, then select fresh work. Quarantine neither
deletes archives, reservations, completion files or retention-trash journals nor grants
apply authority; existing identity, journal and lock checks protect unfinished work.
Fail closed on symlinked pending directories/retry metadata or non-regular retry files.
Invalid regular retry records exhaust the budget and remain unchanged in quarantine.
Inspect receipts locally; repair requires the original plan and evidence.

## Current compact producers

New recoverable captures from manual removal, classified cleanup, profile publication
and Pulse profile cleanup use one verified compact transaction, not a full-copy bucket.
The default is `$HOME/.aidevops/recovery/archives` on every platform; the archive-root
override precedes explicit historical trash-root overrides. Use the archive CLI's
`list --output-root <effective-root>` to discover them. Pins and removal safeguards
are unchanged; neither listing nor verification grants deletion authority. See the
[producer contract](../scripts/worktree-archive-helper.md#recoverable-producer-transactions)
for exact root precedence, journal/receipt paths, independent restoration and retry behavior.

## Legacy full recovery buckets

The legacy default root is `$HOME/.Trash` on macOS (OS Trash semantics), but framework-owned
`$HOME/.aidevops/recovery/worktrees` elsewhere: normal “Empty Trash” must not silently
delete those snapshots. Select an absolute root with `AIDEVOPS_WORKTREE_TRASH_ROOT`
or the legacy `AIDEVOPS_ORPHAN_TRASH_ROOT` fallback.

Historical v2 buckets use `aidevops-worktree-recovery-v2` evidence: stable Git identity,
creation time, producer/context, optional runtime session identity, archive completion,
source-removal outcome, `framework` ownership, `recovery` safety class and
`manual-review` policy. Write the completion marker only after archive integrity and
source identity validation; successful native removal atomically advances the source
outcome from `pending` to `removed`.

`manual-review` remains for v2 producer-format compatibility, not deletion authority.
Manual confirmation or a separate policy-bound automatic plan must revalidate the exact bucket.

Readers accept complete platform-storage-transition v1 buckets and markerless legacy
v1 buckets with valid original Git recovery structure. Never reinterpret partial v2
evidence as v1. Older readers reject v2, failing closed without archive damage.

Historical full-copy producers reserved one attempt per physical source identity.
An interrupted attempt remains explicitly reserved; retries do not create another
bucket or erase the partial snapshot. Incomplete reservations require operator
review, including proof that any discarded data is preserved elsewhere. A completed
attempt may be reused only after Git identity, current non-cache contents, and index
comparison succeed. A changed source or unreadable comparison preserves both copies.
Legacy markerless buckets remain unknown and are never automatically adopted.

## Explicit compact migration (no retirement)

For one complete, attributed bucket in the configured recovery root:

```bash
bash .agents/scripts/worktree-recovery-lifecycle-helper.sh migrate \
  --bucket /absolute/recovery-root/aidevops-worktree-cleanup-example \
  --repo owner/repo --base-branch main
```

New migrations use the [single compact format](../scripts/worktree-archive-helper.md#recoverable-producer-transactions):
exact base/HEAD, incremental commits, staged/unstaged patches and ordinary untracked files. Git's standard ignore rules exclude ignored files; raw administrative payloads are not copied.
Capture does not perform a trial restore or archive verification; it reports `archived`, not `verified`. The shared repository must retain the exact base.
Source removal uses the guarded manual retirement transition or automatic compaction policy below; capture alone cannot remove it.
Existing receipts retain their policy. `AIDEVOPS_WORKTREE_RECOVERY_POLICY=preserve-v1` is no longer accepted for new capture; the former preservation format is read-only compatibility.
Migration never retires, rewrites or moves the original bucket during capture.

The private journal is `<recovery-root>/.compact-migrations/<bucket>/journal.json`.
It binds physical identities, the source snapshot, opaque recovery provenance, the archive manifest digest, capture outcome and available allocated byte counts.
The archive remains in the existing archive store beneath `.legacy-migrations/<source-path-digest>/`, pinned against expiry.
Path-bearing provenance is historical evidence, not live Git configuration or process ownership authority.
Journals and archive artifacts are fsynced before completion is reported; only verified, identity-fenced restore scratch is removed.

Legacy-preservation receipts reserve private scratch with a journaled inode and inherited writer lock; pre-existing repositories are never adopted. Cleanup journals a random quarantine name, renames the reserved container and rechecks identity/content before removal. Replacements, late writes and interrupted removal remain for review. These are not user workspaces; sampling cannot fence malicious same-user writers.

Retries reuse the reservation and completed capture; source drift, changed manifest or invalid identity fails closed.
Captures lacking a complete manifest stay incomplete: retry never allocates another copy. Do not delete journals or partial artifacts to force retry.
Complete captures can resume restoration/verification; completed receipts require fresh source/archive verification before reuse.

Unsupported untracked metadata, unknown administrative state and unique reflog-only history remain protected; tracked changes use Git's modes.
Missing objects or incomplete completion/ownership metadata block verification. Markerless v1 compatibility does not confer migration eligibility.

### Standalone AUTO_MERGE preservation

The unified format supports a standalone `AUTO_MERGE` diagnostic tree: a regular, non-symlink administrative file with a complete object ID referencing an existing tree.
The source fingerprint's optional `auto_merge` binds required `auto-merge-v1.json` metadata (`schema: 1`, matching `tree`) in the normal artifact size/hash inventory.
Older readers reject this unknown required artifact rather than restore incompletely. Archives without it retain their existing read path; no migration, backfill or alternate archive mode is needed.
The existing `commits.bundle` retains recursive trees/blobs through named preservation tips, excluding objects reachable from the recorded base. Capture adds no shared-repository objects or refs.
Independent verification imports only the retained base graph and bundle, checks tree type and complete object closure, and refuses unavailable dependencies.
Restore imports preservation tips and writes `AUTO_MERGE` to actual target Git administration, never its working-file tree. Imported tips survive GC.
Measure per-archive bundle bytes separately from base bytes. Pruning another archive cannot remove this bundle; the recorded base must remain available.
This does **not** preserve resumable conflicts: `MERGE_HEAD`, conflict index stages and unsupported operations remain refused. Full `git merge --continue` needs separately scoped metadata/index preservation and continuation verification.
Reflog/ORIG_HEAD, private-ref, process, source-drift and retirement guards remain enforced; AUTO_MERGE alone grants no removal authority.

An existing migration reservation makes legacy planning and stale-plan revalidation return `compact-migration-protected`.
Maintenance counts that reason separately instead of treating migration as expiry authority. A receipt's `verified` phase is point-in-time evidence, never sufficient removal permission.
The command reports `bucket_bytes` (null when not measured), `archive_bytes`, `source_retired: false` and
`reclaimed_bytes: 0`; creating an archive alone does not reclaim disk space.

## Confirmed retirement of migrated buckets

Manual retirement uses `worktree-recovery-lifecycle-helper.sh` and the configured recovery root:
run `retire-plan --bucket <absolute-bucket-path>`, inspect its report, then
`retire --bucket <same-path> --confirm <confirmation_token>` with the exact token.
`retire-status --bucket <same-path>` reports the transaction even after the original bucket disappears.

The migration must be verified, source identity/content unchanged, and the bound
archive freshly verified against the recorded manifest and available base.
Legacy self-contained archive receipts remain readable. Existing registry,
interactive-claim, Git worktree-reference and process guards must be clear.
Positive CWD matches always block; degraded visibility needs a valid saved
managed-lifetime receipt. Missing evidence blocks, without sudo or new enrollment.

The operation holds producer and migration locks, journals a randomized private
transaction, then renames the bucket into it. Physical content is compared again
without rewriting relocated Git pointers. Archive and ownership/process evidence
are rechecked before descriptor-anchored removal. A new bucket at the original
name is never a deletion target. As with migration scratch, transaction directories
exclude cooperating writers; content sampling cannot exclude malicious same-user writers.

The journal is `.compact-migrations/<bucket>/retirement.json`; reservations and
archive pins remain for audit/recovery, not automatic expiry. Interrupted claims
can resume with the same confirmation token after revalidation. Partial removals,
changed contents, missing transaction data or substituted identities remain
incomplete and retained for review; absence alone never counts as retirement.
Do not delete journals or alter receipts to force continuation.

Reports separate measured `bucket_bytes`, `archive_bytes` and `retired`: allocated-size
observations, not physical free-space proof on shared, compressed or snapshotting storage.
Archive expiry remains separately authorized.

### Automatic verified compaction

Pulse invokes `worktree-recovery-maintenance-helper.sh compact`; see the
[compaction contract](../scripts/worktree-archive-helper.md) for bounds, journals and controls.
It reuses migration/retirement guards across all named recovery buckets, not only Pulse sources.
Authority `verified-git-changes/v1` requires schema-3 untracked preservation, completed original
removal and an available external base. Manual plans are not adopted; interrupted automatic
journals resume without treating missing paths as success. Unsupported/active sources remain intact.
Deploy on each machine and measure actual reclaimed space; merge alone does neither.

## Inventory and retention planning

### Fast legacy Pulse eligibility statistics

`worktree-helper.sh recovery legacy-report` (also available directly through the
lifecycle helper) reads bounded metadata from the user's default recovery root.
`--details` adds local bucket/source paths, source inode, creation date and reasons.
`--root`, `--registry` and `--ledger` select other local evidence. No recursive
sizing, source reads, Git/network calls, process scans, restores or mutations.
Elapsed time excludes interpreter/shell startup; byte totals are not measured.

Existing lifecycle records use the lifecycle path; unknown/profile origin is
retained. Name-classified legacy Pulse requires a UTC creation time at least seven days
old. This predicate is a prefilter, not verification or deletion authorization.

**Provenance limitation:** `producer`, `producer-context` and `session-id` describe
the archiver, not the creator. Dispatch path matches are counted separately: they
do not bind a generation. Legacy classification uses the actual Pulse dispatcher
name pattern, shared with [legacy Pulse compaction](legacy-pulse-compaction.md),
without extra flags. Names are a policy convention, not lifecycle evidence.
Raw-copy expiry is unchanged; recorded state is not a successful `proof`.
Manual data and the final compact archive have no new expiry.

The historical copy path excluded proven ignored, untracked cache roots before IO, including cache
roots nested below a broader ignored directory. Git evidence failures stop copying
instead of falling back to a potentially enormous unfiltered copy. Tracked files,
symlinks, and unknown ignored content remain protected. This prevents a bounded
cleanup timeout from repeatedly materializing dependency trees before pruning them.

Run `worktree-helper.sh recovery` for a read-only legacy-bucket count/byte report with
protected/unknown reasons. The same legacy summary appears as one
`worktree-recovery` record in shared storage status; `reclaimable_bytes` remains
zero because that aggregate report grants no deletion authority. On non-macOS systems, inventory also includes attributable
legacy `$HOME/.Trash/aidevops-worktree-cleanup-*` buckets. Framework-owned
default roots remain distinct from joint OS Trash or operator-selected roots.
Incomplete, symlinked, unrecognised, or unsized buckets are `unknown`; inventory
never migrates, rewrites, or deletes them. Entry-local sizing failures are
reported in `sizing_error` and do not become structural `error` failures. The
aggregate byte totals remain unavailable when any entry is unsized, while
independently exact entries retain their own evidence.

Run `worktree-helper.sh recovery plan --output <absolute-path>` to persist a
versioned `aidevops.worktree-recovery-plan/v2` JSON review artifact. The new, absolute,
non-symlinked, writable output path is published atomically from a complete mode-0600
temporary file beside it, never replacing an existing path. Generation is read-only
for all recovery roots and archives: no bucket moves, rewrites or deletions.

Manual planning inventories structure without exact-sizing every bucket, then checks
full evidence and final exact size only within the selected window (default 100 entries).
Tune with `--max-classify <1-1000>`; continue from `next_classification_offset` using
`--offset <non-negative-integer>`. The between-entry deadline defaults to 120 seconds;
tune with `--deadline-seconds <1-3600>`. Outside-window or timed-out entries remain
`unknown` with `classification-deferred` or `classification-deadline-exhausted`, never
deletion authority. Plans record completeness, classified/deferred counts, deadline
state and both offsets, allowing independent inspection or reclamation windows
without an unbounded pass or authoritative size cache.

The envelope records producer, generation time, deterministic plan ID, inventory
completeness/errors, source roots, reconciled entry/byte totals and ordered `candidate`,
`protected` and `unknown` entries. Incomplete global inventory yields no candidates;
local sizing failure downgrades only that entry. Each attributable entry binds physical
bucket/archive paths, format, Git HEAD/branch, source/admin/common identity, archive
index/completion-marker digests, expected allocated bytes, observed local/remote
evidence, disposition and reason codes. Unchanged evidence yields identical entries
and plan ID; generation time is observational. The v2 confirmation token binds plan ID,
exact candidate count, expected allocated bytes, schema and permanent-delete action.
Never upgrade earlier or tokenless plans into destructive authorization.

Candidate status requires a valid complete archive, completed source removal, a clean tracked/untracked/user-ignored
Git state, an exact terminal commit, no open pull request, no live Git worktree/registry/claim/process reference,
and exact readable sizing. Ignored, untracked directories with recognised regenerable-cache identities
(`node_modules`, `.pnpm-store`, `.yarn/cache`, `.next/cache`, `.nuxt/cache`, `.turbo`,
`.parcel-cache`, `.vite`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, and `.ruff_cache`
at any depth; `.venv`/`venv` only with a regular `pyvenv.cfg` and `*.egg-info` only with a
regular `PKG-INFO`; `.codegraph` and `.astro` only at the repository root) do not make an
otherwise clean legacy archive dirty. Ignored, untracked aidevops state at exact root paths
(`.agents/loop-state/`, `.agents/tmp/`, `.agents/.full-loop-cleanup-deferred`,
`todo/batches/*.json.lock`) is also not user data; it is removed only with its whole bucket.
Generic `dist/` and `build/` lack identity evidence and stay protected. Positive live or
unfinished evidence is `protected`. Missing APIs, process visibility, identity, validation, or sizing is `unknown`.
Identity and allocated bytes are read again immediately before an entry is emitted, so concurrent drift downgrades
only that entry. Age, size, and OpenCode or Claude session history never prove reclaimability. Plan files grant no
deletion authority by themselves.

### Terminal publication evidence

Branch-backed archives prove terminal state through an exact merged PR head and
a closed linked task. Detached archives have no branch-keyed claim or linked
task, so they use one of two publication contracts. The profile publication
scratch-worktree producer (exact v2 producer identity) becomes
eligible only when GitHub independently proves the archived HEAD is the merge
base of the repository's current default-branch tip. A changed producer/context,
unavailable API, non-ancestor commit, dirty archive, or live local reference
still preserves the bucket.

Other v2 detached archives (any producer, with recorded `created-at` evidence)
follow a combined retention and publication contract. They stay `protected`
with `detached-within-retention` until their recorded creation time is at
least the retention period old (`AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS`,
default seven days, for both manual plans and automatic maintenance); bucket
mtime never substitutes for missing or unparsable creation evidence, which is
`unknown` with `retention-evidence-unavailable`. After retention elapses they
become `candidate` with `detached-head-published-retention-elapsed` only when
the same GitHub merge-base proof shows the archived HEAD is published on the
current default branch, source removal is complete, Git state is clean, and
worktree, registry, and process evidence are all clear. An unpublished HEAD is
`exact-commit-not-published`; unavailable APIs or process visibility remain
`unknown`. Legacy detached archives without v2 creation evidence remain
`detached-or-unresolved-branch`. Both detached candidate reasons are accepted
by the confirmation-bound and automatic apply paths, which revalidate the full
evidence before any move. Classification recognises
the exact producer identity before external publication proof is available, so
an early evidence failure reports its owning stage (for example,
`process-evidence-unavailable`) instead of misreporting a supported producer as
an unsupported detached branch. Identity recognition grants no deletion
authority: provenance and publication proof remain mandatory for candidacy.

### Protected mixed archives

Automatic maintenance may reclaim those same approved cache roots from an
otherwise protected mixed archive without deleting the archive. This narrower
path requires a dirty archive, completed source removal, an elapsed maintenance
retention period (default 7 days), and clear worktree, registry, claim, and process
evidence. Unmerged commits and open tasks may remain; PR evidence must be clear. Each root must be
an exact ignored and untracked approved directory with no symlink component,
tracked path, or hard-linked regular file. A bounded manifest records its
device/inode identity and allocated bytes; uncertainty, deadline exhaustion,
Git output beyond the fixed capture ceiling, or drift preserves the root.
Ordinary recovery planning short-circuits once dirty; automatic maintenance completes
downstream evidence even for unmerged commits, and cache apply repeats the snapshot.
Age uses created-at or legacy bucket mtime; unknown age retains roots. Whole-archive rules stay unchanged.

## Confirmation-bound apply

After reviewing a v2 plan, an operator may run:

```bash
worktree-helper.sh recovery apply \
  --plan <absolute-path> \
  --receipt <absolute-new-path> \
  --confirm <manifest-token>
```

Apply requires the exact supported producer manifest and bound token. Reject relative
or symlinked inputs, mismatched existing receipts/reservations, unsupported schemas,
duplicate paths/identities, candidates outside attributable recovery roots and summary
or digest mismatches. Archive creation and apply share an exclusive producer lock
recording PID, process start time and owner token. Live, malformed, ambiguous or
unverifiable ownership blocks mutation; reclaim only conclusively stale ownership.

Under lock, create or validate a mode-0600, plan-bound
`aidevops.worktree-recovery-apply-reservation/v1` at the requested receipt path,
preventing post-deletion receipt loss to a concurrent plan's path collision. Bind a
uniquely allocated mode-0600 completion file before mutation; publication never claims
or removes predictable adjacent paths. Exact retries may resume incomplete reservations;
different plans or replaced completion files fail before mutation. Revalidate every
candidate and all mutable evidence before any move, then recheck exact identity and
allocated bytes immediately before each same-filesystem rename into the root's
`.retention-trash/<transaction-id>/`. An atomically replaced journal lists all permitted
original/staged paths: remove only those entries, never wildcards or newly discovered
archives. Empty initialization directories and deterministic journal-next files are
recoverable; unrelated transaction artifacts fail closed. Interrupted initialization,
rename, journal update or removal resumes only from the exact attributable plan/journal.

Success atomically replaces the exact reservation with a mode-0600
`aidevops.worktree-recovery-apply-receipt/v1` receipt containing the plan and
transaction identities, confirmation binding, times, exact paths and archive
identities, expected/observed bytes, and terminal outcomes. Replaying the same
complete receipt is a no-op; a conflicting receipt or reservation fails closed. Protected,
unknown, unrelated Trash, and newly created content remain untouched. This
explicit command remains the operator-reviewed apply path.

## Bounded automatic maintenance

The legacy `worktree-recovery-maintenance-helper.sh run` command retains the retention
policy below. Pulse now calls `compact` instead, as described above. Legacy retention
runs only on the default framework-owned non-macOS recovery root. Exclude macOS Trash, configured roots and
attributable legacy Trash buckets from automatic mutation. Use the manual path's exact
classifier and apply transaction: age/pressure selects only candidates already meeting
every terminal, clean-state, identity, reference and sizing requirement.

Default selection: after seven days, or earlier if the store exceeds 5 GiB or filesystem
free space falls below 10 GiB or 10 percent. Aggregate-sizing timeout enables conservative
`aggregate-size-unavailable` pressure mode, not a disabled store limit; deletion still
requires exact per-bucket sizing and all terminal evidence. After cheap path enumeration,
validate/classify at most 50 rotating entries within 120 seconds; apply at most 20
candidates or 5 GiB. Expensive Git validation shares that cursor window and deadline.
Classify evidence before whole-archive sizing; candidate-only exact probes use remaining
pass budget, and apply revalidates identity/allocated bytes. Protected mixed archives
can reach approved cache-root pruning without whole-archive `du`.

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

If `process-evidence-unavailable` is that dominant reason, maintenance
instead reports `outcome:"operator-intervention-required"` with the fixed
`unsupported-process-visibility` condition. A minority of process-visibility
observations no longer overrides a larger blocker such as detached or dirty
archives. The result includes only a bounded
scan-observation count and fixed guidance: inspect the read-only plan locally
and check saved managed-lifetime evidence before diagnosing process visibility.
The classifier already accepts a sealed generation matching the archived source
path and inode as the rootless alternative to a degraded CWD scan. Check
`worktree-lifecycle-helper.sh report --summary` and the source's
`worktree-managed-lifetime.py status` record; do not confuse missing enrollment,
unfinished sealing or invalid receipts with a requirement for sudo. Repair the
owning lifecycle transition without fabricating receipts. See
`reference/worktree-cwd-visibility.md` for the proof contract and limitations.
The result never reports process names, command lines,
CWDs, usernames, or archive paths. The one operator-invoked exception is
`worktree-helper.sh recovery unreadable-processes` (GH#32853): run manually on
a `/proc` host, it prints `<pid>\t<comm>\t<remedy>` for each live, non-zombie
process that is not provably foreign-UID and whose CWD neither a direct read
nor the opt-in inspector can read. These are exactly the entries that make
visibility degraded. `<remedy>` is `inspector` when the inspector's UID rule
(real UID is the caller; other UIDs are the caller or root) accepts the process
and `stop-only` otherwise on supported non-NixOS Linux (GH#32871). NixOS reports
`unprivileged-review` and never invokes that inspector. These labels are not
instructions to stop login/session services. It is read-only, prints to the terminal
only, and is never called by automatic maintenance, advisories, logs, or plans;
the escalation advisory names the command but never its output. Names are identification
aids, never exemptions. Platforms without `/proc` exit 3 because `lsof` does not
identify denied processes. If neither complete visibility nor a valid managed
lifetime proof is available, the affected archives remain retained. Pulse/manual launch provenance: [shared launch](worktree-registry.md#shared-pulse-and-manual-launch-gh35295). Degraded
visibility alone does not prohibit cleanup of every archive on the host.
This diagnostic outcome grants no deletion authority, does not trust
process names, and does not require root access or weaker kernel process
protections. A readable CWD match remains a positive live-reference block, and
every other candidacy and apply invariant above remains unchanged.

## Session-history limitations

An originating OpenCode or Claude session identifier is recovery guidance, not
deletion proof. Session history can reconstruct text edits and intent but may be
archived, unavailable, or incomplete and does not prove preservation of ignored
or binary files, permissions, symlinks, index state, or detached Git metadata.
Existing archive integrity, lock, identity, late-write, detached-HEAD, and
interruption checks remain authoritative.
