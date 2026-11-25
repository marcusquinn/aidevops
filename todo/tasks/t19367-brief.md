## Origin

Interactive session, Pulse throughput mission (parent GH#40108). Filed for worker implementation.

## What

The fixed 300 s prelaunch budget (`AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS`, set in `_dlw_begin_prelaunch`) adapts to observed prelaunch stage durations. Claimed candidates with a precreated worktree then reach spawn under host load, instead of aborting at the publication reserve after 7–8 minutes of ceremony.

## Why

Evidence from the macOS runner, `~/.aidevops/logs/dispatch-stages.tsv` and `pulse.log`, 2026-11-23 to 2026-11-25:

- `pre_runtime_failure:prelaunch_reserve_insufficient` and `:prelaunch_budget_exhausted` occurred 6, 5 and 11 times on those three days. On 2026-11-25 that was 11 aborts against 95 spawns, about 10% of attempts that reached prelaunch.
- Each abort comes after the claim was won and the worktree was created. For example, two candidates in a managed product repository returned rc=2 after 497 s and 507 s. In both, the claim comment was deleted and the worktree discarded, so the next attempt repeats all of it.
- At load average 242 on 16 CPUs (desktop apps plus workers), stages after `begin_prelaunch` took: `precreate_worktree` 139 s (`git worktree add` 79 s), `final_ownership_fence` 47 s, `assign_and_label` 62 s. The publication check then needs 75 s more. This load is outside Pulse's control, so a fixed 300 s fails exactly when ceremony is already slowest.

## Tier

tier:standard. A bounded adaptive default in one function and a regression case in the existing test.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-dispatch-worker-launch.sh` — `_dlw_begin_prelaunch` (around line 809). When `AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS` is unset, use `max(300, ceil(p90 × 1.25))`, capped at `AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_MAX_SECONDS` (default 600). p90 is taken over recent successful prelaunch durations: the sum of `dedup.precreate_worktree`, `dedup.final_spawn_gates`, `dedup.final_ownership_fence`, `dedup.assign_and_label` and `dedup.worker_spawn` per launch. Alternatively, the `dedup.worker_launch_total` p90 minus its pre-`begin_prelaunch` stages; pick the simpler one that is correct and say which in the PR.
  - Read only the log tail (the pattern in `_dispatch_ceremony_reserve_seconds` in `.agents/scripts/pulse-dispatch-lib-candidates.sh`, t19365: `tail -n 40000 | awk`).
  - An explicit env value keeps today's exact behaviour.
- EDIT: `.agents/scripts/tests/test-prelaunch-publication-reserve.sh` — add a case: a stages fixture with slow prelaunch samples raises the budget (capped); no samples keeps 300; an explicit env value wins.

### Hazards and Compatibility

- The deadline must never slide once set (the existing invariant in the `_dlw_begin_prelaunch` comment). Only its initial size changes.
- `_dlw_renew_prelaunch_lease` derives the lease TTL from the remaining budget, so a larger budget lengthens the prelaunch claim lease. That only affects takeover delay if the dispatcher dies. Keep the 600 s cap; check that `dispatch-claim-helper.sh transition prelaunch` accepts the longer TTL.
- The per-candidate watchdog (600 s, or adaptive `timeout_used_ms`) still bounds the whole candidate. If the budget can exceed `watchdog − pre-prelaunch elapsed`, clamp it there so the watchdog does not kill a spawn in progress. Verify against `_dispatch_with_timeout` in `.agents/scripts/pulse-dispatch-lib-candidates.sh`.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-worker-launch.sh .agents/scripts/tests/test-prelaunch-publication-reserve.sh
bash .agents/scripts/tests/test-prelaunch-publication-reserve.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
```

### Files Scope

- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/tests/test-prelaunch-publication-reserve.sh`

## Acceptance Criteria

- [ ] With no env override and slow observed prelaunch samples, the budget rises above 300 s and never exceeds the cap or the remaining per-candidate watchdog.
- [ ] With no samples, or an explicit `AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS`, behaviour is unchanged.
- [ ] Existing prelaunch publication-reserve cases pass.
- [ ] Runtime, after deploy: daily `pre_runtime_failure:prelaunch_*` count in `dispatch-stages.tsv` drops below 3 per 100 spawns.

## Relevant Files

- `.agents/scripts/pulse-dispatch-worker-launch.sh:809-823,859-881,1709-1744`
- `.agents/scripts/pulse-dispatch-worker-gates.sh:798-816` — `_dlw_prelaunch_budget_available`.
- `.agents/scripts/pulse-dispatch-lib-candidates.sh:824-840` — tail-scan p90 pattern.
- `.agents/scripts/tests/test-prelaunch-publication-reserve.sh`
