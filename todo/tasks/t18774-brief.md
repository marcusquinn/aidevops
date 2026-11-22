## What

`.agents/scripts/tests/test-linters-local-bash32-gate.sh` fails locally on unmodified `main` with `FAIL create feature repo`. The test passes in CI.

Root cause, confirmed locally:

1. `test_feature_branch_uses_regression_helper` runs `cd "$repo_dir"` (inside `TEST_ROOT`), then `teardown` runs `rm -rf "$TEST_ROOT"`. The shell is left in a deleted directory.
2. `test_timeout_is_warning_only` then calls `git -C "$repo_dir" ...`. On machines with aidevops installed, `git` on `PATH` is the shim `.agents/scripts/git`, which runs `canonical-git-command-guard.py`. Its `main()` uses `parser.add_argument("--cwd", default=os.getcwd())`, and `os.getcwd()` raises `FileNotFoundError` when the directory was deleted. The shim exits 1 with a traceback even though `git -C <absolute path>` does not need the current directory. Real git succeeds in the same state.

Repro (deleted cwd, absolute `-C`): the shim prints a traceback ending in `FileNotFoundError: [Errno 2] No such file or directory` and exits 1; `/opt/homebrew/bin/git -C <repo> rev-parse --short HEAD` exits 0.

## Fix

- Test: leave `TEST_ROOT` before deleting it. In `teardown`, `cd "$TEST_SCRIPTS_DIR"` before the delete. Or run each test body in a subshell so its `cd` does not leak.
- Guard: do not crash on a deleted cwd. Resolve the default `--cwd` inside `main()` with `try: os.getcwd() except FileNotFoundError:`. Fall back to the `PWD` env value or an empty value, keep classification fail-closed where the cwd matters, and allow `git -C <absolute path>` invocations that do not depend on the cwd. Print a one-line `BLOCKED:` reason instead of a traceback when it must block.

### Files Scope

- `.agents/scripts/tests/test-linters-local-bash32-gate.sh`
- `.agents/scripts/canonical-git-command-guard.py`

## Files to modify

- `.agents/scripts/tests/test-linters-local-bash32-gate.sh:35-40` (`teardown`), following the `setup`/`teardown` pattern already in the file.
- `.agents/scripts/canonical-git-command-guard.py:78-84` (`main`, `--cwd` default). Keep the canonical-checkout protection unchanged; existing coverage is in `.agents/scripts/tests/test-canonical-git-command-guard.sh`.

## Verification

- `bash .agents/scripts/tests/test-linters-local-bash32-gate.sh` passes locally with the aidevops `git` shim first on `PATH`.
- From a deleted directory, `git -C <repo> rev-parse --short HEAD` through the shim exits 0 with no traceback.
- `bash .agents/scripts/tests/test-canonical-git-command-guard.sh` still passes; canonical mutations stay blocked.
- `shellcheck` clean on the test; `.agents/scripts/linters-local.sh --changed --base-ref origin/main` passes.
