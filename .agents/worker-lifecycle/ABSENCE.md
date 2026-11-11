# Reconciling absent worktrees

An admission reserves a path; it is not proof that a worktree still exists.
An interrupted enrollment can leave an admission without an admitted owner or a
creation receipt. A worktree removed outside the retirement executor can leave
an admission with creation history but no retirement completion. Neither case
proves that results were preserved. Missing directories must not be reported as
failed archives or repeatedly occupy the cleanup queue forever.

## Terminal reconciliation

The scheduled admission cleanup handles missing sources separately from physical
retirement. `absence.reconcile_absence`:

1. Acquires the existing generation retirement lock and checks for a prior outcome.
2. Defers to a recorded retirement plan instead of abandoning a private relocation.
3. Pins the accessible canonical parent and checks the source with `lstat`.
   A missing parent, permission error, dangling link or replacement is not accepted
   as confirmed source absence.
4. Refreshes registered owners. Live, unknown or observation-only owners prevent
   finalization. An empty reservation is eligible only without a creation receipt.
5. In one admission writer transaction, rechecks the exact owner IDs, versions and
   ended states, checks the creation receipt and checks absence/parent identity again.
6. Appends `worktree-absence-reconciled` and deletes only that generation's admission.

The journal outcome is `source-disappeared` when a valid creation receipt exists,
otherwise `creation-unconfirmed`. The latter does **not** claim that no directory
ever existed. Both record `preservation=unverified` and `cleanup_authorized=false`.
No files, archives, Git administration, generations, bindings or run history are
deleted. No schema migration or new database is required.

New admissions serialize against the writer transaction. A racing owner or changed
directory produces a retry, not a terminal outcome. Journal and admission release
commit together; failures roll back both. A replay returns its historical outcome
without inspecting or modifying a replacement generation at the same pathname.

## Fixed-path re-creation (GH#37706)

Producers that reuse a fixed pathname (for example persistent Buzz agent trees)
can find a closed admission for a tree that disappeared before the cleanup pass
reconciled it. Absence is provable immediately before re-creation, so:

- `worktree_create_registered` calls `worker-registry.py reconcile-path --path P`
  while `P` is absent, and native `create-worktree` does the same before its
  reservation check. `absence.reconcile_path` runs `reconcile_absence` for every
  admission of that exact path. All fences above still apply; a retained
  reservation keeps refusing enrollment. A present path is never reconciled.
- An already re-used path (a linked tree without a marker in its own Git admin
  while one closed generation without a retirement plan reserves the path) uses
  the operator route `worker-registry.py recover-reused-path --path P
  --repos-config C --output-root R`. It previews first. `--confirm` runs an idle
  census, archives and verifies the tree (ignored files are not captured), pins
  the archive base, journals `reused-path-archived`, rechecks the content and
  identity, removes the tree natively, then reconciles the stale generation.
  The branch is kept. Re-running after an interrupted recovery only reconciles.
- Legacy cleanup no longer reports such a tree as `already-retired`; it is
  `retained` with reason `path-reused-after-retirement`.

## Reporting

`cleanup` returns `reconciled` separately from `retired`, `held` and `failed`.
Reconciled generations disappear from the admission queue on the next pass. They
do not increment removed/archive counts. An inaccessible parent remains observable
as `source-absence-unconfirmed`; no admission is released in that case.

`archive_failed` counts confirmed failures of the archive helper's capture,
verification and source-comparison commands, not every cleanup exception. Other
errors remain in `failed` and per-candidate diagnostics. Legacy archive-helper
failures contribute to the combined archive-failure count too.

Diagnostics retain the candidate path/generation, safe validation code, errno or
command operation/exit status. Raw command arguments and stdout/stderr are never
copied into reports. Only bounded `merge:`/`git_admin:` validation codes are extracted
from archive-helper errors; paths and error descriptions are omitted. This does
not add support for any archive format or bypass a preservation refusal.

## Verification

`tests.test_absence` exercises actual disposable Git repositories and registry
transactions, including empty reservations, ended/live/unknown owners, competing
admission, replacements, missing parents, access errors, rollback and path reuse.
Existing retirement/recovery tests cover private relocation resumption. The new
tests and implementation are included in the portable registry validation bundle.
