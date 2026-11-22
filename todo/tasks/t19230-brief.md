## What

Local REST primary pacing charges a full schedule slot for every admitted GET, including conditional revalidations that GitHub answers with `304 Not Modified` at zero primary-quota cost. Refund the pacing slot when a completed response is free, so free revalidations stop pushing paid and latency-sensitive reads (merge gates, check snapshots, app-token reads) past their read timeouts.

## Why

Evidence from `~/.aidevops/logs/gh-api-calls.log`, trailing hour, 2026-11-21 ~02:20 UTC, single host:

- 8,452 REST core attempts. 3,576 (42.3%) were `304`; the log's cost column records `0` for 3,772 attempts and `1` for 4,522. Paid spend was about 4,876 points/h, close to the 5,000/h window, so pacing correctly engages.
- 68 transport timeouts in the same hour: `github-app-auth-helper.sh` 23, `shared-gh-wrappers-checks.sh` 14, `pulse-merge-required-checks.sh` 14 (the pre-merge check snapshot, so Pulse merges of finished worker PRs defer), `shared-gh-wrappers.sh` 7, `pulse-merge-rest-state.sh` 4.
- `gh_transport_capacity.primary_wait` spaces admissions at `interval = (reset - now) / available` and advances `pacing.retry_at` by one interval for every admission. `gh_transport_budget.Budget.finish` updates `quota` and `reservation` but never touches `pacing`, so a 304 permanently consumes a slot. At a 42% free share, the schedule admits about 42% fewer paid-equivalent requests than the remaining balance allows early in each window, and queued reads wait longer than necessary.
- Concrete impact: a merge-time check-run snapshot page took 9,039 ms for a 304 under pacing versus 0.5–0.9 s unpaced (see GH#39590).

## How

- `.agents/scripts/gh-transport-governor.py` `run()` already parses `status` from `included_headers(output)`. Pass it to `_finish_budget(...)` and on to `Budget.finish(...)` as a keyword argument (for example `free=status == 304`), defaulting to "not free" so other callers are unchanged.
- `.agents/scripts/gh_transport_budget.py` `Budget.finish`: when the response is free and observed headers are valid, call a new helper in `gh_transport_capacity.py` inside the same transaction. The helper moves `pacing.retry_at` back by one current interval (`(reset - now) / max(available, 1)`) for the same scope/resource and window (`pacing.reset == quota.reset`), clamped to `now`. Never move it before `now`, never create a pacing row, never touch secondary-ceiling accounting (`admission_history`) or reservations.
- Keep fail-closed behaviour: invalid or missing headers mean no refund. Cooldowns, exhaustion, concurrency and the 900 points/min secondary ceiling are unchanged.
- Read GH#37570 (delivery class) and the GH#38566 conditional-cache notes in `gh-transport-governor.py` before editing. The refund must not let delivery-class reads, or 304 bursts, exceed the secondary ceilings, which `capacity_wait` enforces separately.

## Files Scope

- `.agents/scripts/gh-transport-governor.py`
- `.agents/scripts/gh_transport_budget.py`
- `.agents/scripts/gh_transport_capacity.py`
- `.agents/scripts/tests/test-gh-transport-budget.py`

## Acceptance

- A 304 response on an eligible GET returns its pacing slot: after admission plus a free finish, the next admission's `retry_at` equals the value before the free admission (within float tolerance), clamped to `now`.
- A paid (200) response, an error, or a response without valid rate-limit headers leaves pacing exactly as today.
- Secondary-ceiling counts, reservations, cooldowns and exhaustion handling are unchanged.
- `python3 .agents/scripts/tests/test-gh-transport-budget.py` passes.

## Verification

- `python3 .agents/scripts/tests/test-gh-transport-budget.py`
- Runtime, after deploy: rerun the trailing-hour timeout breakdown from `gh-api-calls.log` (rows with kind `timeout`, grouped by caller) at comparable load, and compare against the 68/h baseline above. Expect `pulse-merge-required-checks.sh` and `shared-gh-wrappers-checks.sh` timeouts to fall.
