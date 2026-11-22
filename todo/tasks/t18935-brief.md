## What

Stop spending headless worker dispatches on already-satisfied rollout issues, and credit workers that correctly close one without a PR.

## Why (evidence)

1. **r914 files duplicate trust-workflow issues from stale local checkouts.** `check-workflows-helper.sh` is deliberately a no-network local audit (`.agents/scripts/check-workflows-helper.sh:663-666`). When a canonical checkout is behind `origin/main`, it reports `NO-WORKFLOW` for a caller already merged on the remote, and says so in its own note (`"local evidence; main is 4 commit(s) behind origin/main"`, `evidence.freshness: "behind"`). `_trust_install_one` (`.agents/scripts/repo-aidevops-health-helper.sh:736-808`) treats that as authoritative, creates the tracking issue (`:779`), and then the sync helper "made no PR". On 2026-11-09 19:41-19:51 the keeper re-filed `chore: install aidevops issue triage gate` on repos whose installs had merged on 2026-11-07 (about 10 duplicates, e.g. a cloudron app where the worker PR closing the first issue was merged two days earlier). Each duplicate costs one worker dispatch.
2. **No-PR closures are classified `premature_exit`.** `reference/worker-discipline.md` Outcome A says to close with a rationale comment and no PR, but `workflows/full-loop.md:143` says "Do NOT emit `TASK_COMPLETE` with uncommitted changes or no PR". The runtime accepts the marker for a closed issue with a clean worktree (`.agents/scripts/headless-runtime-result.sh:207-209`). No objective predicate covers a duplicate rollout issue: its body has no `### Files Scope` and the merged PR closes the earlier issue (`verify-issue-close-helper.sh:577-590`). So a worker that follows the docs exactly is recorded `premature_exit` (exit 77, `pr_less_completion_rejected`/`scoped_receipt_unavailable`). The continuation then trips the ownership fence on the closed issue (exit 85 → `worker_ownership_lost`), and the closed issue keeps `status:in-progress`. A sibling worker on the same task that emitted the marker anyway was credited `success`.

## How

### Files to modify

- EDIT: `.agents/scripts/repo-aidevops-health-helper.sh`. Add `_trust_remote_workflow_state <slug> <workflow>` (read-only `gh api repos/<slug>/contents/.github/workflows/<workflow>.yml`). Output `present` on success, `absent` only on an explicit HTTP 404, and `unknown` otherwise. In `_trust_install_one`, after `class == NO-WORKFLOW` and before the rate-limit/issue creation: `present` → log the stale local checkout and `echo present`; `unknown` → log and `echo skipped` (never file on unverified absence); `absent` → continue unchanged.
- EDIT: `.agents/workflows/full-loop.md` (and its mirror `.agents/scripts/commands/full-loop.md`, a symlink) completion criterion 5. Add the no-PR terminal exception: after a verified Outcome A close (pre-close gate 7 satisfied, closing comment posted, worktree clean, nothing pushed), end with `<promise>TASK_COMPLETE</promise>`.
- EDIT: `.agents/reference/worker-discipline.md` Outcome A. State the same terminal marker requirement and point to the criterion.

### Files Scope

- `.agents/scripts/repo-aidevops-health-helper.sh`
- `.agents/workflows/full-loop.md`
- `.agents/scripts/commands/full-loop.md`
- `.agents/reference/worker-discipline.md`

### Reference pattern

- Existing read-only `gh api "repos/${slug}"` probes in `_trust_repo_visibility` (`repo-aidevops-health-helper.sh:650-686`).
- Runtime marker acceptance: `headless-runtime-result.sh:205-210`.

## Acceptance criteria

- A stale local checkout whose remote default branch already has `.github/workflows/issue-triage-gate.yml` yields `present` and creates no tracking issue.
- A genuinely missing remote file (HTTP 404) still follows the existing install path.
- Any other API failure files nothing (skipped) for that run.
- Worker docs no longer contradict each other on the no-PR terminal marker.

## Verification

- `shellcheck .agents/scripts/repo-aidevops-health-helper.sh`
- Exercise `_trust_remote_workflow_state` read-only against one repo whose local checkout is behind but whose remote has the file (expect `present`), and against a nonexistent workflow name (expect `absent`).
- `.agents/scripts/linters-local.sh` scoped markdown checks for the edited docs.
