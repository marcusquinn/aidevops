<!-- aidevops:brief-schema=v2 -->

# t18538: Pulse: auto-refresh and alert when capacity is zero only from auth-error accounts

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Follow-up to #32927 / PR #32932 (shipped in v3.37.26). The maintainer asked to capture the zero-capacity alert, and also to have the pulse try refreshing the token itself when it can.

## What

When the selected provider's pulse dispatch capacity is zero only because every account is `auth-error`, the pulse should:

1. Immediately attempt a bounded, throttled OAuth refresh for that provider, instead of waiting for the 30-minute r911 routine.
2. If capacity is still zero from `auth-error` after N consecutive cycles (default 3), record a durable health signal in `pulse-health.json` that names the provider and the manual remedy `oauth-pool-helper.sh reset-cooldowns <provider>`. Clear the signal on recovery.

## Why

PR #32932 made `auth-error` accounts refresh-eligible once their cooldown expires (`.agents/scripts/oauth-pool-lib/pool_ops_refresh.py:61-78`). Recovery still depends on the r911 cron (`.agents/scripts/routines/core-routines.sh:29`, `*/30`), so capacity can sit at 0 for up to 30 minutes. The only visibility today is `auth_error_accounts=N` inside the `Dispatch_capacity` log line (`.agents/scripts/pulse-capacity.sh:247`). In #32927, capacity was 0 for about 3 days before anyone noticed. Accounts without a refresh token can never self-heal and need an operator, so they need an alert.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: shell changes in 2 files plus a jq report tweak, reusing existing helpers. Not `tier:simple`, because it requires a helper extraction and bounded network I/O inside the dispatch cycle.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-capacity.sh:164-251` — extract helpers from `pulse_apply_provider_load_capacity_cap`, then add the auth-error-only refresh trigger and consecutive-cycle counter.
- `EDIT: .agents/scripts/pulse-logging.sh:637-758` — add an optional `auth_error_capacity_zero` object to the `pulse-health.json` snapshot.
- `EDIT: .agents/scripts/pulse-check-report.jq` — surface the new health field in the pulse-check report when present.

### Complete Write Surface

