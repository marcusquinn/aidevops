<!-- aidevops:brief-schema=v2 -->

## Origin

Interactive fleet-health review on 2026-10-31 (session objective: Pulse and workers continually resolve what they can; humans receive only needs they can act on). Maintainer decision recorded in that session: evidence-less blocked exits stay dispatchable.

## What

A `permission_required` terminal-blocker hold with no published, actionable permission request must not be a permanent human-gated hold. Re-arm it under a bounded, windowed backoff through the existing terminal-blocker recovery path. Keep the hold when a real request exists (`needs-maintainer-permissions` label or a `worker-permission-helper.sh` request marker without a later approval).

## Why

`permission_required` is a retry-only class (`_TBC_RETRY_ONLY_REARM_REASONS`, `.agents/scripts/terminal-blocker-circuit.sh:39`). Its first observation projects `status:blocked`, and only an OWNER/MEMBER `terminal-blocker-circuit:retry` line re-arms it (`terminal_blocker_observation_hold_active`, `:606-635`; recovery `_tbr_release_circuit_hold`, `.agents/scripts/terminal-blocker-recovery-helper.sh:717-799`).

The public release says only "Resolve the evidenced permission prerequisite". The evidence stays in the releasing runner's protected telemetry. Unless the worker also ran `worker-permission-helper.sh request` (which posts "Maintainer permission required" with a request ID and capability list, and adds `needs-maintainer-permissions`), the maintainer has nothing to approve.

GH#36033 showed that many of these releases are runner-local faults: one device released six different issues as `permission_required` within 15 minutes. That fix stops new storms. It does not release the backlog.

GraphQL search on 2026-10-31 for open `status:blocked` issues with a `reason=permission_required` release:

- 37 in one managed private organisation, of which only 3 have a visible permission request. Releases came from three runners, dated 2026-09-11 to 2026-10-30, six of them on the GH#36033 incident day.
- 2 in a second managed organisation.
- 4 in personal repositories, for example #35850 (released 11 minutes after dispatch on 2026-10-28, OpenCode 1.19.4, no request posted). #35592 is the counter-example: a real request `perm-f288b40c03806601` with `needs-maintainer-permissions`, which must stay held.

## Tier

`tier:thinking`: changes a trust-sensitive hold predicate (`#aidevops:trust-boundary`), shared by the dispatch gate and the recovery helper.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/terminal-blocker-circuit.sh`: add `terminal_blocker_permission_request_evidenced <comments_json> <issue_json>`. It returns 0 when the issue carries `needs-maintainer-permissions`, or an authoritative comment contains the `worker-permission-helper.sh` request marker (`PERMISSION_REQUEST_MARKER`) with no later approval/retry. In `terminal_blocker_observation_hold_active` (`:627-630`), keep holding `permission_required` only when it is evidenced, or when the newest observation is inside the backoff window. Otherwise return 1 (re-armed).
- `EDIT: .agents/scripts/terminal-blocker-recovery-helper.sh`: in `_tbr_release_circuit_hold` (`:770-785`), add decision `unevidenced_permission_window` for `permission_required` evidence that is not evidenced and older than the window. Project `status:available` through `_tbr_project_rearm` with the existing hidden receipt, binding the observation id and window index in the receipt key so each window releases at most once. Also confirm `_tbr_circuit_blocks_release` (`:655-672`) does not re-hold it.
- `EDIT: .agents/scripts/tests/test-terminal-blocker-circuit.sh` (it also covers `_tbr_release_circuit_hold`): add the cases in Acceptance Criteria.
- `EDIT: .agents/reference/worker-diagnostics.md`: add one short paragraph next to the zero-attempt backoff contract.

### Complete Write Surface

- **Callers/readers:** dispatch reads hold state through `terminal_blocker_circuit_active` / `terminal_blocker_observation_hold_active` (callers: `rg -n "terminal_blocker_observation_hold_active|terminal_blocker_circuit_active" .agents/scripts --glob '!tests/**'`). The recovery helper intake seeds from `label:"status:blocked" "Terminal blocker" in:comments` (`terminal-blocker-recovery-helper.sh:306-311`, `:419`).
- **Writers/mutation paths:** the only new write is the existing `set_issue_status available` plus the hidden `aidevops:terminal-blocker-rearmed` receipt in `_tbr_project_rearm` (`:802-827`). No new visible comments, which avoids comment storms.
- **Existing verification/tests:** `test-terminal-blocker-circuit.sh` (circuit and recovery helper), `test-permission-block-breaker.sh` (GH#36033 runner breaker must stay effective).
- **Schemas/config:** the window constant mirrors `ZERO_OUTPUT_HOLD_WINDOW_SECONDS=43200` (12h) from the zero-attempt backoff (GH#36214). Reuse or co-locate it; do not add a user config key unless needed.
- **Generated/deployed mirrors:** deployed by `setup.sh` on the normal update path.
- **Migrations/backfills:** none. Existing holds are picked up by recovery intake on the next pass.
- **Cleanup/rollback paths:** revert the predicate. Posted receipts are inert hidden markers.

### Hazards and Compatibility

- **Trust boundary:** re-arming schedules a new attempt only; it never grants a permission. A worker that hits a real guard again must go through `worker-permission-helper.sh request`, which publishes an actionable request and is then held as evidenced. Mark new predicates `#aidevops:trust-boundary`.
- **Storm safety:** the GH#36033 runner-local breaker plus the window bound attempts to about 2 per issue per day. Never re-arm while `needs-maintainer-permissions`, `hold-for-review`, `no-auto-dispatch`, `parent-task` or another hold label is present (existing guard in `_tbr_release_circuit_hold:724-730`).
- **Mixed versions:** older runners keep holding; newer runners release once per window via the receipt key.
- **Idempotency:** the receipt key includes observation id + window index.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-terminal-blocker-circuit.sh
bash .agents/scripts/tests/test-permission-block-breaker.sh
shellcheck .agents/scripts/terminal-blocker-circuit.sh .agents/scripts/terminal-blocker-recovery-helper.sh
```

- **Surface mapping:** the circuit suite covers the predicate, projection and receipt idempotency; the breaker suite covers storm safety.
- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/terminal-blocker-recovery-helper.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `.agents/reference/worker-diagnostics.md`

## Acceptance Criteria

- [ ] Positive: a `permission_required` first observation older than the window, with no `needs-maintainer-permissions` label and no request marker, is not an active hold; the recovery pass projects `status:available` once and posts only the hidden receipt; a second pass in the same window writes nothing.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-terminal-blocker-circuit.sh"
  ```

- [ ] Negative: the same observation inside the window, or with `needs-maintainer-permissions`, or with a request marker and no later approval, stays held. Existing push/network policy-timeout retry-only behaviour is unchanged.
- [ ] Regression: GH#36033 runner breaker tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-permission-block-breaker.sh"
  ```

## Context & Decisions

- Producer-side improvement (worker releases publish a redacted capability summary) is out of scope here. If found cheap, file it as a follow-up.
- Related: GH#36033 (runner breaker), GH#35925 (trusted retry releases first observations), GH#34846 (first-observation holds), GH#36214 (windowed zero-attempt backoff pattern).
