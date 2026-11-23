## What

`full-loop-helper.sh commit-and-pr` never readies an existing draft PR it continues. When an issue already has an open PR on the current branch, `_create_or_continue_pr` (`.agents/scripts/full-loop-helper-commit.sh:1384-1401`) reconciles the origin label, body metadata and base, then returns the PR number. If that PR is a draft, it stays a draft, even for a worker completion or an interactive `--ready` run. Make the continuation path mark a draft ready when the run is a completion and the pushed head equals local `HEAD`.

## Why

- The worker first-pass contract item 5 (`.agents/scripts/pulse-dispatch-worker-prompt.sh:586`) tells workers to push and open a draft PR early, then says that "the PR is non-draft" once complete, but gives no supported way to get there. `.agents/prompts/worker-efficiency-protocol.md:26` says to finish with raw `gh pr ready`. `.agents/workflows/full-loop.md:159` says "worker PRs always open non-draft".
- A worker that opens the early draft and then completes with `commit-and-pr` keeps a draft. Recovery currently relies on a later refusal: `wait-checks` exit 9 (`WAIT_CHECKS=draft-required-missing`, `.agents/scripts/gh-checks-wait-helper.sh:808`) or the merge readiness refusal (`.agents/scripts/full-loop-helper-readiness.sh:557`), then a manual `gh pr ready`, then another check wait. If the worker exits first, the finish classifier sees a draft checkpoint and schedules a continuation worker for already-complete work.
- Evidence (2026-11-22): of the 50 most recently merged `origin:worker` PRs in this repository, 2 (#39790, #39766) were opened as drafts and readied manually later. The other 48 opened non-draft, which suggests most workers skip the early-draft step that item 5 asks for.

## How

1. In `_create_or_continue_pr`, after `_retarget_continuation_pr_base`, read the continued PR's `isDraft`. If it is a draft and either `origin_label` is `origin:worker` or `${create_ready:-0}` is 1, use `_effective_pr_ready 1 "$branch_name"` (same file, line 1433) to confirm that the pushed head matches local `HEAD`, then mark the PR ready. Follow the raw-call pattern in `_gh_create_pr_ready_recovered_draft` (`.agents/scripts/shared-gh-wrappers-create.sh:1235-1246`, `_gh_with_timeout write gh pr ready ... # aidevops-allow: raw-gh-wrapper`). If readying fails, print a warning with the exact `gh pr ready` command and keep going (the draft stays a durable checkpoint).
2. Interactive runs without `--ready` keep the existing draft (unchanged behaviour). Non-draft continuations are unchanged.
3. Align the wording: in item 5 of `.agents/scripts/pulse-dispatch-worker-prompt.sh:586`, say that the final `full-loop-helper.sh commit-and-pr` marks the continued draft ready. Replace "finish with `gh pr ready`" in `.agents/prompts/worker-efficiency-protocol.md:26` with the same statement. In `.agents/workflows/full-loop.md:159` (and its mirror `.agents/scripts/commands/full-loop.md` if the same sentence appears), note that `commit-and-pr` readies a continued worker draft.

### Files Scope

- `.agents/scripts/full-loop-helper-commit.sh`
- `.agents/scripts/pulse-dispatch-worker-prompt.sh`
- `.agents/prompts/worker-efficiency-protocol.md`
- `.agents/workflows/full-loop.md`
- `.agents/scripts/commands/full-loop.md`

## Acceptance

- A worker-origin `commit-and-pr` that continues its own draft PR leaves the PR non-draft at the verified pushed head, and `wait-checks` no longer returns exit 9 for it.
- `commit-and-pr --ready` from an interactive session that continues a draft readies it. Without `--ready`, the draft is kept.
- A pushed-head mismatch keeps the draft and prints the `gh pr ready` command.

## Verification

- `shellcheck -x .agents/scripts/full-loop-helper-commit.sh .agents/scripts/pulse-dispatch-worker-prompt.sh`
- Existing suites that cover the continuation path: `bash .agents/scripts/tests/test-full-loop-commit-and-pr.sh` (or whichever suites `affected-tests-helper.sh run --base origin/main` selects for `full-loop-helper-commit.sh`).
- Product path: from a worker-style worktree with an open draft PR for the issue, run `full-loop-helper.sh commit-and-pr --issue <N> --message ...` and confirm with `gh pr view <PR> --json isDraft` that the PR is ready afterwards.
