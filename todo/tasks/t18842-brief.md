# fix(pulse-merge): route CI/review repair for worker PRs that use For/Ref instead of a closing keyword

## What

Worker PRs that declare their work issue with a standalone `For #N` / `Ref #N`
line instead of a closing keyword never get CI or review repair. The pulse
logs "routing to CI fix-worker" and then does nothing, without any diagnostic,
every cycle. Route these PRs to the same repair path as closing-keyword PRs,
and make any remaining unroutable case log a reason.

## Why

- PR #36213 (`For #36212`, `origin:worker`) failed `Framework Validation` at
  2026-10-31T09:14Z. The maintainer pulse log shows the merge gate associating
  it with #36212 ("worker-briefed auto-merge: PR #36213 ... issue #36212,
  link=non-closing reference"). It also shows the CI-drift rebase, then
  "routing to CI fix-worker" at 09:53Z. After that there is no
  `_dispatch_ci_fix_worker` line, no CI feedback on #36212 and no repair
  commit. The PR stays open with a failing required check and nothing works
  on it. These are the "PRs that never get merged".
- Partial deliveries and continuation checkpoints legitimately use `For`/`Ref`,
  so this affects any worker PR that is not a final, issue-closing delivery.

## Root cause

`_pmp_stage_required_checks` (`.agents/scripts/pulse-merge.sh`) passes
`linked_issue` from `_extract_linked_issue`, which accepts only closing
keywords, so it is empty for `For #N` PRs. `_check_pr_merge_gates` resolves the
explicit `For`/`Ref` identity for `origin:worker` PRs, but only into a
gate-local variable. That keeps partial deliveries away from post-merge
closing.

In `_route_pr_to_fix_worker`, `_route_pr_resolve_work_issue`
(`.agents/scripts/pulse-merge-process.sh`) resolves `For`/`Ref` only for
`kind=conflict` (GH#33763). For `ci` and `review` with an empty target, it
calls `_recover_interactive_pr_work_issue`. That function returns 1 for any
non-`origin:interactive` PR, and `|| return 1` returns before
`_route_pr_has_linked_issue` can log. The route silently returns 1, and the
caller treats it as "not routable".

## How

1. `_route_pr_resolve_work_issue`: for non-conflict kinds with no closing
   target, resolve the work issue with
   `_extract_pr_work_issue "$pr_number" "$repo_slug" explicit`. This is the
   same standalone `For`/`Ref` identity the merge gate already trusts, with no
   title inference.
2. Keep interactive recovery as the next fallback, but on failure fall through
   to `_route_pr_has_linked_issue` instead of `return 1`, so an unroutable PR
   always logs why.
3. Conflict routing is unchanged. All downstream gates still apply: origin
   labels, hold labels, closed-issue guard, terminal-route guard and in-place
   repair. The resolved issue is used only as the feedback and repair target,
   never for closing.

## Files Scope

- .agents/scripts/pulse-merge-process.sh

## Acceptance

- For an `origin:worker` PR whose body has `For #N` (no closing keyword) and
  failing required CI, `_route_pr_to_fix_worker ... ci` reaches
  `_dispatch_pr_repair_by_kind` with issue `N`.
- A PR with neither a closing nor an explicit `For`/`Ref` target logs
  `has no linked issue for <kind> repair routing` instead of returning
  silently.
- Conflict routing still uses repair-mode resolution.
- After deployment, PR #36213 (or the next non-closing worker PR with failing
  CI) gets a `_dispatch_ci_fix_worker:` log line in `~/.aidevops/logs/pulse.log`.

## Verification

```bash
shellcheck .agents/scripts/pulse-merge-process.sh
bash .agents/scripts/tests/test-pulse-merge-fix-worker-dispatch.sh
bash .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh
bash .agents/scripts/tests/test-pulse-merge-closing-contradiction.sh
```
