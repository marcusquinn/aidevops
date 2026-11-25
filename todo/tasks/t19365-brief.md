## Origin

Interactive session, Pulse throughput mission (parent GH#40108). Follow-up to t19364 / PR #40312. Implemented by the filing session.

## What

Candidate admission stops paying about 1 s per check to recompute the observed ceremony reserve. The reserve is read only when a fixed cycle clock applies, and the read scans only the recent tail of `dispatch-stages.tsv`.

## Why

Measured on the macOS runner at 2026-11-25T07:50Z (load average 242 on 16 CPUs): `_dispatch_ceremony_reserve_seconds` took 0.93–1.02 s per call, because awk scans the whole 31 MB, 182,615-line `~/.aidevops/logs/dispatch-stages.tsv` to keep the last 200 `dedup.ceremony_total` samples. The file holds 1,827 samples, about 100 lines per sample.

The serial candidate loops call it twice per candidate (`_dispatch_graphql_budget_allows_next`, `_dispatch_cycle_budget_defers_candidate`) and once per round plan (`_dispatch_round_budget_plan`). A 108-candidate round therefore spends about 200 s serially on this lookup. Under the elastic lease (instance owner, and since t19364 the split-lock refill holder) every one of those results is thrown away, because `_pulse_cycle_remaining_seconds` returns 1 and the reserve is never compared.

## Tier

tier:simple. Reorder three lookups and add `tail -n` in one function.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-dispatch-lib-candidates.sh`
  - `_dispatch_ceremony_reserve_seconds` (around line 824): pipe `tail -n "${DISPATCH_CEREMONY_RESERVE_TAIL_LINES:-40000}"` into the existing awk. Validate the value as a positive integer.
  - `_dispatch_cycle_budget_defers_candidate` (around line 712): read the floor only after `_pulse_cycle_remaining_seconds` returns a number.
  - `_dispatch_round_budget_plan` (around line 895): read the floor only after the lease and opt-out checks and a numeric remainder.
  - `_dispatch_graphql_budget_allows_next` (around line 1068): read the floor and margin only inside the branch where `_pulse_cycle_remaining_seconds` succeeds.

### Hazards and Compatibility

- Output is unchanged when the tail holds at least 200 samples: about 40,000 lines covers about 400 samples at current density. With fewer samples it uses the p90 of what it has; with none it keeps the 600 s cold start.
- Bounded mode keeps the same comparisons and log lines.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-lib-candidates.sh
bash .agents/scripts/tests/test-dispatch-max-parallel.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash .agents/scripts/tests/test-pulse-dispatch-first-wave.sh
```

Also time the function against the live log, before and after.

### Files Scope

- `.agents/scripts/pulse-dispatch-lib-candidates.sh`

## Acceptance Criteria

- [ ] `_dispatch_ceremony_reserve_seconds` returns the same value against the live log and takes at least 2x less time.
- [ ] Under an active elastic lease, admission and stage-start checks do not call `_dispatch_ceremony_reserve_seconds`.
- [ ] Existing ceremony-reserve, budget-plan and cycle-floor tests pass unchanged.

## Relevant Files

- `.agents/scripts/pulse-dispatch-lib-candidates.sh:712-723,824-836,895-924,1068-1082`
- `.agents/scripts/pulse-dispatch-lib.sh:1432,1913` — serial callers of `_dispatch_graphql_budget_allows_next`.
- `.agents/scripts/tests/test-dispatch-max-parallel.sh:1952-2040` — observed-reserve and budget-plan tests.
