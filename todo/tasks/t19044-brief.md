## What

Stop `gh-checks-wait-helper.sh wait` from declaring a terminal failure on a concurrency-cancelled check while other checks are still pending. A cancel-only failure should stay pending, with its grace clock not yet started, until no other check is pending. The existing GH#35830 grace window (`AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS`, default 180s) should then begin.

## Why

GH#35830 treats a cancel-only failure as pending for 180s from when the cancelled set is first seen, to give the superseding run time to appear. Under CI queue pressure, the superseding run is often still queued after 180s: on 2026-11-15, jobs for PR #38533 started up to about 8 minutes after the PR was created, and 20 workflow runs were queued in the repository at once. The grace expires while other checks are still pending, and the helper reports `FAIL: required checks reached a terminal failure` as soon as the last other check finishes.

Evidence, PR #38533 on 2026-11-15:

- The wait started with `gate / Maintainer Review & Assignee Gate: cancel` (run 43765832020) and 8 pending checks.
- About 4.5 minutes later the last pending check went `pending -> pass`, and the helper printed `FAIL: required checks reached a terminal failure` listing only the cancelled gate.
- About one minute later, `gh pr checks 38533` showed `gate / Maintainer Review & Assignee Gate` as `pass` (run 43765831983), and the PR merged normally.

Callers such as `full-loop-helper.sh wait-checks`, interactive sessions and headless workers treat `FAIL` as a real CI failure. That costs a revalidation round or a misrouted repair attempt.

## How

In `apply_cancel_grace` (`.agents/scripts/gh-checks-wait-helper.sh`, about line 555): when the classification is `failure`, `only_cancelled_failures` holds, and any check in the canonical set has bucket `pending`, set `_GCW_GRACED_CLASSIFICATION=pending` and clear `_GCW_CANCEL_FIRST_EPOCH` and `_GCW_CANCEL_SET`. The grace window then starts when the set first has no pending checks. Keep all other behaviour unchanged: real failures are still terminal immediately, the overall `--timeout` still bounds the wait, and the per-attempt grace reset from GH#35830 still applies.

## Acceptance

- New fixture in `.agents/scripts/tests/test-gh-checks-wait-helper.sh`. Poll 1 is `[cancel Build, pending Lint]` with `AIDEVOPS_GH_CHECKS_CANCEL_GRACE_SECONDS=0`. Poll 2 is `[pass Build, pass Lint]`. The wait exits 0 with `PASS: required checks completed`. On the current code poll 1 already returns 1.
- The existing GH#35830 cases (superseded, per-attempt timer, unsuperseded-after-grace, invalid grace, valid-grace timeout) still pass. A mixed cancel plus real-failure set is still terminal immediately.
- `bash .agents/scripts/tests/test-gh-checks-wait-helper.sh` passes, and ShellCheck is clean.

## Files Scope

- `.agents/scripts/gh-checks-wait-helper.sh`
- `.agents/scripts/tests/test-gh-checks-wait-helper.sh`
