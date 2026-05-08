<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t3576: Avoid redispatch for CI infra-only blockers

## Goal

Reduce duplicate worker PR churn by ensuring aidevops only routes CI repair feedback when a PR has actionable failed required checks. CI timeout/cancellation/advisory-only failures should remain blocked for retry/escalation/monitoring rather than closing the PR and redispatching another implementation worker.

## Context

The awardsapp convergence mission found many approved worker PRs blocked by CI timeout, kill, or advisory E2E failures rather than PR-specific code defects. Existing `pulse-merge-feedback.sh` treated `cancelled`, `timed_out`, and advisory/non-required failures as CI repair evidence, which closed PRs and requeued issues for duplicate worker attempts.

## Files

- `.agents/scripts/pulse-merge-feedback.sh`
- `.agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`
- `todo/missions/m-20260508-0e27c3/mission.md`

## Implementation Notes

- Keep pending/queued/in-progress checks non-terminal.
- Treat only actionable failed required checks (`failure`, `action_required`) as CI repair feedback.
- Skip repair routing for `timed_out`, `cancelled`, and advisory/non-required failures.
- Preserve fail-open behavior: if no actionable failed required check URL is available, do not close the PR.

## Verification

- `.agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`
- `shellcheck .agents/scripts/pulse-merge-feedback.sh .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`
- `.agents/scripts/linters-local.sh` for broader gates; note any repo-wide timeout separately.
