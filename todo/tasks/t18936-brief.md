## What

Credit a headless worker that correctly closes an already-satisfied or premise-falsified issue without a PR, using an evidence-bound receipt the runtime verifies independently. Today such a run is recorded `worker_noop_zero_output` even when the close is correct.

## Why (evidence)

- GH#37510 / PR #37512 documented the no-PR terminal exception: workers verify on the live remote default branch, post an evidence comment, close the issue, keep the branch clean, and emit the completion marker. That stops the wasted continuation (`premature_exit` → exit 85 `worker_ownership_lost`).
- The run is still not credited. `_run_result_terminal_completion_confirmed` (`.agents/scripts/headless-runtime-result.sh:205-210`) accepts the bare marker. But `_hrw_finish_success_run` in `.agents/scripts/headless-runtime-worker.sh:1845-1856` calls `_worker_produced_output` unless `_hrw_terminal_objective_complete` passes, and a clean zero-commit branch classifies as `noop` (`.agents/scripts/headless-runtime-worker-output.sh:234-246`). The result is `_report_failure_to_fast_fail worker_noop_zero_output`, a failure metric for a correct outcome.
- `_hrw_pr_less_terminal_complete` (`headless-runtime-worker.sh:784-840`) has no predicate for this shape. `_hrw_already_delivered_terminal_complete` (`:950-987`) needs a merged PR whose `closingIssuesReferences` names *this* issue. A duplicate rollout issue was satisfied by a PR that closed the *earlier* issue, and its body has no `### Files Scope`, so the scoped-delivery path fails as well.
- Found by CodeRabbit on PR #37512 (review thread on `.agents/workflows/full-loop.md:143`): "do not treat the `TASK_COMPLETE` marker alone as sufficient". The framework deliberately refuses self-attested PR-less closes. Every existing predicate binds to independent forge evidence.

## How

### Files to modify

- EDIT: `.agents/scripts/headless-runtime-worker.sh`. Add `_hrw_already_satisfied_terminal_complete session_key work_dir issue_number repo_slug issue_json`, modelled on `_hrw_review_triage_terminal_complete` (`:860-945`). Call it from the chain in `_hrw_pr_less_terminal_complete` (`:826-830`) after `_hrw_already_delivered_terminal_complete`. Skip it when `_HRW_REVIEW_TRIAGE_CANDIDATE` is set; review feedback keeps its own receipt. Set `_HRW_PR_LESS_REJECTION` to a constant reason at each step.
  - Receipt: one issue comment whose body starts `<!-- aidevops:already-satisfied-completion:v1 -->\n`, followed on line 2 by JSON: `schema` (1), `repository`, `issue`, `attempt_id`, `attempt_started_at` (must equal `AIDEVOPS_ATTEMPT_ID` / `AIDEVOPS_ATTEMPT_STARTED_AT`), `disposition` (`already_satisfied` | `premise_falsified`), `rationale` (string, ≥20 chars), `path` (repo-relative, no `.`/`..` segments), `blob` (40-hex), and `evidence_pr` (positive int; required for `already_satisfied`).
  - Independent checks (#aidevops:trust-boundary; trust forge metadata, never receipt claims):
    - The comment author is `gh api user` and is the issue's `closed_by`, with OWNER/MEMBER/COLLABORATOR association.
    - Comment `created_at` ≥ attempt start; `updated_at` ≤ issue `closed_at`; `html_url` matches the issue.
    - Exactly one such receipt.
    - The issue body contains `path` literally, which binds relevance.
    - The live default branch has `path` at `blob`: after `_hrw_pr_less_worktree_clean` (it fetches the live default tip into `FETCH_HEAD`), `git rev-parse FETCH_HEAD:<path>` equals `blob`.
    - For `already_satisfied`: `evidence_pr` is merged in this repo, and its files list `path`, not removed.
  - Return 0 only when all checks pass; the caller normalizes labels.
- EDIT: `.agents/reference/worker-discipline.md` Outcome A (line ~32), and the already-satisfied exception in `.agents/scripts/headless-runtime-lib.sh` (Mandatory behavior 6 and the pre-exit self-check). Tell workers to post this receipt (exact format) before closing, and say a bare marker is not credited.
- EDIT: `.agents/workflows/full-loop.md` criterion 5: point to the receipt.

### Files Scope

- `.agents/scripts/headless-runtime-worker.sh`
- `.agents/scripts/headless-runtime-lib.sh`
- `.agents/reference/worker-discipline.md`
- `.agents/workflows/full-loop.md`
- `.agents/scripts/tests/test-headless-runtime-completion-tests.sh`

### Reference pattern

- `_hrw_review_triage_terminal_complete` (`headless-runtime-worker.sh:860-945`): receipt binding to attempt, actor, closer, merged PR files, and live default blob.
- `_hrw_report_only_terminal_complete` (`:1106-1134`): comment URL binding.
- Existing review-triage cases in `.agents/scripts/tests/test-headless-runtime-completion-tests.sh` (run via `.agents/scripts/tests/test-headless-runtime-helper.sh`).

## Acceptance criteria

- A closed issue with a valid receipt, a clean branch, no pushed branch and no PR classifies as success (`_hrw_terminal_objective_complete` returns 0), not `worker_noop`.
- Each of these is rejected with a distinct `_HRW_PR_LESS_REJECTION`:
  - A missing, duplicated, stale (created before attempt start), or edited-after-close receipt.
  - A closer/author mismatch.
  - A path not named in the issue body.
  - A blob that differs from the live default.
  - `already_satisfied` without a merged evidence PR that touched the path.
- Review-feedback issues are unaffected.
- Existing completion tests still pass.

## Verification

- `shellcheck .agents/scripts/headless-runtime-worker.sh .agents/scripts/headless-runtime-lib.sh`
- `bash .agents/scripts/tests/test-headless-runtime-helper.sh`. Add focused accept/reject cases next to the review-triage cases; this is a trust-boundary predicate, so coverage is required.
- `.agents/scripts/linters-local.sh --changed --base-ref origin/main`
