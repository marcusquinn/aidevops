## What

Bound the per-repository prefetch fan-out to `PULSE_PREFETCH_MAX_PARALLEL` concurrent shards (default 12) inside the existing deadline. Make state assembly skip a shard that was killed before writing, instead of dropping every later shard.

## Why

`prefetch_state` launched one background subshell per pulse-enabled repository at the same time (70 locally, 48 of them dormant). Each dormant repository runs two conditional reads in `pulse_repo_scan_allowed` (`pulse-repo-dormancy.sh:133-134`), so roughly 100+ GitHub requests were in flight together, alongside full sweeps and worker traffic.

Evidence from `pulse.log` and `gh-api-calls.log` (2026-11-13 to 2026-11-15):

- 832 of 866 `dormancy reason=woken_error` events (96%) fall inside `preflight_prefetch_and_scope` stage windows. Outside the fan-out, dormancy proofs succeed 2083 times against 34 errors (1.6%). Inside it the error rate is 58%.
- Every logged dormancy read failure is a 15s `_gh_with_timeout` read timeout, in bursts of 40-95 launched within 1-2s.
- Each `woken_error` deletes the dormant state and persists a wake marker. The repository then gets full scans until it re-enters dormancy (994 `entered` events), cancelling dormancy's API savings and adding load in the same window.
- The fan-out hit its 120s cap (`Parallel gh fetch timeout after ~120s`) in 15 runs. `preflight_prefetch_and_scope` failed with rc 124 in 13 of 17 runs, publishing an INCOMPLETE primary repo fetch.

A second defect made those timeouts worse. Shards write their output only when they finish, and `_assemble_state_file` stopped at the first missing numbered file. One killed shard therefore hid every later repository from the published state.

## How

1. `.agents/scripts/pulse-prefetch-orchestration.sh`:
   - add `_prefetch_wait_for_slot` and `_prefetch_fanout` next to `_wait_parallel_pids`;
   - each launch waits for a free slot (`kill -0` polling), all inside one deadline;
   - at the deadline, launching stops, rc is 124 and the remaining wait time is passed to `_wait_parallel_pids`;
   - one `Prefetch fan-out: launched total max_parallel elapsed rc` line is logged per run;
   - `_assemble_state_file` takes an optional shard count and skips missing shards.
2. `.agents/scripts/pulse-prefetch.sh`: `prefetch_state` calls `_prefetch_fanout`, then assembles with `PREFETCH_FANOUT_LAUNCHED`.
3. Dormancy semantics are unchanged; errors still fail open.

### Files Scope

- .agents/scripts/pulse-prefetch.sh
- .agents/scripts/pulse-prefetch-orchestration.sh
- .agents/scripts/tests/test-pulse-prefetch-stage-budget.sh
- TODO.md
- todo/tasks/t19041-brief.md

## Acceptance

- No more than `PULSE_PREFETCH_MAX_PARALLEL` concurrent `_prefetch_single_repo` subshells.
- The fan-out stays bounded by the same deadline; a deadline stop still reports 124 and INCOMPLETE.
- A shard killed before writing does not hide later shards.
- Existing prefetch-budget, dormancy, characterization and stage-wiring tests pass; ShellCheck clean.

## Verification

- `bash .agents/scripts/tests/test-pulse-prefetch-stage-budget.sh`. The new case checks a cap of 3 with one killed shard: at most 3 running and 23 of 24 shards assembled.
- `test-pulse-repo-dormancy.sh`, `test-pulse-wrapper-characterization.sh`, `test-pulse-dispatch-engine-stage-wiring.sh`.
- After release, over 24h of `pulse.log`:
  - `reason=woken_error` inside prefetch windows falls toward the outside baseline;
  - `Parallel gh fetch timeout` becomes rare;
  - `preflight_prefetch_and_scope` mostly completes with rc 0;
  - the `Prefetch fan-out:` lines show elapsed time well below the deadline.
- If `launched < total` appears regularly, the default cap is too low for this repository count; raise it rather than restoring the unbounded fan-out.
