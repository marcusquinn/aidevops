# fix(pulse): partial-continuation revisit walks past merged PRs that target a different issue

## Origin

Interactive productivity mission session, 2026-11-19. Evidence from a read-only dry run and a guarded real-write drain of stranded `status:in-review` issues in a managed product repository (private; name withheld).

## What

`_pmpc_revisit_in_review_issue` (`.agents/scripts/pulse-merge-partial-continuation.sh`) walks an in-review issue's merged cross-referenced PRs newest first. It skips PRs that close a sibling issue (GH#38869), but it stops at the first non-closing PR and hands it to `_pm_restore_partial_continuation`. When that PR only mentions the issue — `For #<other>`, a prose mention, or an `origin:interactive` PR about other work — the guard returns silently and the walk ends. The older worker partial that really targets the issue is never examined, so the issue stays `status:in-review` with no owner and no open PR.

Make the walk skip any merged PR that provably does not target the revisited issue, and stop only at a PR that closes or targets it (or whose metadata is unreadable or ambiguous). Bound the walk.

## Why

- One stranded issue's newest merged cross-reference was a PR whose body said `For #<other issue>` and only mentioned the stranded issue in prose. The walk stopped there, and the older partial for the issue was never revisited.
- In the product repository, 133 open `status:in-review` issues existed and 109 were not referenced by any open PR (sample median idle 1.1 days). A bounded drain that walks past silent guard returns restored issues through the unchanged `_pm_restore_partial_continuation` guard. Workers picked them up again, which Pulse would have done unaided if the walk were correct.
- Each such issue otherwise waits for a person to start an interactive session, which is the friction this framework exists to remove.

## How (Approach)

- `.agents/scripts/pulse-merge-partial-continuation.sh`:
  - Add `_pmpc_pr_may_own_issue <pr> <repo> <issue>`. It reads the PR body once and returns 1 (skip) when the PR closes another issue, or when its explicit `For`/`Ref` target is absent or another issue and its title cannot corroborate this issue (`^(t|GH#)<issue>`). It returns 0 (hand to the guard) when the PR closes or targets this issue, has a closing reference in an unparsed form, or any read is unreadable or ambiguous (fail closed).
  - In `_pmpc_revisit_in_review_issue`, replace the closing-only sibling check with this helper, keep the GH#38869 log line for skipped PRs, and cap walked PRs with `PULSE_PARTIAL_REVISIT_MAX_PRS` (default 10).
  - Leave `_pm_restore_partial_continuation` unchanged. It still re-reads all issue, PR and comment state and makes the decision.
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh`: add cases next to the GH#38869 block (`rg -n "GH#38869" .agents/scripts/tests/test-pulse-merge-partial-continuation.sh`):
  - the newest merged PR is non-closing with `For #<other>`, and the older partial restores;
  - the newest merged PR's body is unreadable, so there is no restore;
  - the walk cap stops before an eligible PR beyond the cap.

### Files Scope

- `.agents/scripts/pulse-merge-partial-continuation.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh`

## Acceptance Criteria

- `bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh` passes, including the new cases.
- `shellcheck .agents/scripts/pulse-merge-partial-continuation.sh` reports no findings.
- After deploy, a Pulse revisit pass restores a stranded issue whose newest merged cross-reference targets a different issue. The evidence is a `kind=merged-partial-continuation` marker naming the older PR.
