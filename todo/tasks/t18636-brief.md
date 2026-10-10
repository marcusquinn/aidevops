# t18636: fix(tests): restore test-pulse-routines-selector Case 9/11 after detached script routines

## Origin

- Created: 2026-10-09, interactive session, found while verifying t18635 (GH#34169).
- Issue: GH#34172.

## What

`.agents/scripts/tests/test-pulse-routines-selector.sh` Case 9/11 (`_test_supervisor_self_recursion_guard`, GH#28544/GH#30592) fails on current `main` (`384b125f72`): `self_marker=absent downstream_marker=absent`. Make the test reflect current production behaviour so it passes again, without weakening the self-recursion guard assertion.

## Why

Found while verifying GH#34169. Running the test against unmodified `main` gives 13 passed, 1 failed. The test is not wired into CI (no reference in `.github/workflows` or `linters-local.sh`), so the regression went unnoticed. Likely cause: #32668 ("detach due script routines") moved script routines to a detached runner, so `evaluate_routines` returns before `downstream.sh` writes its marker, and the `routine-state.json` `last_status == "success"` assertion is no longer reached synchronously.

## How

- Read `.agents/scripts/pulse-routines.sh` `_routine_execute` and the detached runner path added in #32668/#34025 to confirm how script routines launch and record state.
- In `_test_supervisor_self_recursion_guard` (around line 325), either wait boundedly for the detached runner to finish (poll for the marker and state with a short cap), or use any existing synchronous/test hook the runner exposes. Keep these assertions: no self marker, and the `skipping self-recursive supervisor target` log line.
- Optional: add the test to the local or CI gate if a suitable bounded hook exists.

## Acceptance

- `bash .agents/scripts/tests/test-pulse-routines-selector.sh` reports 0 failures on main.
- The r901 self-recursion skip is still asserted.
- ShellCheck is clean.

### Files Scope

- `.agents/scripts/tests/test-pulse-routines-selector.sh`
- `.agents/scripts/pulse-routines.sh`
