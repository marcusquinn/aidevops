<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CI Gate Policy

Use CI as a throughput control, not a progress trap. Required merge gates should
match the risk of the target branch; slower integration checks should create
feedback loops when they find defects.

## Default policy

| Target | Required gates | E2E role | Merge posture |
|---|---|---|---|
| `develop` / integration work branch | Format, lint, typecheck, unit tests, cheap security/secret checks | Skipped or advisory by default | Optimise for continual progress and rapid worker feedback. |
| `staging` / release candidate | Core gates plus E2E/smoke tests relevant to promoted areas | Required when it protects the promotion path | Optimise for integrated confidence before production-like deployment. |
| `main` / production release | Core gates, release checks, required E2E/smoke/security checks | Required where branch rules declare it | Optimise for release assurance and auditability. |

## Design rules

1. Keep develop PR required checks fast and deterministic. Prefer format, lint,
   typecheck, and unit tests over broad browser suites.
2. Do not require "branch up to date" on high-throughput develop queues unless
   the repository has a merge queue that batches/revalidates automatically.
3. Run E2E at staging or release-promotion boundaries, where integrated state is
   the product under test.
4. Treat develop E2E as advisory unless the PR directly changes the exact
   critical path under test and the test is stable enough to provide useful
   signal.
5. Convert advisory E2E, visual, performance, and flaky integration findings
   into follow-up tasks with worker-ready evidence instead of blocking unrelated
   develop PRs or spawning duplicate worker attempts.
6. If an E2E failure is required by branch protection, fix or explicitly
   quarantine the failing path before merge; do not bypass production/release
   gates silently.
7. In JS/TS monorepos, make affected-package checks non-recursive. For Turbo,
   a broad filter such as `--filter="...[origin/<base>]"` can include the
   workspace root; if root `lint`/`typecheck` scripts call Turbo, exclude root
   with `--filter="!//"` or run root checks in a separate job.

## Ruleset checklist

- Develop ruleset:
  - required status checks: core gates only;
  - strict required status checks: off, or replaced by a merge queue;
  - E2E contexts: not required.
- Staging/release ruleset:
  - strict status checks or merge queue: on;
  - E2E/smoke checks: required for the promotion surface;
  - deployment and environment gates: explicit and auditable.

## Follow-up issue pattern

When an advisory check discovers a defect:

1. Verify the failure is reproducible or cite the exact CI run/check URL and
   first failing assertion.
2. File a task with:
   - files/specs implicated;
   - expected vs actual behaviour;
   - branch/check context where it was observed;
   - reproduction or artifact path;
   - verification command.
3. Reference the source PR/check using `For #NNN` or `Ref #NNN`, not a closing
   keyword unless the new task is the direct fix.
4. Let the original PR proceed if its required gates are green and the advisory
   finding is not a defect introduced by that PR.

This mirrors review-bot handling: additive or broader findings become follow-up
work; only defects in the PR's own code block the PR.

## Anti-patterns

- Full E2E on every develop PR when most failures are unrelated flakes.
- Parallel update/rerun of many PRs when each merge invalidates the next one's
  strict up-to-date checks.
- Redispatching new workers for advisory E2E failures instead of filing focused
  follow-up tasks.
- Treating delayed, pending, cancelled, or infrastructure-timed-out checks as
  proof of a source-code defect.
- Broad affected Turbo lint/typecheck filters that include a recursive root
  script, making CI look hung or quiet instead of testing changed packages.
