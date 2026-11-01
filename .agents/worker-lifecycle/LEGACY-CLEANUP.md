# Temporary observation-era worktree cleanup

`worker-legacy-cleanup.py` drains worktrees recorded before admission-controlled
creation was enabled. It is a transition tool, not another permanent lifecycle
system. It reads the existing `generations`, `bindings`, `runs` and `events` tables.
It does not create a database, migrate the schema, invent creation events or insert
historical rows into `generation_admissions`.

## Algorithm

1. Group historical generations by pathname. Multiple attempts can refer to one
   directory; absent directories are reported, not counted as newly removed.
2. Select old linked worktrees within the configured maintenance repositories.
   The default age is one hour since the latest recorded event or worktree/HEAD/index
   modification. Current admission-controlled generations are left to normal cleanup.
3. Recheck every recorded process using the native Linux/macOS identity adapter.
   Alive or unknown results retain the directory. A cached `ended` row or a missing
   PID alone is insufficient. There is no global process-cwd scan or descendant census.
4. Archive using the existing Git-only archive helper and verify a restoration.
   Preserve unpublished commits, index state and non-ignored working files;
   ignored files remain excluded. Pin the archive base in the common repository.
5. Recheck the registered writers, directory identities and content snapshot.
   Journal the operation, move the worktree to its recorded private sibling, then
   remove that private worktree with native Git. Never recursively remove a public
   pathname that might have been reused.

The existing SQLite writer transaction serializes registration changes during
archive/removal operations. After committing a checkpoint and reacquiring it, the
script checks the bindings and native identities again. This transition uses
**recorded processes**, not a claim that historical observation proves complete
writer coverage. As with the managed lifecycle contract, independent unregistered
writers are not inferred from cwd, age or Git state.

## Pulse and manual operation

Pulse calls the temporary pass before admission-based cleanup. Each receives half
the worktree-cleanup budget; the existing outer watchdog remains responsible for
hard termination. The temporary pass attempts at most 25 worktrees per invocation.
A private `legacy-cleanup-position` cursor in the existing state directory prevents
one failing candidate from starving the remaining backlog. It grants no deletion
authority and is not a database.

Preview (no filesystem or registry writes):

```bash
python3 -E -s -B ~/.aidevops/agents/worker-lifecycle/worker-legacy-cleanup.py --state-dir ~/.aidevops/.agent-workspace/worker-lifecycle --repos-config ~/.config/aidevops/repos.json --output-root ~/.aidevops/recovery/archives
```

Add `--apply` to archive and remove the selected worktrees. `--min-age-seconds`,
`--limit` and `--budget-seconds` bound a manual invocation. The archive root must
be an owned private directory, as required by the existing archive executor.

The JSON report distinguishes historical generation count, unique path count,
eligible candidates, attempted operations and actually retired worktrees. Its
`counts` field groups specific retention reasons. `incomplete` means another
bounded pass is needed, not that the remaining directories have been examined.

## Interruptions and removal of the transition tool

Archive and retirement receipts live in the existing event journal. A retry uses
the recorded archive and private target, verifies them again and honors current
repository scope. A replacement at the old public path is never removed by a
completed operation. A failed archive or changed source is retained; if relocation
already happened, the private tree and its journal remain available for recovery.
Archives still require their common repository and retained base ref.

After the observation-era backlog and pending retirements have been resolved,
remove `worker-legacy-cleanup.py`, `worker_lifecycle/legacy_cleanup.py`,
`worker_lifecycle/legacy_inventory.py`, their focused test, this document and the
temporary Pulse call. Restore the full Pulse budget to admission-based cleanup.
Retain completed archive receipts and historical registry events; do not rewrite
the evidence or delete archives as part of removing this code.