- **Callers/readers:** `pulse_apply_provider_load_capacity_cap` is called from `.agents/scripts/pulse-dispatch-engine.sh:1245` and `.agents/scripts/pulse-dispatch-lib.sh:288`; both parse only `"<final_max> <floor_active>"` from stdout, so that output contract must not change. `pulse-health.json` is read by `.agents/scripts/pulse-check-helper.sh:28` and `.agents/scripts/pulse-check-report.jq`; `git grep -l pulse-health -- .agents/scripts` also lists `.agents/scripts/pulse-current-state.py` and `.agents/scripts/pulse-watchdog.sh`, which must tolerate a new optional key.
- **Writers/mutation paths:** `.agents/scripts/pulse-capacity.sh` writes new per-provider throttle and counter stamp files under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/pulse-auth-error-recovery/`. The pool file `~/.aidevops/oauth-pool.json` changes only indirectly, through the existing locked `oauth-pool-helper.sh refresh <provider>` path (`cmd_refresh` in `.agents/scripts/oauth-pool-manage.sh:451`, which calls `pool_ops.py refresh`). `.agents/scripts/pulse-logging.sh` writes `pulse-health.json`.
- **Existing verification/tests:** `.agents/scripts/tests/test-dispatch-min-concurrency.sh` stubs `pulse_apply_provider_load_capacity_cap` (L332, L493, L582); `.agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh` covers pool gating; `.agents/scripts/oauth-pool-lib/tests/test_pool_ops.py` covers refresh eligibility; the production log is the `Dispatch_capacity:` line in the pulse `LOGFILE`.
- **Schemas/config:** `pulse-health.json` has no schema file; its fields are composed ad hoc in `pulse-logging.sh`. New tunables use env vars (`PULSE_AUTH_ERROR_REFRESH_THROTTLE_SECONDS`, default 300; `PULSE_AUTH_ERROR_ALERT_CYCLES`, default 3), matching the `PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER` pattern at pulse-capacity.sh:188.
- **Generated/deployed mirrors:** the deployed copy under `~/.aidevops/agents/scripts/` is refreshed by `setup.sh` and release deploy. There are no generated files (checked: no build step for these scripts).
- **Migrations/backfills:** N/A because no persistent schema or stored data changes: the stamp files are created lazily by `.agents/scripts/pulse-capacity.sh`, a missing stamp means "never attempted", and `pulse-health.json` is fully regenerated each cycle by `.agents/scripts/pulse-logging.sh`, so no backfill is needed.
- **Cleanup/rollback paths:** revert the PR. The stamp files are disposable tmp state, and the old code ignores them. The `pulse-health.json` field is regenerated every cycle, so after a revert it disappears on the next write.

### Implementation Steps

1. Extract helpers first to stay under the 100-line function gate (see Complexity Impact):
   - Move the account-multiplier resolution (pulse-capacity.sh:188-196) into `_pulse_capacity_account_multiplier`, which prints `"<multiplier> <source>"`.
   - Move the gauge emission (L239-244) into `_pulse_capacity_emit_gauges`.
2. Add `_pulse_capacity_auth_error_recovery <provider> <total> <available> <auth_errors>`:
   - It runs only when `total>0 && available==0 && auth_errors==total`.
   - It checks the per-provider throttle stamp, writes the stamp before invoking so concurrent cycles don't both fire, and then runs `oauth-pool-helper.sh refresh "$provider"` under a timeout (for example `timeout_sec 20` if available in shared-constants, otherwise the existing pattern in pulse scripts). Stdout and stderr go to LOGFILE.
   - Return 0 if a refresh ran, so the caller re-reads `_pulse_capacity_provider_account_counts`.
3. Call it in `pulse_apply_provider_load_capacity_cap` right after the counts are read (L174-178). Re-read the counts only when it returns 0.
4. Track consecutive auth-error-only cycles:
   - Keep a per-provider counter stamp. Increment it when the step 2 condition still holds after recovery; reset it (delete the stamp) otherwise.
   - Export `_PULSE_HEALTH_AUTH_ERROR_PROVIDER` and `_PULSE_HEALTH_AUTH_ERROR_CYCLES`, following the existing `_PULSE_HEALTH_*` globals consumed in pulse-logging.sh:758.
   - Add `auth_error_only_cycles=%s` to the `Dispatch_capacity` log line.
5. In pulse-logging.sh, when cycles >= `PULSE_AUTH_ERROR_ALERT_CYCLES`, include `"auth_error_capacity_zero":{"provider":..,"cycles":..,"remedy":"oauth-pool-helper.sh reset-cooldowns <provider>"}`. Omit the key otherwise.
6. In pulse-check-report.jq, render that key as a warning line when present.
7. Run shellcheck on both shell files, then exercise the runtime check in Verification.

```bash
# Skeleton for step 2 (pulse-capacity.sh)
_pulse_capacity_auth_error_recovery() {
	local provider="$1" total="$2" available="$3" auth_errors="$4"
	[[ -n "$provider" ]] || return 1
	((total > 0 && available == 0 && auth_errors == total)) || return 1
	local state_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/pulse-auth-error-recovery"
	local stamp="${state_dir}/${provider}.last-refresh"
	local throttle="${PULSE_AUTH_ERROR_REFRESH_THROTTLE_SECONDS:-300}"
	# read epoch from stamp; return 1 if now - last < throttle
	# mkdir -p state_dir; write now to stamp BEFORE invoking (claim)
	# run oauth-pool-helper.sh refresh "$provider" with a bounded timeout, output >> LOGFILE
	return 0
}
```

### Hazards and Compatibility

- **Concurrency/atomicity:** `cmd_refresh` already holds the pool `.lock` (pool_ops_refresh.py `acquire_lock`), so it is serialized with the r911 cron and with worker `mark-failure`. The throttle stamp is written before the invocation, so overlapping pulse cycles or multiple runners on one host skip rather than double-fire. Worst-case race: two refreshes a few seconds apart. The second is a no-op because the account is `active` or in cooldown.
- **Migration/rollback:** there is no persistent schema. Rollback is a plain revert; stale stamp files are ignored by old code and can be deleted safely.
- **Mixed-version/backward compatibility:** the `pulse_apply_provider_load_capacity_cap` stdout contract (`"<final_max> <floor_active>"`) is preserved for both callers. The new `pulse-health.json` key is optional, and existing jq readers use `//` defaults or ignore unknown keys. The `Dispatch_capacity` log line only gains a trailing field.
- **Idempotency/retry:** a failed refresh re-applies exponential backoff via `_mark_refresh_failure` (pool_ops_refresh.py:96). While the cooldown is active, `_should_refresh_account` returns False, so repeated triggers are no-ops. The throttle caps attempts at one per provider per 300s.
- **Partial failure/recovery:** if the refresh times out or errors, capacity stays at 0 as today and the dispatch cycle continues; the refresh error is logged, not fatal. A successful refresh rotates the refresh token exactly as r911 does, and `_self_heal_auth_file` only rewrites `auth.json` when the active credential is missing or expired. If stamp writes fail, the step treats the throttle as unknown and skips the refresh; failing closed avoids hammering the endpoint. An interrupted refresh leaves the pool file intact because `pool_ops_refresh.cmd_refresh` writes it atomically via `atomic_write_json` under the lock.

### Complexity Impact

