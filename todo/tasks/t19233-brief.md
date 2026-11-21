## What

The GitHub App read-routing advisory (GH#38273) never fires on the governor-paced installs it exists for. Make it fire when REST-core is saturated, not only when it is exhausted, and refresh it from every Pulse cycle, not only after a progress-stage deferral.

## Why

On one install over 24h, `aidevops github auth advise --since 24h` reported `routable_share: 0.878` (95,687 of 109,022 known quota points could move to an App installation budget), `rest_core_min_remaining: 515`, `owners_without_app_read` covering 5 owners, and `advisory_due: false`. Pulse ran 10-14 of 20 worker slots while 100+ issues were runnable; launch ceremony p50 was 274 s, about 30 serial REST calls under pacing.

Two defects keep the advisory off:

1. `advisory_due()` in `.agents/scripts/github_auth_usage.py` requires `min_remaining == 0` or `< AIDEVOPS_PULSE_REST_CORE_BUDGET_HARD_FLOOR`. That floor defaults to `0` (`_cb_rest_core_bounds`, `.agents/scripts/pulse-rate-limit-circuit-breaker.sh`), so only exhaustion qualifies. The transport governor paces requests to avoid exhaustion, so consumption pins near `limit - reserve` (4,543 of 5,000 points per hour here) and the signal never appears.
2. `_pulse_github_app_advise_maybe()` in `.agents/scripts/pulse-budget-priority.sh` runs only after a progress-stage deferral. Pacing makes those rare (5 in the retained `pulse.log`, all with REST mode `unknown`).

## How

- `github_auth_usage.py`: read the authoritative REST-core `limit` offline from the Pulse cache (`AIDEVOPS_PULSE_REST_CORE_CACHE`, default `~/.aidevops/cache/pulse-rest-core.json`; same path as `_CB_REST_CORE_CACHE_FILE`). Compute logged REST-core known cost per hour (`by_api_pool["rest-core"]`, not the all-pool total, which includes GraphQL and search) from the report window. Report `rest_core_limit`, `rest_core_cost_per_hour` and `rest_core_saturation`. Treat saturation of at least 0.75 as due, alongside the existing exhaustion and floor tests. Logged cost is a lower bound: in the sampled hour it was 3,796 points, while per-credential `remaining_drop` totalled about 5,100. If the limit is missing, keep today's behaviour.
- `pulse-budget-priority.sh`: call `_pulse_github_app_advise_maybe` from the cycle-start (non-quiet) `_pulse_set_rest_core_budget_priority`. The existing 6h stamp and background/fail-open contract still bound it.
- `.agents/reference/github-auth.md` "Local usage": document the saturation criterion and the cycle-start refresh.

## Files Scope

- `.agents/scripts/github_auth_usage.py`
- `.agents/scripts/pulse-budget-priority.sh`
- `.agents/reference/github-auth.md`

## Acceptance

- With the evidence above (share 0.878, 4,543 points/h, limit 5,000), `aidevops github auth advise --since 24h` reports `advisory_due: true` and the saturation fields.
- With no limit cache, the result equals the previous exhaustion/floor logic.
- After an App read binding covers every pulse owner, `owners_without_app_read` is empty and the advisory is removed (unchanged behaviour).
- `shellcheck .agents/scripts/pulse-budget-priority.sh` passes, and `bash .agents/scripts/tests/test-pulse-graphql-budget-priority.sh` and `python3 -m pytest .agents/scripts/tests/test_pulse_repo_auth.py` still pass.
