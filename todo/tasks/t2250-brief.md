# t2250 — tabby-profile-sync: handle folded YAML scalars, detect worktrees deterministically

## Session origin

Interactive. User observed the routine that creates Tabby terminal profiles from `repos.json` had:

1. Produced a duplicate profile for `wordpress/wp-plugin-starter-template-for-ai-coding`.
2. Created a profile for `wpallstars.com-chore-aidevops-init` — a linked git worktree, not a canonical repo.

## What

Fix two independent bugs in the tabby profile sync pipeline, both of which trace
to fragile string heuristics that can't handle real-world inputs:

- **A (duplicate profiles):** `tabby_yaml_helpers.extract_existing_cwds()` uses a
  single-line regex that misses YAML folded (`>-`) and literal (`|-`) block
  scalars. Tabby's GUI rewrites long paths into folded form on every save, so
  after the first sync + first Tabby session the dedup check silently fails for
  every profile with a long cwd, and the next sync duplicates it.
- **B (worktree leakage):** `tabby-profile-sync.get_repos()` tries to detect
  worktrees by splitting the basename on `.` and checking if the remainder
  starts with a known branch prefix (`feature-`, `bugfix-`, `chore-`, ...).
  The heuristic fails for repos whose names contain a dot
  (`wpallstars.com`, `example.io`, `essentials.com`) because `split(".", 1)[1]`
  begins with the TLD (`com-...`), not the branch prefix.

Also: the upstream cause of worktrees ending up in `repos.json` at all —
`register_repo()` in `aidevops.sh` has no worktree detection on its general
path (only `cmd_init` does, and only when `WORKTREE_PATH` is set). The
auto-discovery scan (`find ~/Git -name .aidevops.json`) picks up
`.aidevops.json` files from inside worktrees (because worktrees inherit working
tree contents) and registers each worktree as a standalone repo.

## Why

Every tabby profile sync duplicates long-path entries and occasionally leaks
worktree entries as standalone profiles. Compounds over time: each sync adds a
new duplicate for every long-path repo. The root causes are framework-level
(`register_repo` treating worktrees as repos) and propagate to any other
consumer of `initialized_repos` (pulse, cross-repo tooling, tabby).

## How

Three-layer defense, paired with a one-shot migration:

### Layer 1 — YAML scalar parser

`.agents/scripts/tabby_yaml_helpers.py::extract_existing_cwds`:
- Replace the single-line regex with a line-by-line parser that recognises
  `cwd: value`, `cwd: 'value'`, `cwd: "value"`, `cwd: >-` + indented
  continuation, and `cwd: |-` + indented continuation.
- New helper `_parse_block_scalar` walks indented continuation lines until
  dedent and joins folded lines with spaces / literal lines with newlines.

### Layer 2 — Deterministic worktree detection

`.agents/scripts/tabby-profile-sync.py`:
- New `is_linked_worktree(repo_path)` uses `git rev-parse --git-dir` vs
  `git rev-parse --git-common-dir`. If they differ (after absolutising), the
  path is a linked worktree. Works for any repo name, any branch name, any
  future worktree convention. No string heuristics.
- `get_repos()` calls `is_linked_worktree()` in place of the old
  basename-splitting code.
- Helper `_run_git()` wraps `subprocess.run` with a 5s timeout and swallows
  errors so non-git paths pass through as "not a worktree".

### Layer 3 — Root cause fix

`aidevops.sh`:
- New `resolve_canonical_repo_path()` resolves a worktree path to the main
  worktree via `git worktree list --porcelain`, falls through for non-git and
  main-worktree inputs.
- `register_repo()` now calls `resolve_canonical_repo_path()` after path
  normalisation, so *every* registration path (cmd_init, auto-discovery, scan)
  is protected — not just the `cmd_init` branch that checks `WORKTREE_PATH`.

### One-shot migration

`setup-modules/migrations.sh::cleanup_worktree_entries_in_repos_json`:
- Scans `initialized_repos[].path`, detects linked worktrees, removes them.
- Flag file `~/.aidevops/logs/.migrated-worktree-repos-json-t2250` suppresses
  re-execution.
- Wired into both `setup.sh` non-interactive and interactive flows alongside
  the other cleanup_* calls.

### Tests

- `tests/test-tabby-profile-sync.py` grows from 2 tests to 16:
  - `TestExtractExistingCwds` × 8: inline plain/quoted, folded, literal, mixed
    forms, empty config, no-profiles config. The folded-scalar test uses the
    exact wp-plugin-starter path that caused the original duplicate.
  - `TestIsLinkedWorktree` × 5: main, non-git, nonexistent, linked worktree,
    **worktree of dotted-name repo** (the canonical regression case).
  - `TestGetReposExcludesWorktrees` × 1: end-to-end check that a worktree
    entry in a synthetic `repos.json` does not reach the result list.
- `.agents/scripts/tests/test-resolve-canonical-repo-path.sh` × 4: shell-level
  tests for the aidevops.sh function. Uses temporary git fixtures.

## Acceptance criteria

- [x] `extract_existing_cwds` recognises the wp-plugin-starter folded-scalar
      cwd as an existing path (verified against real user config).
- [x] `is_linked_worktree()` returns True for linked worktrees including
      TLD-named ones, False for main and non-git paths.
- [x] `get_repos()` no longer emits the wpallstars.com worktree (verified
      end-to-end via `tabby-profile-sync.py --status-only`).
- [x] `register_repo()` resolves worktree input paths to the canonical main.
- [x] Migration removes the stale worktree entry from the real user config;
      flag file prevents re-execution.
- [x] All 16 Python tests pass, all 4 shell tests pass, shellcheck clean.

## Manual follow-up (user)

The duplicate Tabby profile at line 1176 of
`~/Library/Application Support/tabby/config.yaml` should be removed via
Tabby's GUI (right-click → delete). The sync tool deliberately never
overwrites existing profiles to preserve user customisations (colours,
icons, env vars), so the one pre-existing duplicate won't be auto-cleaned.
The fix prevents *new* duplicates from appearing.

## Context

- Canonical failure config: `~/Library/Application Support/tabby/config.yaml`
  (lines 809 and 1176 had identical `cwd` for the wp-plugin-starter path).
- Canonical worktree leak: `wpallstars.com-chore-aidevops-init`.
- Related: PR #17555 (tabby-helper refactor), PR #18677 (issue-sync SYNC_PAT).
