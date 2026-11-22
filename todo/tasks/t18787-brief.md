<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# t18787: Feedback routes close worker PRs while the worker dispatch lease is still live

## What

Feedback routes (review, CI fallback and conflict) finalize a worker PR without checking whether the linked issue still has a live headless worker dispatch lease. The route strips the live worker's assignee and status, closes the PR, races the worker's next push, and leaves both the PR and the issue on an automation `hold-for-review` that nothing owns afterwards.

## Why (evidence)

- #35824 / PR #35835 (2026-10-28 UTC): worker attempt `attempt:eb8097e5…` held a `DISPATCH_LEASE phase=ready` lease from 14:04:33 (expiry 16:04:33) until its terminal lease at 15:04:36.
  - 14:57:53–57: the review route's `_transition_issue_for_redispatch` removed the assignee and replaced `status:in-progress` with `status:available` while the worker was live.
  - 14:58: the route closed the PR expecting head `d75bd23a`, but the live worker had pushed `108d31ab`. `_feedback_route_restore_after_postclose_failure` reopened the PR, could not verify the original head and applied `hold-for-review` (14:58:19) plus `AUTOMATION_HOLD_PROVENANCE` (14:58:39).
  - 15:04:20–38: the worker posted `CLAIM_RELEASED reason=worker_complete` and its terminal lease. The issue was left `status:available` + `hold-for-review` with a blocked PR.
- Replaying `dispatch-lease-claims.jq` against the real #35824 comments gives one active ready claim at 14:57:50, 14:58:10 and 15:04:30, and none from 15:05:00. `dispatch-claim-helper.sh check` would have returned 0 throughout the route window.
- `_feedback_route_owner_allows` fences interactive claims only. No route step reads the headless dispatch lease, and labels are not a liveness signal.
- #35884 (GH#35867) stopped bot-only change requests from starting the review route. Trusted human change requests, the CI fallback and conflict routes still finalize through `_finalize_feedback_route`.

## How

1. `.agents/scripts/pulse-merge-feedback-finalizer.sh`: `_feedback_route_worker_lease_allows <issue> <repo>` runs the sibling `dispatch-claim-helper.sh check` and allows the route only on exit 1 (no active claim). Exit 0 (prelaunch or ready lease, or a repository the runner cannot manage) and any other exit (unreadable state) defer. Reference pattern: `dispatch-dedup-helper.sh` `check-claim`.
2. `_feedback_route_prepare_finalization_snapshot` calls it right after the PR snapshot, only when the PR is OPEN. That is before the head-drift maintainer hold, the issue transition and the close. Deferral returns `PULSE_FEEDBACK_ROUTE_DEFERRED_RC`, which `_route_pr_preserve_deferred_retry` already retries on later cycles. `DISPATCH_READY_LEASE_TTL` (7200s) bounds a dead worker's lease.
3. Resumes of routes whose PR is already CLOSED are unchanged, so a route that already closed its PR is never blocked by a newly dispatched worker.

### Files Scope

- `.agents/scripts/pulse-merge-feedback-finalizer.sh`
- `.agents/scripts/tests/test-pulse-merge-fix-worker-dispatch-cases.sh` (stub the new predicate beside the existing interactive-fence stub)
- `.agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh` (same stub, and the harness repair below)

### Harness repair (pre-existing break from GH#35867 / PR #35884)

PR #35884 changed `_handle_changes_requested_review_gate` to read `_PULSE_MERGE_DIR` and `_review_feedback_active_change_requests`, and to dismiss bot-only requests through `review-bot-gate-helper.sh dismiss-advisory-coderabbit` instead of `_pulse_merge_dismiss_coderabbit_nits`. The CI-route harness was not updated. On base `d47f778316` the suite aborts after 13 of 79 cases with `_PULSE_MERGE_DIR: unbound variable`. No workflow runs this suite, so the break merged unseen.

The harness now sets `_PULSE_MERGE_DIR`, stubs `_review_feedback_active_change_requests` (default: one trusted human request; it fails closed if production removes the function), and records advisory dismissals through a stub `AIDEVOPS_REVIEW_BOT_GATE_HELPER`.

## Acceptance Criteria

- A route on an OPEN PR whose linked issue has an active dispatch claim or lease defers with no issue or PR writes.
- After the terminal lease or lease expiry, the route proceeds unchanged.
- Existing route suites keep passing.

## Verification

- `bash .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`: 79 run, 0 failed (base: aborted after 13).
- `bash .agents/scripts/tests/test-pulse-merge-fix-worker-dispatch.sh`: 52 run, 0 failed.
- `bash .agents/scripts/tests/test-pulse-merge-closed-issue-route.sh` and `bash .agents/scripts/tests/test-integration-recovery.sh` pass.
- `shellcheck -x` on the changed shell files reports zero violations.
