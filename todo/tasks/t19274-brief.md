# t19274: fix(tests): make test-dispatch-max-parallel.sh timing cases deterministic under parallel load

ref: GH#39823

## What

`.agents/scripts/tests/test-dispatch-max-parallel.sh` fails intermittently under parallel test load. Make its timing-sensitive cases deterministic so `affected-tests-helper.sh` and CI stop reporting it as `flaky`.

## Why

Observed 2026-11-22 during `affected-tests-helper.sh run --base origin/main --compare-base` (30 suites in parallel) on an unrelated runner-capability change: head result `1,0` (failed, then passed on rerun), base `0`, classified `flaky`. Three further isolated head runs passed. The changed file was not referenced by this suite, so the flake is pre-existing. Each flaky report costs every PR session a triage step and weakens the regression signal of the suite that guards dispatch concurrency.

## How

1. Reproduce under load: run the suite in a loop (20+ iterations) while CPU is busy (for example alongside `affected-tests-helper.sh run` or `yes` processes), capturing the `FAIL` line of each failing run.
2. Identify the failing case(s). Likely candidates are the fixed `sleep` windows used as synchronisation: lines ~320 (`sleep 2 &`), ~433, ~531, ~606, ~648, ~714, ~1449, ~1740, and the `date +%s` arithmetic at ~1055, ~1394, ~1409, ~1627.
3. Replace sleep-as-synchronisation with explicit readiness signals (marker files, FIFOs, or polling a condition with a bounded deadline), following existing patterns in the same suite where a case already waits on a marker.
4. Keep assertions unchanged in meaning; do not widen tolerances to hide real races in `pulse-dispatch-*` code. If the loop proves a real product race, stop and report it on this issue with the captured evidence instead of editing product code outside the Files Scope.

## Acceptance

- The failing case is named in the PR with the captured failure output.
- 20 consecutive runs under CPU load pass (state the load method).
- `shellcheck .agents/scripts/tests/test-dispatch-max-parallel.sh` clean.
- `.agents/scripts/affected-tests-helper.sh run --base origin/main --compare-base` reports the suite `pass`.

### Files Scope

- `.agents/scripts/tests/test-dispatch-max-parallel.sh`
