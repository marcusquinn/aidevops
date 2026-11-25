## What

Reject pnpm `nodeLinker: hoisted` layouts up front in the worktree dependency
restore validator, with a named reason, instead of walking every workspace member
and failing late with `incomplete-package-inventory`.

## Why (evidence, 2026-11-25)

- t19357 (GH#40257, PR #40260) added per-member pnpm workspace restore. The
  validator assumes pnpm's isolated layout: every importer dependency is linked
  in the member's own `node_modules`.
- A managed monorepo with `nodeLinker: hoisted` in `pnpm-workspace.yaml` has
  flat real directories in the root `node_modules` (1,857 entries) and almost
  nothing in member `node_modules`. A read-only diagnostic against its canonical
  checkout rejected 49/49 members: 40 `incomplete-package-inventory` (an
  importer entry missing from the member, e.g. `prettier`, `eslint`, `vitest`), 2
  `unrecorded-module-file` (the root, from `pino/test/fixtures/eval/node_modules`),
  1 `missing-dependencies` and 6 with no member `node_modules`.
- `pulse.log`: 4,350/4,350 `Dependency workspace restore` outcomes were `rejected`.
- `dispatch-stages.tsv` `precreate.restore_deps` for that repo: median 8.6s / p90
  15.1s (n=251, before 2026-11-25T06:00Z) became median 46.4s / p90 139.1s (n=130,
  after) — about 120 minutes of dispatch-critical time spent holding the restore lock
  for zero restores. A hoisted root also exceeds the 64 MB / 20,000-entry copy budget,
  so a restore of this layout can never succeed.

## How

- `.agents/scripts/_worktree_dependency_identity.py`: add a hoisted-linker check
  (`nodeLinker: hoisted` in `pnpm-workspace.yaml`, or `node-linker=hoisted` in the
  repo `.npmrc`) that raises `Rejected("unsupported-node-linker-hoisted")`. Call it
  in `workspace_identity` right after the workspace config comparison (before the
  lockfile reads) and in the non-workspace pnpm branch of `identity`.
- Effect: `--workspace-list` fails fast, the legacy root restore records the named
  reason for `worktree-js-readiness-helper.sh`, and member walks are skipped.
- Reference pattern: existing fail-closed `Rejected(...)` codes in the same file.

## Files Scope

- `.agents/scripts/_worktree_dependency_identity.py`
- `.agents/scripts/tests/test-worktree-dependency-provision.py`

## Acceptance

- Hoisted config (either source) → `--workspace-list` exits 1 with
  `dependency-provision-rejected reason=unsupported-node-linker-hoisted`.
- Isolated-layout workspaces still provision (existing provisioning and bootstrap
  suites pass).
- Live: a read-only `--workspace-list` against the hoisted canonical returns the new
  reason in about 1s, and later dispatches for that repo show `precreate.restore_deps`
  back near the pre-t19357 baseline or lower.

## Verification

- `python3 .agents/scripts/tests/test-worktree-dependency-provision.py`
- `bash .agents/scripts/tests/test-worktree-js-dependency-bootstrap.sh`
- ShellCheck/linters for any touched shell.

## Follow-up (not in scope)

Hoisted repos still start workers without restored dependencies. Supporting them
(for example an APFS clonefile copy-on-write restore of the root `node_modules`
under the same trust boundary) is a separate design decision.