- **Target function:** `pulse_apply_provider_load_capacity_cap` in `.agents/scripts/pulse-capacity.sh`
- **Current line count:** 88 lines (L164-251; threshold: 100 lines for function-complexity)
- **Estimated growth:** +8 lines (call, re-read, counter, log field)
- **Projected post-change:** 96 lines without extraction (96% of threshold)
- **Action required:** Extract helpers first. `_pulse_capacity_account_multiplier` (~10 lines from L188-196) and `_pulse_capacity_emit_gauges` (~7 lines from L239-244) bring it to about 80 lines after the change.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-capacity.sh .agents/scripts/pulse-logging.sh
bash .agents/scripts/tests/test-dispatch-min-concurrency.sh
bash .agents/scripts/tests/test-headless-runtime-oauth-pool-gate.sh
python3 -m unittest discover -s .agents/scripts/oauth-pool-lib/tests -p test_pool_ops.py
# Runtime: temp pool only, never live credentials. Point PULSE_DISPATCH_OAUTH_POOL_FILE and
# the oauth-pool helper pool path at a temp copy whose accounts are all auth-error with
# cooldownUntil=0; stub the token endpoint (or leave it unreachable). Then source
# pulse-capacity.sh and call pulse_apply_provider_load_capacity_cap 6 0 6 three times.
```

- **Surface mapping:** `shellcheck` covers `.agents/scripts/pulse-capacity.sh` and `.agents/scripts/pulse-logging.sh`, including the helper extraction. `test-dispatch-min-concurrency.sh` proves the callers in `pulse-dispatch-engine.sh` and `pulse-dispatch-lib.sh` still parse the unchanged stdout contract (mixed-version hazard). The oauth-pool gate test and `test_pool_ops.py` prove refresh eligibility and backoff are unchanged (idempotency hazard). The runtime temp-pool check proves acceptance criteria 1-4: one refresh per throttle window, the counter reaching the alert threshold, the `pulse-health.json` key with remedy text, and clearing on recovery (partial-failure and concurrency hazards).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** do not modify `.agents/scripts/oauth-pool-lib/pool_ops_auto_clear.py`, and never set `auth-error` accounts to `idle` or `active` without a successful token refresh. Do not change `_should_refresh_account` semantics from PR #32932.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-capacity.sh`
- `.agents/scripts/pulse-logging.sh`
- `.agents/scripts/pulse-check-report.jq`

## Acceptance Criteria

- [ ] With an all-`auth-error` provider pool whose cooldowns have expired and whose refresh succeeds, a single `pulse_apply_provider_load_capacity_cap` call triggers `oauth-pool-helper.sh refresh <provider>`. The same cycle's `Dispatch_capacity` line then reports `provider_accounts_available>=1`, without waiting for r911.

  ```yaml
  verify:
    method: codebase
    pattern: "_pulse_capacity_auth_error_recovery"
    path: ".agents/scripts/pulse-capacity.sh"
  ```

- [ ] After `PULSE_AUTH_ERROR_ALERT_CYCLES` (default 3) consecutive cycles with zero capacity only from `auth-error`, `pulse-health.json` contains `auth_error_capacity_zero` with the provider and the text `oauth-pool-helper.sh reset-cooldowns`. The key is absent once capacity recovers.

  ```yaml
  verify:
    method: codebase
    pattern: "auth_error_capacity_zero"
    path: ".agents/scripts/pulse-logging.sh"
  ```

- [ ] Negative/regression: at most one refresh attempt per provider per throttle window. No refresh is triggered when any account is available or when only rate-limited accounts cause zero capacity. The stdout contract `"<final_max> <floor_active>"` is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-min-concurrency.sh"
  ```

- [ ] Negative/regression: no code path sets `auth-error` accounts to `idle` without a successful refresh; `pool_ops_auto_clear.py` is untouched.

  ```yaml
  verify:
    method: codebase
    pattern: "status.*=.*idle"
    path: ".agents/scripts/pulse-capacity.sh"
    expect: absent
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/pulse-capacity.sh .agents/scripts/pulse-logging.sh`

## Context & Decisions

- The refresh is triggered from pulse-capacity instead of shortening the r911 cron. A shorter cron would add token-endpoint traffic for every healthy account; the pulse trigger fires only in the failure state.
- The pulse never probes by dispatching a canary worker. A real token refresh is a cheaper, more authoritative check, and it matches the recovery path chosen in #32932.
- Accounts without refresh tokens are out of scope for auto-recovery; the health signal is their remedy path.

## Relevant Files

- `.agents/scripts/pulse-capacity.sh:81-121` — `_pulse_capacity_provider_account_counts`
- `.agents/scripts/oauth-pool-manage.sh:451` — `cmd_refresh`
- `.agents/scripts/oauth-pool-lib/pool_ops_refresh.py:61-104` — eligibility and backoff
- `.agents/scripts/pulse-logging.sh:637-758` — `pulse-health.json` writer
