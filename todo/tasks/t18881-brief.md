## What

For fork PRs, have `review-bot-gate` fetch its helper from the base repository's `main`, not from the PR head SHA.

## Why

`.github/workflows/review-bot-gate.yml` line 84 passes `aidevops_ref: ${{ github.event.pull_request.head.sha || 'main' }}`. The reusable workflow then checks out the framework scripts at that ref (`review-bot-gate-reusable.yml` ~line 115) and runs `__aidevops/.agents/scripts/review-bot-gate-helper.sh`.

This was intended for self-modifying gate PRs from the same repository. It has two effects on fork PRs:

1. The PR's own copy of the helper decides the PR's own `review-bot-gate` result. Since GH#36931 the gate is not a merge authority, because external merges need an exact-head V2 crypto approval. It still matters for repositories that opt into `completion_behavior: strict`.
2. Gate-policy fixes on `main` do not reach open fork PRs until the fork branch is updated. That update changes the head and invalidates the maintainer approval. Example: external PR #36845 kept running the pre-GH#36931 helper after the fix.

## How

- `.github/workflows/review-bot-gate.yml`: pass the PR head SHA only when `github.event.pull_request.head.repo.full_name == github.repository`. Otherwise pass `main`. Pattern: the same-repository test already in `review-bot-gate-reusable.yml`'s trust block (`REVIEW_GATE_PR_HEAD_REPOSITORY` vs `REVIEW_GATE_PR_BASE_REPOSITORY`).
- Check whether other callers pass the same `aidevops_ref` pattern to framework-fetching reusable workflows: `rg -n "aidevops_ref: \$\{\{ github.event.pull_request.head.sha" .github/workflows`.

### Files Scope

- `.github/workflows/review-bot-gate.yml`
- `.agents/scripts/tests/test-linked-issue-guidance.sh`

## Acceptance

- A same-repository PR still runs its own helper revision.
- A fork PR's gate runs `main`'s helper. To confirm, check that the workflow log's checkout ref for `__aidevops` is `main` on a fork PR.
- actionlint passes on the edited workflow.
