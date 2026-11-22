## What

Stop a cancelled re-run of a check that already passed on the same PR head from blocking Cloudron release approval requests and approved merges indefinitely. `release_checks` should drop a `cancel` bucket entry when the same-named check has a `pass` entry on that head. Then the routine `r924` request and merge paths treat the PR as terminal-green.

## Why

`.agents/scripts/cloudron-release-approval-helper.sh:50-58` (`release_checks`) requires every `gh pr checks` entry to be `pass` or `skipping`. `gh pr checks` lists every run for the head, including a later attempt that was cancelled.

Observed on one managed Cloudron package PR (opened 2026-11-19). `gate / review-bot-gate` passed on the `pull_request` run at 02:19:35Z. A second run of the same check, triggered by the CodeRabbit `pull_request_review` event, was cancelled 2 seconds after it started (02:23:24Z). Every r924 pass since then has logged `release approval request waits for terminal-green checks`. After more than 2 days the PR still has `release-approval-required` + `hold-for-review` and no release issue, so the maintainer has nothing to sign. Two sibling packages whose checks had no cancelled re-run got release issues normally.

The review-bot verdict itself is still enforced separately: `release_review_threads_clear` refuses unresolved review-bot threads before both request and merge.

### Files Scope

- `.agents/scripts/cloudron-release-approval-helper.sh`
- `.agents/scripts/tests/test-cloudron-release-approval.sh`

## How

- Change the test file only if an existing case asserts the old all-buckets behaviour.
- In `release_checks`, group checks by `.name`. Within a group that has at least one `pass`, drop the `cancel` entries, then apply the existing all-`pass`/`skipping` and preflight-pass test to the filtered list. Print the filtered list too, so the release issue's recorded evidence does not show the superseded cancellation.
- Keep failing closed for: a `fail` entry (in any group), a `cancel` with no same-named `pass`, `pending`, and an empty or all-skipped suite.
- Reference pattern: the GH#35830 cancel handling in `.agents/scripts/gh-checks-wait-helper.sh` (`only_cancelled_failures`, `apply_cancel_grace`) and the GH#39664 superseded-cancel rule in `.agents/scripts/pulse-merge-required-checks.sh` (`_pmrc_is_superseded_forge_recorder`).

## Acceptance

- `cloudron-release-approval-helper.sh process --repo <the affected package repo>` (dry run) no longer prints `waits for terminal-green checks` for the affected PR. `process --apply` then creates its release issue.
- A PR whose only non-green check is a cancelled run with no same-named pass is still refused.
- A failing check is still refused even when an earlier run of the same name passed.
- ShellCheck is clean, and the existing `test-cloudron-release-approval.sh` passes.
