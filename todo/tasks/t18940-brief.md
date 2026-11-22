## What

Make the pulse worker-bus relay log which gate stopped a GitHub read, so a "listing deferred or failed" line identifies its cause. `_relay_get` in `.agents/scripts/worker-bus-relay-helper.sh` returns 1 for six distinct reasons with no record of which one fired: stop flag, GraphQL rate-limit flag, tripped circuit breaker, REST-core deferrable gate, `gh api` non-zero/timeout, and non-JSON output.

## Why (evidence)

- After the pulse resumed dispatching (3 workers launched in one cycle), the relay logged `listing <repo> deferred or failed; workers keep their state` right after each dispatch, for 3 different repos. It has delivered 0 messages since it shipped (t18905/t18911), so maintainer steering never reaches running workers.
- None of the flag files existed at investigation time, and `pulse.log` has 0 `REST-core … unit blocked: context=worker-bus-relay` lines (the REST gate logs its blocks). An interactive reproduction that sources the helper and calls `_relay_get` against the same endpoint succeeds (`api_allowed_rc=0 gh_rc=0 relay_get_rc=0`). The failing gate is therefore pulse-environment specific and currently unobservable.
- The relay's detached stderr log (`~/.aidevops/logs/worker-bus-relay.log`) is empty, because `_relay_get` discards `gh` stderr.

## How

### Files to modify

- EDIT: `.agents/scripts/worker-bus-relay-helper.sh`
  - `_relay_api_allowed`: emit a short reason token (`stop-flag`, `rate-limit-flag`, `breaker`, `rest-gate`) to a caller-provided variable or stdout.
  - `_relay_get`: record `gh-rc=<n>` (124 = timeout) or `non-json`, plus the first stderr line truncated to 160 characters with tokens and paths stripped.
  - `_relay_repo`: include the reason in the existing log line, e.g. `listing <repo> deferred (rest-gate)` / `failed (gh-rc=1: <first line>)`.
  - Apply the same reason to the per-worker comment and timeline reads that use `_relay_get`.
- Keep behaviour identical otherwise: same gates, same order, same return codes.

### Reference pattern

- `pulse_rest_core_priority_allows_next` in `.agents/scripts/pulse-rate-limit-circuit-breaker.sh` (~561-591) logs `context=… mode=… remaining=…` on every block. Mirror its one-line style.

### Files Scope

- `.agents/scripts/worker-bus-relay-helper.sh`

## Acceptance criteria

- With a live worker and a forced failure (for example `PULSE_RATE_LIMIT_FLAG` pointing at an existing file, or a `gh` stub on PATH returning 1 with a stderr line), `pulse.log` shows the matching reason token in the relay line.
- No credentials, tokens or absolute local paths appear in the logged stderr excerpt.
- shellcheck clean; existing relay tests pass.

## Verification

- `shellcheck .agents/scripts/worker-bus-relay-helper.sh`
- Run the relay test file if present (`git ls-files '*worker-bus-relay*'`).
- After deploy, the next relay line in `~/.aidevops/logs/pulse.log` carries a reason; record the observed reason on the issue. If it is a real defect (for example a timeout or a missing PATH entry), fix it in the same PR when small, otherwise file a follow-up.
