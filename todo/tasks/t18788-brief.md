<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18788: Pulse-merge regression suites drift unseen: repair harnesses and run them in Framework Validation

## What

Pulse-merge regression suites drift silently because CI runs only 3 of the 49 `test-pulse-merge-*.sh` suites. Repair the drifted harnesses and make Framework Validation run every pulse-merge suite whenever pulse-merge sources or their tests change, so a change that breaks a suite cannot merge unseen.

## Why (evidence)

- `.github/workflows/code-quality.yml` Framework Validation (a required check) runs only `test-pulse-merge-approve-collaborator-guard.sh`, `-ruleset-fallback.sh` and `-phantom-pending-checks.sh`.
- On `origin/main` `d47f778316` (2026-10-29), seven suites fail or abort. Each failure is harness drift from a merged production change, not a reported behaviour regression:
  - `test-pulse-merge-ci-repair-routing.sh` aborts after 13 of 79 cases (`_PULSE_MERGE_DIR: unbound variable`) and `test-pulse-merge-review-thread-remediation.sh` fails 14 of 27 (`_review_feedback_active_change_requests: command not found`). Cause: GH#35867 / PR #35884 review-gate dependencies. The ci-repair-routing harness is repaired in PR #35941 (t18787); this task covers the rest.
  - `test-pulse-merge-stuck-auto.sh` fails 8 of 8 (every case returns 2): the fixture lacks `.head.ref` / `.labels` for the protected-release identity read added by GH#35798 / PR #35861 in `_set_native_auto_merge_or_skip`. The t3192 stuck native auto-merge fallback ("PRs that never merge") is therefore unguarded.
  - `test-pulse-merge-rest-readiness.sh` aborts (`_PMP_CHECK_FAILURE: unbound variable`).
  - `test-pulse-merge-pr-json-fields.sh` fails 1 of 6 (merge-ready list failure fallback).
  - `test-pulse-merge-first-nonblocking.sh` fails its static ordering check: `pulse-dispatch-engine.sh` now calls `_preflight_early_dispatch` through `_pulse_run_budget_priority_stage`, so the line-anchored grep no longer matches.
  - `test-pulse-merge-superseded-duplicates.sh` exits 1 without a FAIL line: GH#30610 made `_psh_find_merged_closer_for_closed_issue` call `_psh_gh_read`, which the harness never extracted; production's `2>/dev/null` hid the missing-function error.
  - In `test-pulse-merge-review-thread-remediation.sh`, the external-contributor case still expected the close-and-redispatch route that GH#35867 removed on purpose (`#aidevops:trust-boundary`: external-contributor PRs are held, never routed).
- Merge and routing defects then reach production and surface as stranded issues, comment loops and unmerged PRs (for example #35824 / PR #35835).

## How

1. Repair each drifted harness to match current production contracts. Never weaken an assertion to fit a behaviour change: if a failure turns out to be a production regression, fix production or report it with evidence.
2. Add a Framework Validation step in `.github/workflows/code-quality.yml` that runs every `.agents/scripts/tests/test-pulse-merge-*.sh` and `*.py` suite (a glob, so new suites are covered automatically; `*-cases.sh` / `*-mocks.sh` are sourced fixtures). It runs whenever Framework Validation runs: the suites also read `.agents/configs/`, so narrower path scoping would reopen the gap. Suites run in parallel (`nproc`) with a private `HOME`/`TMPDIR` each and a per-suite timeout; failures print the suite log in a group and fail the job. Reference pattern: the existing "Approve Collaborator Author Guard" step.

### Files Scope

- `.github/workflows/code-quality.yml`
- `.agents/scripts/tests/test-pulse-merge-review-thread-remediation.sh`
- `.agents/scripts/tests/test-pulse-merge-stuck-auto.sh`
- `.agents/scripts/tests/test-pulse-merge-rest-readiness.sh`
- `.agents/scripts/tests/test-pulse-merge-pr-json-fields.sh`
- `.agents/scripts/tests/test-pulse-merge-first-nonblocking.sh`
- `.agents/scripts/tests/test-pulse-merge-superseded-duplicates.sh`

## Acceptance Criteria

- Every `test-pulse-merge-*` suite exits 0 on the branch, on macOS locally and on the CI Ubuntu runner.
- Framework Validation runs the full pulse-merge suite set and fails when any suite fails.
- No production behaviour changes unless a confirmed regression is fixed and named in the PR.

## Verification

- Run the step's `run:` block locally from the repo root: all 49 suites (47 shell, 2 Python) report `rc=0` (about 50 s in parallel on macOS).
- A scratch repo with one failing, one passing and one `*-cases.sh` fixture: the block runs 3 suites, prints the failing log in a group and exits non-zero.
- `shellcheck` on changed shell files; `actionlint .github/workflows/code-quality.yml`.
- The PR's Framework Validation log shows the new step running the suite set.
