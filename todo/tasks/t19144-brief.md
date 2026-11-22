<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `commit-and-pr draft ready interactive PR` → 0 relevant hits.
- [x] Discovery pass: no open issue or PR adds a ready option to `commit-and-pr` (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:simple`. One flag mapped to an existing environment override, plus usage and workflow text.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** `gh_create_pr` opens every interactive PR as a draft (`.agents/scripts/shared-gh-wrappers-create.sh:1024-1037`) so mid-work checkpoints survive interruption. `workflows/full-loop.md:237` then requires each verified interactive full-loop to run a separate `gh pr ready` before merge. More than 200 `origin:interactive` PRs merged in the 7 days to 2026-11-19, and each paid that extra step. When it is missed, `full-loop-helper.sh merge` fails with `PR #N is a draft` (observed on PR #39207 and PR #39208 in one session). The late ready transition also re-runs gate workflows (two `CANCELLED` Maintainer Gate runs on #39207), and review bots that skip drafts only see the PR after readiness (`workflows/full-loop.md:296`). The opt-out already exists as `AIDEVOPS_PR_CREATE_READY=1`, which seven deterministic helpers set (for example `.agents/scripts/shared-todo-commit.sh:835`), but agents cannot discover it from `commit-and-pr`.

## What

Add `--ready` to `full-loop-helper.sh commit-and-pr` / `create-pr`. When it is set, the PR is created non-draft (run the `gh_create_pr` call with `AIDEVOPS_PR_CREATE_READY=1`). Without it, behaviour is unchanged: interactive PRs still default to draft. Update the usage line and `workflows/full-loop.md` Step 4.2 so verified implementation-intent sessions pass `--ready` instead of running `gh pr ready` afterwards; keep `gh pr ready` as the path for promoting an existing draft checkpoint.

## Why

This removes one mandatory step and one failure mode from every interactive full-loop. CI and review bots run once, on a ready PR.

## Tier

`tier:simple`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/full-loop-helper-commit.sh:123-217`. Parse `--ready` (no value) into a local `create_ready=1`, like `--keep-issue-open` at `:198`.
- EDIT: `.agents/scripts/full-loop-helper-commit.sh:1626-1638`. When `create_ready=1`, run the `pr_cmd` call as `AIDEVOPS_PR_CREATE_READY=1 "${pr_cmd[@]}"`. Scope the variable to that call only; do not export it.
- EDIT: `.agents/scripts/full-loop-helper.sh:83-90`. Add `[--ready]` to the usage line and a one-line description.
- EDIT: `.agents/workflows/full-loop.md:237`. Replace the post-create `gh pr ready` instruction with `--ready` for verified implementation intent; keep the draft default for checkpoints, review-first and incomplete work.

### Files Scope

- `.agents/scripts/full-loop-helper-commit.sh`
- `.agents/scripts/full-loop-helper.sh`
- `.agents/workflows/full-loop.md`

### Reference pattern

- `AIDEVOPS_PR_CREATE_READY=1 gh_create_pr ...` at `.agents/scripts/shared-todo-commit.sh:835`.
- Existing regression for the override: `.agents/scripts/tests/test-origin-label-mutex-create.sh:405-413` (case B8).

## Acceptance Criteria

- [ ] `full-loop-helper.sh commit-and-pr --ready ...` in an interactive session creates a non-draft PR; without `--ready` the PR is still a draft.
- [ ] `--ready` does not leak `AIDEVOPS_PR_CREATE_READY` into later commands in the same process.
- [ ] `bash .agents/scripts/tests/test-origin-label-mutex-create.sh` passes.
- [ ] ShellCheck reports no warnings for the changed shell files; markdownlint is clean for `workflows/full-loop.md`.
