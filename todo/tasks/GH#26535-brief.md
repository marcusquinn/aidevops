# GH#26535 — Review-thread remediation before PR closure

Worker-ready issue body at https://github.com/marcusquinn/aidevops/issues/26535

## Goal

Add an opt-in pulse merge setting so worker PRs with
`reviewDecision=CHANGES_REQUESTED` can try review-thread remediation before
closing the PR and redispatching the linked issue.

## Files Scope

- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/tests/test-pulse-merge-review-thread-remediation.sh`

## Required behavior

- Preserve the default fast-routing policy: non-CodeRabbit
  `reviewDecision=CHANGES_REQUESTED` still routes feedback to the linked issue
  and closes the worker PR.
- When `AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1`, dispatch
  `pr-review-thread-response-scanner.sh dispatch-pr` with human review threads
  included before routing.
- When remediation dispatch succeeds, return early from the merge gate and keep
  the PR open for the remediation cycle.
- In opt-in mode, only fall back to `_route_pr_to_fix_worker` when remediation
  is unavailable, repo lookup fails, or dispatch fails.
- Preserve the existing unresolved-conversation merge-blocker remediation path.

## Verification

- `.agents/scripts/tests/test-pulse-merge-review-thread-remediation.sh`
- ShellCheck on touched shell files.
