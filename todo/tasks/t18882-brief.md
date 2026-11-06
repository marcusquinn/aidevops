## What

Have fork PRs get a `review-bot-gate` commit status on every push, without waiting for a review bot to comment.

## Why

The required `review-bot-gate` context is a commit status. A fork `pull_request` run gets a read-only token (`Statuses: read`), so the status post fails with 403. Example: PR #36845, head `918edf4761`, run `42284687451` logged `Helper result: PASS_RATE_LIMITED`, then `Resource not accessible by integration`.

On fork PRs, only bot-actor `issue_comment` / `pull_request_review*` events run in base context, and those are the only runs that can write the status. If CodeRabbit is silent (for example, review limit reached), the status keeps its last value forever. That holds even after GH#36931 (advisory for all authors) and GH#36954 (fork PRs run main's helper). This is the remaining structural reason "waiting on CodeRabbit" blocks fork PRs.

## How

- Add `pull_request_target: types: [opened, synchronize, reopened]` to the self-caller and the downstream caller template.
- Eligibility matrix, kept identical in all three files (parity test GH#28316):
  - `pull_request` only when `github.event.pull_request.head.repo.full_name == github.repository`
  - `pull_request_target` only when it differs
  - bot-actor events unchanged
- Safety: for fork PRs the reusable workflow checks out only the aidevops scripts at `main` (GH#36954), never PR code. Attacker-controlled fields reach shell only through `env:`.
- Extend the eligibility evaluator in `test-reusable-workflow-caller.sh` with head/base repository inputs and fork fixtures.

### Files Scope

- `.github/workflows/review-bot-gate.yml`
- `.github/workflows/review-bot-gate-reusable.yml`
- `.agents/templates/workflows/review-bot-gate-caller.yml`
- `.agents/scripts/tests/test-reusable-workflow-caller.sh`
- `.agents/reference/review-bot-gate.md`

## Acceptance

- A fork PR push produces a `pull_request_target` gate run that posts the `review-bot-gate` status for the exact head, with no review-bot comment and no fork-run approval.
- Same-repository PRs keep a single `pull_request` evaluator.
- `test-reusable-workflow-caller.sh` and actionlint pass.
