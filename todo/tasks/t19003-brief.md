<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Discovery pass: no open issue covers claim-state ordering; related closed perf work (#37874, #38022, #38226, #38237, #38261) changed census and caching, not round order.
- [x] Tier: `tier:standard`. Order-only change to an existing ordering chain; no gate is removed.

## What

Phase 1 of #38332. Order each dispatch round so unclaimed candidates are attempted before claimed ones. A claimed candidate has any assignee, `status:in-progress`, `status:in-review` or `status:claimed`. This is order-only, like the existing attempt-recency and debt-fairness ordering: every candidate still passes its live dedup/claim gates, and nothing becomes undispatchable. Claimed candidates are still evaluated when free slots remain after the fresh work.

## Why

`_filter_dispatchable_issue_candidates_json` (`.agents/scripts/pulse-repo-meta.sh:575`) admits assigned, in-progress, in-review and claimed `auto-dispatch` issues by design, leaving overlap to later dedup guards. On a 20-slot runner over 41h of `pulse.log`, those guards rejected 242 `dedup_active_claim*`, 108 `dedup_pr_evidence` and 236 draft-checkpoint candidates, each after 27-75s of per-candidate ceremony (`dedup.dedup_check` median 46s, 441 min/24h for 67 launches). `_dispatch_recheck_zero_worker_active_claims` (`.agents/scripts/pulse-dispatch-engine.sh:695`) re-opens active-claim rejections whenever the pool is empty, the usual state. Fresh candidates meanwhile waited: 121 unclaimed ready issues, mean concurrency about 0.6 of 20.

## How

- `.agents/scripts/pulse-dispatch-engine.sh`: add `_dispatch_order_claim_state_candidates` and call it in `_dispatch_order_round_candidates` (`:675`) between attempt-recency and `_dispatch_order_idle_borrowing_candidates`. Use a stable jq partition: unclaimed first, claimed after, original relative order kept in both. Log the demoted count once per round, and fail open: any jq error, or zero claimed candidates, returns the input byte-for-byte.
- `.agents/scripts/tests/test-pulse-dispatch-first-wave.sh`: one fixture where assigned or in-review candidates move behind unclaimed ones while keeping relative order, plus an assertion that an all-unclaimed round is unchanged (the existing `:661-662` byte-identity assertions must stay green).

## Acceptance

- In a mixed round, unclaimed candidates come first in their original relative order, followed by claimed candidates in theirs.
- No-claimed rounds and jq failures return the input unchanged.
- `test-pulse-dispatch-first-wave.sh` and the pulse-merge/dispatch suites pass; ShellCheck is clean.
- Post-deploy signal: `dispatch-stages.tsv` `dedup.dedup_check` count per `dedup.ceremony_total` falls from about 6 toward 2 or fewer.

## Files Scope

- .agents/scripts/pulse-dispatch-engine.sh
- .agents/scripts/tests/test-pulse-dispatch-first-wave.sh
