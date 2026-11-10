# Temporary observation-era worktree cleanup

`worker-legacy-cleanup.py` inventories legacy worktrees, including directories never
recorded before admission-controlled creation. It is a transition tool, not another permanent lifecycle
system. It reads the existing `generations`, `bindings`, `runs` and `events` tables.
It does not create a database, migrate the schema, invent creation events or insert
historical rows into `generation_admissions`.

## Algorithm

1. Union Git's linked-worktree registrations for configured maintenance repositories,
   immediate directories/symlinks in `AIDEVOPS_WORKTREE_BASE_DIR` (by default the
   `_worktrees` directory beneath the user's `Git` directory), and historical registry paths.
   Deduplicate by pathname;
   Git registrations also cover sibling and temporary worktrees outside the central
   directory. Main checkouts are not added by Git discovery. Unregistered/orphan
   directories receive explicit inspection results, not silent omission.
2. Select old linked worktrees within the configured maintenance repositories.
   The default age is one hour since the latest recorded event or worktree/HEAD/index
    modification. Modern generations may use the guarded reconstructible takeover
    described below; their configured age threshold still applies.
3. Recheck every recorded process using the native Linux/macOS identity adapter.
   Alive or unknown results retain the directory. A cached `ended` row or a missing
   PID alone is insufficient. There is no global process-cwd scan or descendant census.
   Automatic passes retain sources with missing owner records. Explicit operator
   confirmation can authorize a named legacy source without historical registration;
   it never overrides a recorded alive/unknown owner or modern admission.
   Discovery does not fabricate process records or `created-worktree` events.
4. Archive using the existing Git-only archive helper and verify captured payloads
   with `verify-local`, without a full checkout or shared-repository `fsck`.
   Preserve unpublished commits, index state and non-ignored working files;
   ignored files remain excluded. Pin the archive base in the common repository.
5. Recheck the registered writers, directory identities and content snapshot.
   Journal the operation, move the worktree to its recorded private sibling, then
   remove that private worktree with native Git. Never recursively remove a public
   pathname that might have been reused.

The existing SQLite writer transaction serializes registration changes during
native move/removal. Non-destructive archive capture and verification release it.
After committing a checkpoint or releasing the writer and reacquiring it, the
script checks the bindings and native identities again. This transition uses
**recorded processes**, not a claim that historical observation proves complete
writer coverage. As with the managed lifecycle contract, independent unregistered
writers are not inferred from cwd, age or Git state.

## Pulse and manual operation

### Remote-reconstructible class (Linux)

Unrecorded/unbound legacy worktrees can retire without writer history only when
their complete content is remote-recoverable and current liveness is observable.
For legacy sources this class is independent of the ordinary legacy age threshold.
Modern takeover still requires the configured age threshold, closed admission and
complete ended owner evidence (or existing explicit enrolled-only authorization).
With `--apply`, takeover first closes a still-open admission only when the shared
`prepare_cleanup` path re-samples every bound run as admitted and ended; otherwise
the source stays retained as `managed-admission-not-closed`. Preview never closes.
Detached modern sources additionally require verified creation evidence. These
authority checks are not waived for clean or pushed sources, and no
`--confirm-legacy-path` is needed for a modern source whose guards already hold.
An interrupted operator-confirmed archive operation still requires confirmation;
automatic cleanup cannot inherit that permission.
It requires a canonical owned linked worktree beneath the managed base, no Git
lock, and an empty Git status including untracked files and submodule state.
Ignored files (dependency trees, caches, build output) do not retain the source;
non-forced removal discards them, as in ordinary cleanup. HEAD must be contained
in a remote-tracking ref. All pages of
GitHub open PRs must be fetched successfully; either a matching branch or head
SHA retains the source. API failures never prove PR absence.

Names containing `preserved`, `readonly`, `recovery` or `review` are retained,
case-insensitively. `AIDEVOPS_WORKTREE_PRESERVE_PATTERNS` adds comma-separated
literal substrings (not regular expressions); the systemd launcher forwards it.
Every same-UID Linux thread's kernel credentials, cwd and fd table are inspected,
including threads surviving a dead leader. An unreadable or still-live thread
with missing observations fails closed. A vanished task/closed fd is distinguished
from unavailable observations. Other operating systems retain these candidates.

GitHub PR lookups release the registry writer, because SQLite does not serialize
GitHub state and a lookup can outlast the admission busy timeout (GH#36921).
Under the reacquired registry writer, eligibility, the fetched GitHub PR absence,
registered writers and the process census are checked again immediately before
native `git worktree remove` **without `--force`**. Branches are never deleted. The event
journal records the exact plan before deletion and a
`reconstructible-worktree-retired` receipt after verifying directory absence,
commit presence and the unchanged branch ref. Results identify the class; receipts
remain in the existing journal, not a new database or fabricated admission.

Before batch mode on each host/installation, one source is removed and its commit
is checked out at a fresh private probe path, verified, and removed non-forcibly.
Only then is `reconstructible-host-probe-verified` journaled. Failed/interrupted
verification blocks further removals until that original plan is reverified;
replacement sources never inherit its authority. Failed probe trees are retained,
not recursively erased. A later pass can reverify and resume.

At the cleanup threshold (the lower of 80% of `AIDEVOPS_MAX_WORKTREES`, default
1000, and `AIDEVOPS_WORKTREE_CLEANUP_THRESHOLD`, default 150 registered
worktrees), or below existing disk thresholds, dispatch
kicks the existing isolated async cleanup launcher once per executor. Admission
still fails closed at the cap/disk limit; it never spends its 60-second budget on
heavy cleanup. Pressure bypasses routine cadence, not the cleanup lock or safety
checks. The async helper also checks pressure before honoring its cadence so
preflight kicks continue draining a backlog over bounded passes. Production
rollout evidence is the count falling below 80% and disappearance of
`local_capacity_gate`; disposable-repository tests do not claim host deployment.

Pulse calls the temporary pass before admission-based cleanup. Each receives half
the worktree-cleanup budget; the existing outer watchdog remains responsible for
hard termination. The temporary pass attempts at most 25 worktrees per invocation.
A private `legacy-cleanup-position` cursor in the existing state directory prevents
one failing candidate from starving the remaining backlog. It grants no deletion
authority and is not a database.
The limit counts attempted retirements, not examined entries; retained entries do
not consume it. Preview does not advance the cursor. Each retained modern result
reports its concrete guard in `reason` and retains the ownership classification in
`ownership: managed-by-current-cleanup`. Missing paths without a pending archive
plan report `already-absent`, without claiming removal or preservation; normal
admission cleanup owns registry absence reconciliation.

Preview (no filesystem or registry writes):

```bash
python3 -E -s -B ~/.aidevops/agents/worker-lifecycle/worker-legacy-cleanup.py --state-dir ~/.aidevops/.agent-workspace/worker-lifecycle --repos-config ~/.config/aidevops/repos.json --output-root ~/.aidevops/recovery/archives
```

Add `--apply` to archive and remove the selected worktrees. `--min-age-seconds`,
`--limit` and `--budget-seconds` bound a manual invocation. Both cleanup passes
use the same read-only archive-path validation described in [CLEANUP.md](CLEANUP.md).
An owned archive root with mode 0755 is accepted without changing permissions;
individual archives remain private. Unsafe paths prevent source retirement.
Exception messages name the offending component; per-item JSON `reason` values
report `ValueError`. No existing permissions are automatically changed.
Preview does not create the root or change its permissions.

### Operator-confirmed legacy transition

Legacy worktrees may predate owner registration. For an operator-approved source,
repeat `--confirm-legacy-path /absolute/worktree/path` on the command above, then
add `--apply` to perform archive, verification and retirement. This selects **only**
the named paths, not all discovered worktrees. Preview remains read-only.

The operator decision authorizes the transition without requiring historical owner
records; it is not proof that an unregistered writer is absent. The operator must
stop independent unregistered writers before approving the source. Recorded native
owners must still be ended. Modern admissions, age, Git locks, directory identity,
archive verification and source-content comparisons remain enforced. No root or
process-CWD scan is introduced. Ignored files remain excluded.

The existing archive/retirement journal records `operator_confirmed: true` with the
exact source identity and fingerprint. No generation or owner is manufactured.
An interrupted operator transaction requires the same explicit path confirmation
to resume; Pulse cannot adopt its permission. Retries preserve replacements at the
original path. The new lifecycle and ordinary `worktree-helper.sh remove --force`
are unchanged. After backlog migration this option leaves with the temporary tool.

The JSON report distinguishes historical generation count, unique path count,
eligible candidates, attempted operations and actually retired worktrees. Its
`counts` field groups specific retention reasons. `incomplete` means another
bounded pass is needed, not that the remaining directories have been examined.
Discovery failures appear in `discovery_errors` and also set `incomplete`; other
sources are still inspected. Discovery and preview do not create registry rows.

## Interruptions and removal of the transition tool

Archive and retirement receipts live in the existing event journal. A retry uses
the recorded archive and private target, verifies them again and honors current
repository scope. A replacement at the old public path is never removed by a
completed operation. A failed archive or changed source is retained; if relocation
already happened, the private tree and its journal remain available for recovery.
Archives still require their common repository and retained base ref.

After the observation-era backlog and pending retirements have been resolved,
remove `worker-legacy-cleanup.py`, `worker_lifecycle/legacy_cleanup.py`,
`worker_lifecycle/legacy_inventory.py`, `worker_lifecycle/legacy_discovery.py`,
`worker_lifecycle/legacy_options.py`, `worker_lifecycle/legacy_takeover.py`,
their focused test, this document and the
temporary Pulse call. Restore the full Pulse budget to admission-based cleanup.
Retain completed archive receipts and historical registry events; do not rewrite
the evidence or delete archives as part of removing this code.
