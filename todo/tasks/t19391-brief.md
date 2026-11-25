## What

Make the runtime-pending held-PR CI gate (`_pmrp_head_ci_ready` in `.agents/scripts/pulse-merge-runtime-pending-notice.sh`) report a terminal-red head when a required check failed terminally and no required check is still active, even if other required contexts are absent from the head's check-run rollup. Today any absent required context makes the whole head "pending", so a held runtime-pending PR whose failing job stops downstream matrix jobs is never routed to CI repair and never surfaces an ATTENTION line.

## Why

Observed 2026-11-25 on a managed WordPress plugin repository (PR held `hold-for-review` with recorded scope `runtime-pending` since 2026-11-24T09:12Z, ~34 hours):

- `full-loop-helper.sh runtime-pending-notice <PR> <repo>` returns a liftable notice (risk Critical, level runtime-pending).
- The default-branch ruleset requires `Lint (PHP 7.4)`, `Release build, preflight and Plugin Check`, `Smoke test (WordPress 6.2, PHP 7.4)` and `Smoke test (WordPress latest, PHP 8.3)`.
- On the exact head, `Lint (PHP 7.4)` is `completed/failure`; the release and smoke jobs depend on it, so they are `skipped` under the unexpanded matrix name (`Smoke test (WordPress ${{ matrix.wp }}, ...)`) and the two required smoke contexts never appear in the rollup.
- `_pmrp_head_ci_ready` evaluates "any required context is null → pending" before looking for failures, so it returns 1 (silent defer) every pass. `pulse.log` has only `skipping PR #N ... PR is draft or has hold-for-review` lines for the PR: no CI-repair route (t19244), no notice, no ATTENTION.

The normal merge-pass path already treats this head as red: `_check_required_checks_has_terminal_failure` in `.agents/scripts/pulse-merge-required-checks.sh` ignores absent contexts and counts terminal failures, and `pulse-merge-process.sh` only waits for absent/active contexts when no terminal failure exists. The held path's comment claims its states match those helpers, but the precedence differs.

## How

In `_pmrp_head_ci_ready`, keep the single exact-head rollup read and classify in this order:

1. Any required context present with an empty conclusion or an active status (`queued|pending|in_progress|waiting|requested`) → `pending` (unchanged: never route repair while a required check is running; covers same-SHA re-runs).
2. Else any required context whose latest run concluded `failure|cancelled|timed_out` → `red:<names>` (absent contexts no longer mask it; they are downstream jobs that cannot start).
3. Else any required context absent → `pending` (not yet created).
4. Else → `green`.

Update the function comment to state the precedence. No other behaviour changes.

## Acceptance

- `.agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh`: add a case where one required context failed and another is absent from the rollup; it must log `deferred: required checks failing (<name>)` and route one CI repair. Existing cases (all pending, failure beside an active check, red, green, re-run turns red) keep their expectations.
- `bash .agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh` passes; ShellCheck clean on both files.

## Files Scope

- `.agents/scripts/pulse-merge-runtime-pending-notice.sh`
- `.agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh`
