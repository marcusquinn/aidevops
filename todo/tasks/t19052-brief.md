## What

Stop headless workers from pausing for maintainer permission because they wrote absolute system paths (`/usr/bin`, `/bin`, `/tmp`, ...) into a bash tool command line. The usual cause is an inline restricted `PATH` used to put test stubs first.

## Why

Evidence: #38523 paused on `perm-2a1e7540c77f77ad`. One `bash` request named `/usr/bin/*` plus `~/.aidevops/.agent-workspace/tmp/gh38523-test/bin/*`. OpenCode applies the external-directory boundary to every absolute path in a shell command. The tmp half is already owned recovery (GH#35128/GH#35676), but `/usr/bin/*` is not, so the whole capture became a `needs-maintainer-permissions` hold. Workers never need to name OS binary directories: those binaries already run through `PATH`.

## How

1. `.agents/scripts/headless-runtime-contract.sh`, setup-shortcuts bullets near "Never seek a broad external_directory grant": add one short bullet. Never write absolute paths outside the worktree into bash tool commands. Put stubs under `AIDEVOPS_TEMP_DIR`, set `PATH` and fixtures inside a worktree script, and run that script with a worktree-relative command.
2. `.agents/scripts/worker-permission-helper.sh` `permission_capture_is_temp_write_recovery()`: also classify `bash`/`read` patterns on OS-owned binary directories (`/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, optionally with `/*`) as owned recovery. This grants nothing and only avoids the human hold. Extend the recovery text to say "set PATH inside a worktree script".
3. `.agents/reference/dispatch-blockers.md` "Scratch `external_directory` requests": document the system-bin case and the avoidance pattern.
4. `.agents/scripts/tests/test-worker-permission-helper.sh`: add the #38523 shape (tmp bin + `/usr/bin/*` via bash) as recovery. Keep `/usr/local/bin/*` and write/edit on `/usr/bin/*` as non-recovery.

## Acceptance

- `bash .agents/scripts/tests/test-worker-permission-helper.sh` passes, including the new cases.
- `bash .agents/scripts/tests/test-headless-runtime-contract-tests.sh` passes.
- ShellCheck is clean on the changed scripts.

## Files Scope

- .agents/scripts/headless-runtime-contract.sh
- .agents/scripts/worker-permission-helper.sh
- .agents/reference/dispatch-blockers.md
- .agents/scripts/tests/test-worker-permission-helper.sh
