# t18923: prove open-PR state from GraphQL when REST is deferred

Ref: GH#37385

## What

When the REST call for open pull requests fails, prove open-PR state from GraphQL instead. This is the check that gates worktree retirement (`worker_lifecycle/pull_requests.py`, `open_pull_requests`). It covers the case where the `gh` transport governor defers REST (exit 75) because the core pool is spent. Then cleanup can keep retiring finished worker worktrees while REST is exhausted, which keeps dispatch capacity open.

## Why

Every automatic retirement path (observation-era cleanup, registry cleanup) needs complete open-PR evidence before it removes a worktree. Today that evidence comes only from REST: `gh api repos/{slug}` plus paginated `repos/{slug}/pulls?state=open`. When the REST core pool is exhausted, which happens most hours under current load, every lookup fails. Every tree for that repository is then held as `pull-request-state-unavailable`. Cleanup stalls, worktree counts stay above `AIDEVOPS_MAX_WORKTREES`, and dispatch fails closed with `worktree capacity unavailable`. GraphQL has its own rate-limit pool, which usually has headroom then.

## Evidence

- `cleanup_worktrees.log`, the last 12 "Observation-era cleanup" passes: passes with `pull-request-state-unavailable` holds of 147 and 113 retired 7 and 2 trees. Passes without them retired 17–25.
- REST core at 78 remaining and GraphQL at 4804 remaining at the same moment (`gh api rate_limit`, 2026-11-09 ~15:57Z).
- Pulse `Dispatch_capacity`: `simultaneous_target_final=20 active_workers=1`, with `Live worktree count … >= cap 200 … dispatch remains fail-closed` for two managed repositories at the same time.

## How

1. `.agents/worker-lifecycle/worker_lifecycle/pull_requests.py`: keep the REST path as `_rest_open_pull_requests`. Add a GraphQL path that collects every page of open PRs and walks the fork parent chain to its root, with page and depth limits. Map nodes to the REST `head.{ref,sha,repo.full_name}` shape with the same validation. Fall back only when a REST call fails (`OSError`, `SubprocessError`). Malformed REST evidence still holds, and a failed or malformed fallback re-raises the REST error.
2. `.agents/worker-lifecycle/tests/test_pull_requests.py`: route `gh api graphql` in the mock (default: failure). Add fallback, malformed-fallback and no-fallback-on-malformed-REST cases.
3. `.agents/worker-lifecycle/CLEANUP.md`: document the fallback.

## Acceptance

- `test_pull_requests.py` passes. The other worker-lifecycle suites, ruff and mypy (linux and darwin) have no new failures.
- With REST deferred and GraphQL available, an open PR whose head SHA or branch matches holds, and complete evidence with no match does not hold.
- Any GraphQL error, missing page cursor or malformed node holds (`pull-request-state-unavailable`).
- Live parity: GraphQL and REST evidence are equal sets for two managed repositories.
- After deploy, during a REST-exhausted window, "Observation-era cleanup" no longer reports a whole-repository `pull-request-state-unavailable` hold.
