## What

Worker dependency provisioning has been refusing almost every restore for a managed pnpm product repo. Since line 250000 of the local pulse log there were 406 rejections and no successful restore. 330 of them were `dependency-provision-rejected reason=unrecorded-module-file`, and about 246 dispatch launches in that repo started without `node_modules`. Those workers start without dependencies, so typecheck, lint and tests cannot run until the worker reinstalls them, if its sandbox allows that at all.

The cause is non-module entries that tools and macOS create at the root of `node_modules`:

- `node_modules/.metadata_never_index`: zero-byte Spotlight exclusion marker, regular file, dated July
- `node_modules/.vite/` and `node_modules/.vite-temp/`: Vite dependency caches (the aidevops checkout itself has `.vite-temp/`)

In `.agents/scripts/_worktree_dependency_snapshot.py`, `resolution_root()` treats every direct child of `node_modules` as a package root unless it is a scope directory or a known package-manager metadata entry (`metadata_entry`). `check_package_root()` therefore rejects the marker file as `unrecorded-module-file`. It would also reject the cache directories, because they have no inventory-backed `package.json`.

This rejection is a deliberate trust boundary. Node resolves a bare specifier such as `require('.extra.js')` to `node_modules/.extra.js`, so nothing unrecorded may be copied into a resolution position, and `test_manifestless_package_roots_and_files` keeps `.extra.js` rejected. The fix must keep that boundary.

Measured scope (implementation session): the affected source `node_modules` is about 3.9 GB, against the 64 MiB copy budget. Its `du` preflight overruns the 5s timeout, so the walk runs anyway. Once these entries are skipped, the walk will reject on the byte or entry budget, or on `stale-installed-lock` while the canonical install is behind its lockfile. Workers there will still install from the lockfile, as `workflows/full-loop.md` directs. This fix removes the false rejection for sources that fit the budget. Fast provisioning for large pnpm sources is separate work.

## How

- EDIT `.agents/scripts/_worktree_dependency_snapshot.py`: add a small typed allowlist of non-module entries that are skipped at the top level of the dependency root: neither counted, copied, recorded nor inventoried, exactly like the `STALE_STAGING` skip in `Snapshot.visit`. A worker can never resolve a skipped entry, so this is strictly safer than copying it.
  - Marker files (`S_ISREG` only): `.metadata_never_index`, `.DS_Store`
  - Tool cache directories (`S_ISDIR` only, never symlinks): `.vite`, `.vite-temp`, `.cache`
  - Any other name, or an allowlisted name with the wrong file type, keeps today's handling. That means `.extra.js`, a symlinked `.cache`, and a directory named `.metadata_never_index` are still rejected.
- EDIT `.agents/scripts/tests/test-worktree-dependency-provision.py`: add one case covering both managers. It restores with the marker and cache directories present, asserts that the package was copied and the skipped entries were not, and asserts that a wrong-type allowlisted name (symlinked `.cache`) is still rejected. The existing `.extra.js` expectation stays unchanged.

### Files Scope

- .agents/scripts/_worktree_dependency_snapshot.py
- .agents/scripts/tests/test-worktree-dependency-provision.py
- TODO.md

## Acceptance Criteria

- [ ] With `.metadata_never_index` (file), `.DS_Store` (file), `.vite/`, `.vite-temp/` and `.cache/` (directories) at the root of the source `node_modules`, the restore succeeds for npm and pnpm fixtures, and none of these entries appear in the worker copy.
- [ ] `.extra.js`, `extra.js`, `@extra.js`, `extra/index.js`, a symlinked `.cache`, and a directory named `.metadata_never_index` are still rejected.
- [ ] Source and staged digests still match (the restore promotes), and the entry budget does not count skipped entries.
- [ ] `python3 .agents/scripts/tests/test-worktree-dependency-provision.py` passes.

## Verification

- `python3 .agents/scripts/tests/test-worktree-dependency-provision.py`
- Read-only check against the real pnpm source: call `snapshot()` with no `copy_to` and confirm that the reason is no longer `unrecorded-module-file`. Any remaining reason, such as a budget, is a separate finding.
- After deploy, `rg -o 'dependency-provision-rejected reason=[a-z-]+' ~/.aidevops/logs/pulse.log | sort | uniq -c` should show `unrecorded-module-file` no longer growing.
