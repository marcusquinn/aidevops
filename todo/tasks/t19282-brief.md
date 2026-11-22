## What

The GH#39158 handover of stale `origin:interactive` draft PRs fails silently for orphan drafts, so they stay open indefinitely. Two PRs in this repository show it: #37733 (idle since 2026-11-11, `Ref #37552`) and #35518 (idle since 2026-11-08, no issue link). Each merge pass calls `_interactive_draft_pr_try_handover` (`.agents/scripts/pulse-merge.sh:1207-1208`, `|| true`), and nothing changes. Make the recovery handle a non-issue or closed `Ref`/`For` target, and log the reason whenever handover is refused.

## Why

- For #37733: `_interactive_pr_is_stale` (`.agents/scripts/pulse-merge-conflict.sh:416`) finds no closing issue (`_extract_linked_issue`), so `_interactive_draft_pr_try_handover` (`.agents/scripts/pulse-merge-author-checks.sh:365-388`) calls `_recover_interactive_pr_work_issue` (`.agents/scripts/pulse-merge-process.sh:1044`). At line 1062, `_extract_pr_work_issue` (`.agents/scripts/pulse-merge.sh:1864`) falls back to the body's non-closing `Ref #37552` and returns 37552. #37552 is a merged PR, not an issue. Recovery returns it as the existing work issue and never creates a tracking issue or a closing link. The second `_interactive_pr_is_stale` check (author-checks line 383) then fails again, so the PR stays stuck on every pass.
- For #35518 (no link): recovery should create a `Track interactive PR #35518` tracking issue, as it did for #36939 (#37038) and #36344 (#36408). It has not. Every gate in `_recover_interactive_pr_work_issue` and `_interactive_pr_is_stale` returns 1 without a log line, so the failing gate cannot be identified from `~/.aidevops/logs/pulse.log`. Over the same period, the log shows only "draft PR not eligible for auto-merge (GH#23525)", "unchanged since draft" and a repeated dirty-PR-sweep `origin-interactive-orphan` notify for #35518.
- Stale interactive drafts that never reach a worker are work a human must notice and restart by hand. That is the interactive dependency the pulse is meant to remove.

## How

1. In `_recover_interactive_pr_work_issue`, accept the `_extract_pr_work_issue` result only when it is an open issue: check with `gh api repos/{repo}/issues/{n}` that `.pull_request` is absent and `.state == "open"`. A merged or closed PR, or a closed issue, falls through to the existing tracking-issue creation path (lines 1067-1093). Keep the original `Ref` line in the body; the recovery appends `Resolves #<tracking>` as it already does (line 1099).
2. Give each `return 1` refusal in `_recover_interactive_pr_work_issue` and in the orphan path of `_interactive_draft_pr_try_handover` one `[pulse-wrapper] interactive-draft-handover: PR #N refused: <gate>` log line. Rate-limit it per PR and gate in the same way as the existing memo, or write it only when the gate changes, so it does not flood the log every pass.
3. Reproduce the #35518 failure with the new log lines (or a traced run of `_recover_interactive_pr_work_issue 35518 marcusquinn/aidevops` outside DRY_RUN in a worker sandbox). Fix the gate that is wrong. If the gate is correct (for example, an intentional trust refusal), make the log line name it, and record that reason on the PR once so it is not silent.

### Files Scope

- `.agents/scripts/pulse-merge-process.sh`
- `.agents/scripts/pulse-merge-author-checks.sh`
- `.agents/scripts/pulse-merge-conflict.sh`

## Acceptance

- A stale `origin:interactive` draft whose only link is `Ref`/`For` to a merged PR or closed issue gets a tracking issue and a closing link, then `origin:worker-takeover`, within one merge pass after the staleness threshold.
- An orphan draft with no link (like #35518) is either handed over, or logs the exact refusing gate once per change.
- Existing behaviour for `no-takeover`, `hold-for-review`, `needs-maintainer-review` and external-contributor PRs is unchanged (same trust gates).

## Verification

- `shellcheck -x` on changed scripts.
- `.agents/scripts/affected-tests-helper.sh run --base origin/main` passes.
- Product path: after deploy, `rg -n "interactive-draft-handover|PR #37733|PR #35518" ~/.aidevops/logs/pulse.log` shows handover or a named refusal, and `gh pr view 37733 --repo marcusquinn/aidevops --json labels` shows `origin:worker-takeover`, or the PR has been closed or merged through the worker pipeline.
