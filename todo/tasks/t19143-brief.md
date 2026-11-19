<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `test-headless-runtime-helper admission-denied filesystem-path-externally-writable fixture` → 0 relevant hits.
- [x] Discovery pass: no open issue or PR covers these two failures (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:simple`. One test function restores the mode it changes.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** `bash .agents/scripts/tests/test-headless-runtime-helper.sh` fails 2 tests on `main` (also on `e1d9419417`): `claude worker sandbox receives only validated signing Git configuration` (`status=0 result=exit=75`) and `Claude bare execution paths use the resolved headless timeout` (`direct_status=75 ... admission-denied reason=FilesystemValidationError code=filesystem-path-externally-writable`). Neither assertion is reached: worker-lifecycle admission denies the fixture launch. Every session that runs the suite must re-prove the failures are pre-existing before trusting it, and the suite is not CI-gated, so the leak stays invisible.

## What

`test_runtime_temp_files_bypass_group_writable_workspace` (`.agents/scripts/tests/test-headless-runtime-contract-tests.sh:358-385`) sets the fixture `${HOME}/.aidevops/.agent-workspace` to `0775` to prove runtime temp files bypass a group-writable workspace, and never restores it. Later tests launch through worker-lifecycle admission, whose chain check (`.agents/worker-lifecycle/worker_lifecycle/filesystem.py:42-57`) rejects the group-writable workspace with `filesystem-path-externally-writable`, so they exit 75.

Restore the workspace's prior mode before the test returns, on both the pass and fail paths.

## Why

Isolation proof (2026-11-19, sourced harness): the Claude-bare test passes in a fresh fixture, fails with `filesystem-path-externally-writable` immediately after the group-writable-workspace test, and returns `direct_status=0 stdin_status=0` with the expected output once the workspace is set back to `0700`.

## Tier

`tier:simple`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/tests/test-headless-runtime-contract-tests.sh:358-385`. Record `runtime_temp_test_mode "$workspace_root"` after `mkdir -p`, then `chmod` back to it before each `return 0`.

- EDIT: `.agents/scripts/tests/test-headless-runtime-completion-tests-recovery.sh`. Scope extension found while verifying: after GH#39167 (`3baf2eeeb0`) the shared PR-base resolver reads `gh api repos/<slug> --jq .default_branch`, but four orphan-recovery stubs still answer only `gh repo view`. With no configured base, `_attempt_orphan_recovery_pr` returns 1, and its bare call under `set -e` ends the whole suite at `rc=1` before the `Tests run`/`Failures` summary. Answer the REST lookup through a shared `_fixture_gh_is_default_branch_lookup` predicate and capture the recovery status, so a future regression is reported as a FAIL line instead of a silent abort.

- EDIT: `.agents/scripts/headless-runtime-worker-orphan.sh`. Production defect found by the same run: `_handle_worker_branch_orphan` and `_handle_worker_local_branch_unpushed` assign `_resolve_orphan_recovery_base_branch` bare. Since GH#39167 the resolver returns 1 when no base is known, so under errexit the handler aborts before claim release and the ops comment. Tolerate the failure: skip the diagnostic ahead-count against an empty base, and print an explicit `<pr-base-branch>` placeholder in the manual-recovery command instead of guessing `main`.

### Files Scope

- `.agents/scripts/tests/test-headless-runtime-contract-tests.sh`
- `.agents/scripts/tests/test-headless-runtime-completion-tests-recovery.sh`
- `.agents/scripts/headless-runtime-worker-orphan.sh`

### Reference pattern

- `.agents/scripts/tests/test-headless-runtime-helper.sh:397` / `:429` change the `unwritable` fixture to `0500` and restore `0700` in the same test.

## Acceptance Criteria

- [x] `bash .agents/scripts/tests/test-headless-runtime-helper.sh` reports `Failures: 0` on a host where it previously reported the two failures above. Verified 2026-11-19: `rc=0`, `Tests run: 539`, `Failures: 0`. Both named tests and `_cmd_run_finish fail still recovers existing PR for open issue` pass.
- [x] `runtime temp creation bypasses a group-writable aidevops workspace` still passes.
- [x] ShellCheck reports no warnings for the changed files.
