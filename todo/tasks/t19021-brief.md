<!-- aidevops:brief-schema=v2 -->

# t19021: Stop gh shim temp-file leaks that bloat the agent tmp root and slow dispatch

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `gh shim temp file leak request-attempts tmp directory cleanup` → 0 hits
- [x] Discovery pass: no open PRs touch `.agents/scripts/gh`, `gh-transport-controls.sh` or `gh-api-instrument.sh` cleanup paths
- [x] File refs verified at HEAD `4cd60f89a9`
- [x] Tier: `tier:standard`. Cleanup of the shim's own scratch; no routing, quota or trust-boundary change

## Origin

- **Created:** 2026-11-15
- **Session:** opencode interactive productivity mission (Parent #38332 / t19002 evidence track)
- **Created by:** ai-interactive
- **Conversation context:** The maintainer asked for higher Pulse/worker issue-solving throughput. Dispatch-stage timing showed the per-dispatch `dedup.setup_worker_log` stage taking minutes. Tracing that stage led to the shared agent tmp root, which leaked `gh-*` scratch was filling.

## What

1. `gh auth *` must not leave a `gh-request-attempts.XXXXXX` file. Today the shim creates the per-invocation attempt state and then `exec`s native gh, so its EXIT trap never runs.
2. A REST read interrupted by `timeout`/TERM/INT/HUP must not leave its `gh-transport-meta.*`/`gh-transport-error.*`/`gh-identity.*` scratch. Those paths are local variables removed only on the normal return path.
3. A producer-owned sweep reaps what only SIGKILL or a crash can leave, and clears the existing backlog. Its scope: exact mktemp names, top level of the agent tmp root, owned by the user, older than 24h. It runs hourly from `gh_trim_log` (pulse cycle end) and on demand via `gh-api-instrument.sh sweep-temp`.
4. (Scope added during implementation.) `_aidevops_research_staging_sweep` runs on every dispatch, but its 7-day retention needs a full walk (1.21s over 60k entries) at most hourly. It is now throttled by a sibling `research-staging.sweep-stamp`; `AIDEVOPS_RESEARCH_STAGING_SWEEP_INTERVAL_SECONDS=0` restores every-call behaviour.

## Outcome (measured in this session)

- Worktree shim through the leak probe: `auth status` 0, `auth token` 0, REST read 0, TERM-interrupted read 0 leaked (before: 1, 1, 0, 2). KILL still leaves 3; the sweep covers them.
- Sweep against the live root: 101,078 → 20,920 entries. Every remaining `gh-request-attempts` file is <24h old except one at the threshold. Unrelated `gh-*` names were untouched.
- `aidevops_pulse_tmp_cleanup` isolated cost: 8.87s → 1.63s. Tmp-root globs: 7.1s → 0.11s. With the research-staging throttle, the remaining per-dispatch walk is skipped between hourly sweeps.

## Why

Measured on 2026-11-15 (local machine, point-in-time):

- Agent tmp root: 101,078 entries. 78,555 `gh-request-attempts.*`, 7,682 `gh-transport-error.*`, 7,040 `gh-transport-meta.*`, 115 `gh-identity.*`. Attempt-file ages: 353 <1h, 10,304 <24h, 59,000 <7d, 8,905 >7d. That is ~430 leaked files per hour.
- A scratch probe reproduced leaks for `gh auth status`/`gh auth token` only. API rate-limit, REST read and `pr list` did not leak. TERM left error/meta files; KILL left all three kinds.
- `system-cleanup.sh` (7-day retention, Trash on macOS) exhausts its budget every run (`elapsed_s=30 budget_s=60 budget_exhausted=1`) and has trashed 156,668 `gh-request-attempts` entries per `system-cleanup.log`, yet 8,905 entries older than 7 days remain.
- `dispatch-stages.tsv` `dedup.setup_worker_log`: 65–381s per dispatch between 06:19Z and 06:39Z. An isolated xtrace of `aidevops_pulse_tmp_cleanup` (the stage's work) took 8.87s. 7.1s of that was two bash globs over the tmp root: `_ptsw_count_workspace_candidates` 4.82s and `_ptsw_sweep_stale_workspaces` 2.29s. The extra in-pulse inflation (concurrent load) is a hypothesis, not yet measured.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Three narrow edits that follow existing patterns. Cleanup before exec mirrors the existing EXIT trap. The registry mirrors `_ghrp_cleanup_temp`. The sweep mirrors `_gh_cleanup_legacy_scratch` (exact names, owner check, age floor).

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/gh:250-266`: replace the conditional `trap 'gh_request_attempt_state_cleanup' EXIT` with an unconditional `_shim_exit_cleanup` trap that also calls `_gh_transport_cleanup_live_temps`.
- `EDIT: .agents/scripts/gh:300-315`: call `_shim_exit_cleanup` before `exec "$_real_gh" "$@"` in the `auth:*` passthrough.
- `EDIT: .agents/scripts/gh-transport-controls.sh`: add `_GHGT_LIVE_TEMPS` with `_gh_transport_track_temp`, `_gh_transport_remove_temps` (remove and forget) and `_gh_transport_cleanup_live_temps`. Track every `mktemp` in `_gh_transport_capture_errors`, `_gh_transport_run_rest` and `_gh_transport_identity_read`, and replace their `rm` calls.
- `EDIT: .agents/scripts/gh-api-instrument.sh`: add `gh_sweep_orphan_temps [--force]`, using one `find -delete` per kind (never a per-file stat loop), throttled by `${GH_API_LOG}.temp-sweep`. Call it from `gh_trim_log` and add a `sweep-temp` CLI subcommand.
- `EDIT: .agents/scripts/tests/test-gh-api-instrument.sh`: assert `gh auth token` leaves no `gh-request-attempts.*` file. Isolate `AIDEVOPS_TEMP_DIR`, because `gh_trim_log` now sweeps the temp root (an unisolated run swept the host root).
- `EDIT: .agents/scripts/pulse-temp-helper.sh:57-105`: hourly throttle for `_aidevops_research_staging_sweep`.

### Complete Write Surface

- **Callers/readers:** nested shim invocations reuse an inherited attempt-state file only when its logical ID matches. Cleanup removes a file only when this process owns it (`_GH_API_REQUEST_ATTEMPT_STATE_OWNER`).
- **Writers/mutation paths:** the sweep deletes only exact `gh-request-attempts|gh-transport-error|gh-transport-meta.??????` regular files and `gh-identity.??????` directories. They must be user-owned, at depth 1 and older than `AIDEVOPS_GH_TEMP_SWEEP_MIN_AGE_MINUTES` (default 1440).
- **Existing verification/tests:** `.agents/scripts/tests/test-gh-api-instrument.sh`, `.agents/scripts/tests/test-gh-shim.sh` (sources `test-gh-shim-transport-cases.sh`).
- **Generated/deployed mirrors:** deployed by `setup.sh`; nothing generated.
- **Cleanup/rollback paths:** a revert restores the previous leak behaviour. Swept files are disposable per-invocation scratch.

### Hazards and Compatibility

- No live gh invocation lasts 24h, so the age floor cannot remove the state of a running command (`gh run watch` included).
- The registry forgets paths as it removes them. The EXIT trap therefore never deletes another process's file that reused a freed mktemp name.
- Command substitutions do not inherit the EXIT trap. Scratch created inside `$(...)` is still removed inline; only signals inside that subshell fall back to the age sweep.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-shim.sh
shellcheck -x .agents/scripts/gh .agents/scripts/gh-transport-controls.sh .agents/scripts/gh-api-instrument.sh
```

Production path: `gh auth status` and a TERM-interrupted `gh api` through the worktree shim leave no new `gh-*` file. `gh-api-instrument.sh sweep-temp` then reports `removed=N` and the tmp root entry count drops.

### Files Scope

- `.agents/scripts/gh`
- `.agents/scripts/gh-transport-controls.sh`
- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/tests/test-gh-api-instrument.sh`
- `.agents/scripts/pulse-temp-helper.sh`

## Acceptance Criteria

- [ ] `gh auth token` and `gh auth status` leave no `gh-request-attempts.*` file.
- [ ] A TERM-interrupted `gh api` REST read leaves no `gh-transport-meta.*`/`gh-transport-error.*` file.
- [ ] `gh-api-instrument.sh sweep-temp` removes only exact-name, user-owned shim scratch older than 24h and reports the count.
- [ ] After the sweep, the per-dispatch `aidevops_pulse_tmp_cleanup` glob cost falls well below the measured 7.1s.
