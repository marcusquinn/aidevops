<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-17
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Conversation context:** Found while unblocking the maintenance tail (t19074 / GH#38802). A standalone run of the stale-queued watchdog spent its whole 900 s budget on known ghosts in the first repository.

## What

Stop the stale-queued-runs watchdog (`.agents/scripts/pulse-stale-queued-runs.sh`) from re-probing job-less ghost runs that GitHub refuses to delete.

When the ghost `DELETE` returns HTTP 403, persist `<run-id>.undeletable` in the repository state directory. Later scans then skip that run with zero API calls until a re-probe TTL expires (`AIDEVOPS_STALE_QUEUED_GHOST_REPROBE_HOURS`, default 24). Expired ghosts are re-probed at most 5 per scan, so parked ghosts never re-probe in a burst.

## Why

Evidence (point-in-time, 2026-11-17T15:20Z):

- Standalone `bash ~/.aidevops/agents/scripts/pulse-stale-queued-runs.sh` ran for its full 900 s budget. It logged 75+ `unkillable-ghost` + `delete-failed` pairs for `marcusquinn/aidevops` (runs about 499,000 s old, from 2026-11-11) and never reached the next repository.
- A direct `gh api --method DELETE repos/marcusquinn/aidevops/actions/runs/43097902748` on a confirmed job-less ghost (`jobs.total_count == 0`, `status == queued`) returns `HTTP 403 {"message":"Could not delete the workflow run"}`. GitHub will not delete a run it still considers queued, so the `deleted-empty-ghost` path can never succeed for these runs.
- The state directory already holds 196 `.ghost` records (145 for `marcusquinn/aidevops`, 51 for one private managed repo). The `.ghost` file suppresses only the log line. Every hourly scan still spends about 10 REST calls per ghost: still-stale read ×5, cancel, force-cancel, jobs, logs and DELETE.
- REST core fell to 1932/5000 during the run, and `gh-transport` then deferred reads (`local primary pacing`). Dispatch shares that budget (`_dispatch_rest_core_progress_allows_next`).
- t19074 (PR #38804) makes the maintenance tail run hourly again under drains. Without this fix, every tail would burn its REST budget on unkillable ghosts, and repositories later in `repos.json` would never get their real stale runs cancelled.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One new state marker in a single script, one HTTP classification and a skip check. No new API calls, and no change to cancellation semantics.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-stale-queued-runs.sh:29-40` — in `_sq_api`, classify `HTTP 403` into `SQ_HTTP=403`, alongside the existing 409/404/410 handling.
- `EDIT: .agents/scripts/pulse-stale-queued-runs.sh:81-146` — in `_sq_handle_run`, skip parked ghosts before any API call. In both `delete-failed` branches, park the run when `SQ_HTTP == 403`.
- `EDIT: .agents/scripts/pulse-stale-queued-runs.sh:241-267,294` — reset a per-scan re-probe counter in `_sq_scan_queued`, and declare it with the other `SQ_*` locals in `pulse_stale_queued_runs_scan`.
- `EDIT: .agents/reference/github-runner-stale-queued-watchdog.md` — document the 403 park, the TTL setting and the re-probe cap.

### Complete Write Surface

- **Callers/readers:** `pulse-wrapper.sh:698` runs `pulse_stale_queued_runs_scan` as the optional `stale_queued_runs` stage. Standalone execution uses the script's `BASH_SOURCE` guard. Only `_sq_handle_run` reads the new marker.
- **Writers/mutation paths:** one new file per parked ghost, `${SQ_STATE}/<owner>/<repo>/<run-id>.undeletable`, which holds the park epoch. It is written only under the existing owner-PID lock (`_lock_acquire`), next to the existing `.ghost` and `.orphan-rerun` records.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-orphaned-job-rerun.sh` sources the script and covers the orphan path; it must stay green. No test covers ghost handling (`rg "deleted-empty-ghost|unkillable-ghost" .agents/scripts/tests` is empty). Production evidence comes from the standalone run's outcome lines and the REST `rate_limit` before and after.
- **Schemas/config:** one env setting, `AIDEVOPS_STALE_QUEUED_GHOST_REPROBE_HOURS`, documented in the reference table. There is no config file schema (`rg "STALE_QUEUED" .agents/configs` is empty).
- **Generated/deployed mirrors:** `setup.sh` deploys to `~/.aidevops/agents/scripts/`. There is no generated output.
- **Migrations/backfills:** N/A, because existing `.ghost` records are unchanged. A known ghost gets parked the first time its DELETE returns 403 after deploy, at the same cost as a current scan. No backfill script is needed.
- **Cleanup/rollback paths:** rollback is `git revert` plus `setup.sh`. Leftover `.undeletable` files are inert, since nothing else reads them (`rg "undeletable" .agents/scripts` is empty before this change).

### Implementation Steps

1. In `_sq_api`, add `elif grep -q 'HTTP 403' "${output}.err"; then SQ_HTTP=403`.
2. Add `_sq_ghost_parked state id` (returns 0 to skip). It reads the epoch from `${state}/${id}.undeletable`, treats an invalid value as 0, and skips while `SQ_NOW - parked < ttl*3600`. After expiry it allows at most 5 re-probes per scan (`SQ_GHOST_REPROBES`) and skips the rest. Add `_sq_ghost_park state id`, which writes `SQ_NOW` to the marker.
3. In `_sq_handle_run`, after the id validation and before `_sq_still_stale`, add `_sq_ghost_parked "$state" "$id" && return 0`. In both `delete-failed` else branches, add `[[ "$SQ_HTTP" == 403 ]] && _sq_ghost_park "$state" "$id"`.
4. Set `SQ_GHOST_REPROBES=0` at the start of `_sq_scan_queued`, and add it to the `local` list in `pulse_stale_queued_runs_scan`.
5. Update the reference doc table and the "Unkillable ghosts" paragraph.

### Hazards and Compatibility

- **Concurrency/atomicity:** markers are written only under the existing owner-PID lock. A partial or corrupt marker reads as epoch 0, which counts as expired, so the run is simply re-probed (bounded by the cap).
- **Migration/rollback:** no ordering constraint. Before deploy, behaviour is unchanged. After rollback, markers are ignored and the old per-scan cost returns.
- **Mixed-version/backward compatibility:** older scripts ignore `.undeletable`. Cancellation, force-cancellation and the 404/410 empty-ghost proof are unchanged, and `AIDEVOPS_STALE_QUEUED_RUN_DELETE*` keep their meaning.
- **Idempotency/retry:** parking only skips work. Transient failures, REST admission denial (`SQ_DENIED`) and 409/5xx do not park, so the run is retried next scan as today. Only an explicit 403 refusal parks.
- **Partial failure/recovery:** if GitHub later clears or starts a parked run, the queued listing stops returning it and the marker is never read again. If a run becomes deletable, the TTL re-probe deletes it.

### Verification Before Dispatch

```bash
shellcheck -x -P .agents/scripts .agents/scripts/pulse-stale-queued-runs.sh
bash .agents/scripts/tests/test-pulse-orphaned-job-rerun.sh
.agents/scripts/linters-local.sh --changed
# Runtime after deploy (standalone run, same REST guard as the stage):
bash ~/.aidevops/agents/scripts/pulse-stale-queued-runs.sh   # first run parks; reaches later repos
fd -e undeletable . ~/.aidevops/.agent-workspace/pulse/stale-queued-runs | wc -l   # > 0
gh api rate_limit --jq .resources.core.remaining   # a second run within 1h costs near zero calls for parked ghosts
```

- **Surface mapping:** shellcheck and the changed-file linters cover the edited script. `test-pulse-orphaned-job-rerun.sh` proves the shared `_sq_api`, `_sq_scan_repo` and orphan paths still work. The runtime commands prove the acceptance criteria: ghosts are parked, the scan reaches every repository, and REST cost falls on later scans.
- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/pulse-stale-queued-runs.sh`
- `.agents/reference/github-runner-stale-queued-watchdog.md`

## Acceptance Criteria

- [ ] A job-less ghost whose DELETE returns 403 gets a `.undeletable` marker. The next scan within the TTL makes no API call for it and logs nothing for it.
- [ ] After the TTL, at most 5 parked ghosts per scan are re-probed. The others stay skipped until a later scan.
- [ ] A DELETE failure other than 403, a REST admission denial or a read failure does not park the run.
- [ ] Runtime: a standalone scan completes all Pulse-managed repositories within the stage timeout once ghosts are parked.

## Context & Decisions

- Rejected: deleting ghost records or adding a new GitHub support path. The API cannot remove queued runs, so skipping is the only zero-cost behaviour.
- Rejected: parking on any DELETE failure. Transient 5xx or rate-limit failures must keep today's retry semantics.
- The re-probe cap keeps the 24 h TTL from turning into a daily burst of about 1,450 calls when 145 ghosts expire together.
