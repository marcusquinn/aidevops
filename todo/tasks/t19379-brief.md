## What

Make `gh-checks-wait-helper.sh wait <PR> --all` treat a cancelled check run as superseded when the same workflow and check name already passed on the same PR head. Today it fails the wait after the 180 s cancel grace.

## Why

Observed on 2026-11-25 (PR #40361, head `eb6292833c`): `gh-checks-wait-helper.sh wait 40361 --repo marcusquinn/aidevops --all` ended with `FAIL: required checks reached a terminal failure` / `gate / review-bot-gate: cancel` while 56 checks passed and nothing was pending.

The cause is the Review Bot Gate concurrency in `.github/workflows/review-bot-gate.yml`. All events share `group: review-bot-gate-<PR number>` with `cancel-in-progress: false`, and GitHub keeps one pending run per group:

- 14:33:09 `pull_request` run: `gate / review-bot-gate` success on the PR head.
- 14:39:53 CodeRabbit posted a review and an inline comment. The `pull_request_review` and `pull_request_review_comment` runs queued on the PR head, then were cancelled without a runner (check runs 139283297759 and 139283299394).
- 14:39:57 CodeRabbit's `issue_comment` run 45636522460 in the same group superseded them and succeeded. GitHub attaches `issue_comment` check runs to the default-branch SHA (`6d0e386558`, `main`), so the successor never appears on the PR head.

The PR head therefore keeps an earlier pass plus cancelled entries whose successor can never become visible there. The gate's real verdict is the `review-bot-gate` commit status on the head, which passed. This is not one PR's problem: 5 of the last 20 `pull_request_review` runs of Review Bot Gate across PRs were `cancelled`. `--all` is the mode recommended by the `gh pr checks --watch` refusal in `.agents/scripts/gh-transport-controls.sh:96` and by `.agents/workflows/error-feedback.md:28`, so every session and worker that follows that advice gets a false failure after a bot review and spends time diagnosing a green PR. The merge path's `_merge_admin_fallback_required_checks_clear` (`.agents/scripts/full-loop-helper-merge.sh:929`) uses required-only mode and is not affected.

The existing cancel tests (`.agents/scripts/tests/test-gh-checks-wait-helper.sh:482-608`) model a successor that replaces the cancelled entry in a later read. They never model the live shape, where a same-name pass and a cancel coexist in one read.

## How

### Files Scope

- `.agents/scripts/gh-checks-wait-helper.sh`
- `.agents/scripts/tests/test-gh-checks-wait-helper.sh`

### Changes

1. Next to `only_cancelled_failures` (`gh-checks-wait-helper.sh:623`), add a jq filter that removes `cancel` entries whose `(workflow, name)` pair also has a `pass` entry in the same read for the same head. Apply it to the check list before the failure test in the classifier (`:609-613`) and before `apply_cancel_grace` (`:1042`), so such a read classifies as `success` and the transition/heartbeat output still lists both entries.
2. Keep every other outcome authoritative. A same-name `fail` or `pending` entry, or a cancel with no passing sibling, behaves exactly as today: the GH#35830 grace, the GH#38537 hold while other checks are pending, and terminal after grace.
3. Add fixtures following the existing `write_fixture` / `run_fixture_wait` pattern:
   - one read with `Gate` pass (earlier `startedAt`) plus `Gate` cancel (later), both workflow `Review Bot Gate`, and grace 0 → exit 0 and `PASS: required checks completed`
   - `Gate` pass plus `Gate` cancel plus `Test` fail → exit 1, reporting `Test: fail`
   - `Gate` cancel alone with grace 0 → exit 1 (the existing `cancel_final` case must still pass)

## Acceptance

- `bash .agents/scripts/tests/test-gh-checks-wait-helper.sh` passes, including the three cases above.
- On a PR whose head carries a `gate / review-bot-gate` pass and later cancelled review-event runs, `gh-checks-wait-helper.sh wait <PR> --repo <owner/repo> --all` exits 0 once the other checks pass.
- ShellCheck is clean on both files.
