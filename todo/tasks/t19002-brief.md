<!-- aidevops:brief-schema=v2 -->

## What

Simplify the pulse dispatch path so a worker launch costs about what an interactive `/full-loop` start costs (claim + worktree + start, about 20s), and free worker slots refill within minutes, not at the end of a 26-45 minute maintenance cycle. This plan has measurable phases. Each child is a separate issue.

## Why (evidence, one runner, 2026-11-07..14)

Throughput, managed repos, last 7 days (GitHub search `issueCount`):

| Lane | Merged PRs / 7d | Median issue→merge | Median PR open→merge |
|---|---|---|---|
| Interactive sessions (`origin:interactive`, maintainer-authored) | 806 (≈115/day) | 0.8h | 15 min |
| This runner's workers (`origin:worker`, maintainer-authored) | 240 (≈34/day) | 3.1h | 24 min |

The worker lane's extra ~2.3h happens before a PR exists. The runner is not capacity-bound:

- `max_concurrent_workers=20`; worker metrics show 450 runs and 106 worker-hours in 168h, so **mean concurrency ≈0.6 of 20**. `pulse-health.json` at 19:42Z showed 0/20 active, last dispatch progress 18:11Z.
- The ready queue is not empty. 121 open `auto-dispatch` issues are unassigned, not blocked, unheld and non-parent. The oldest dates from 2026-06-10.
- Cycles take 26-45 min (`pulse-cycle-index.jsonl`) and dispatch 0-6 workers each. In one 44-minute window, maintenance stages took about 3,870 stage-seconds (`pulse-stage-timings.log`). The largest were post_dispatch_housekeeping 636s, dashboard_freshness_check 499s, preflight_label_maintenance 488s, preflight_ownership_reconcile 328s and normalize_active_issue_assignments 261s. preflight_early_dispatch ran in 0s and dispatched nothing.
- Per-launch dispatcher ceremony (`dispatch-stages.tsv`, 24h, 67 launches) took median 295s, p90 532s. In the same window, 408 `dedup.dedup_check` runs (median 46s) consumed 441 minutes, about 6.6 min of rejected-candidate checking per successful launch. claim_lock median was 56s and precreate_worktree median 43s.
- Rejections are knowable cheaply from the candidate snapshot. Over 41h of `pulse.log`: dedup_active_claim* 242, draft-checkpoint blocked/stale 236, dedup_pr_evidence 108, runner_capability_unmet 45, terminal_blocker_circuit 34. `_filter_dispatchable_issue_candidates_json` (`.agents/scripts/pulse-repo-meta.sh:575`) admits assigned, `status:in-progress`, `status:in-review` and `status:claimed` issues by design (comment at `:641-654`). `_dispatch_recheck_zero_worker_active_claims` (`.agents/scripts/pulse-dispatch-engine.sh:695`) re-opens active-claim rejections whenever the pool is empty, which is this runner's normal state.
- Two cycles in the window were blocked on `rest-core-quota`, with zero dispatch, while maintenance continued to draw on the same REST budget.
- About a dozen recent symptom-level perf fixes (#37874, #38022, #38033, #38055, #38210, #38226, #38237, #38261, #38274, #37811) did not move launches above about 2.8/hour.

## How (phases → child issues)

1. **Fresh-first candidate lane.** Rank unclaimed candidates first: no assignee and no `status:in-progress`/`status:in-review`/`status:claimed`. Recovery candidates (assigned, in-review or claimed) get a small per-round evaluation cap. Nothing becomes undispatchable; stale-claim recovery keeps a bounded share. Target: under 2 dedup checks per launch.
2. **Dispatch never waits on maintenance.** When at least half the slots are free, dispatch/refill runs before label maintenance, dashboard freshness, ownership reconcile and housekeeping, and again between them. Maintenance stages yield to a pending refill instead of holding the cycle.
3. **Interactive-equivalent launch ceremony.** Target median under 60s of dispatcher time per launch. Move worktree precreate and post-launch hooks onto the worker's own startup path, and launch candidates in parallel once claims are verified.
4. **REST budget priority.** Maintenance defers when REST-core falls below the dispatch reserve, so a `rest-core-quota` cycle still dispatches.

## Acceptance (measured on a 20-slot runner, 24h after deploy)

- Launches per day on this runner at least 3x the 67/day baseline, with no rise in duplicate PRs or duplicate claims (`dispatch-stages.tsv`, metrics jsonl).
- Mean worker concurrency at least 5 while the ready queue is non-empty.
- Median issue→merge for worker PRs at or below 1.5h (GitHub search, same method as above).

## Files Scope

- .agents/scripts/pulse-repo-meta.sh
- .agents/scripts/pulse-dispatch-engine.sh
- .agents/scripts/pulse-dispatch-lib-candidates.sh
- .agents/scripts/pulse-wrapper.sh
