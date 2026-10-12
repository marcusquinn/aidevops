<!-- aidevops:brief-schema=v2 -->

# fix(pulse): stop counting the async post-dispatch housekeeping run as a Pulse cycle

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `async housekeeping pulse_pids main cycle drain ceiling` → 0 hits
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged PR on this classification; related history is GH#33256 (async housekeeping in its own process group), GH#34287 (resumable housekeeping) and t18675 / GH#34452 (setup drains to the cycle boundary)
- [x] File refs verified at origin/main f04e8eb925: `_pulse_pids` `.agents/scripts/pulse-lifecycle-helper.sh:706` (Layer 1 fast path `:718`); `_is_running` `:770`; `_pulse_reconcile_defers_to_cycle_boundary` `:863` (`[[ -n "$_main_pids" ]] || return 1` `:872`); `_status` `:1069`; housekeeping lock owner writes `.agents/scripts/pulse-dispatch-engine.sh:1170` and `:1186` (`${BASHPID:-$$}`); async launch `_pulse_start_post_dispatch_housekeeping` `:1458` (`disown` `:1491`)
- [x] Tier: `tier:standard` — two production scripts plus focused cases in three existing suites; no new interfaces
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the filing session

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation after t18675 and t18678; setup reconciliation and `pulse-lifecycle-helper.sh status` treated the async housekeeping run as a Pulse cycle.

## What

The async post-dispatch housekeeping run is identified by a marker in its own lock and is never counted as a Pulse main cycle. Setup reconciliation's drain ceiling, `is-running` and the `status` instance count consider only real cycles, and the housekeeping lock names the shell that actually runs housekeeping on every supported Bash, including 3.2.

## Why

- **Live evidence (2026-10-12, v3.39.22):** the deployed `pulse-lifecycle-helper.sh status` printed `Pulse: running (2 instances)` for cycle PID 7842 and PID 61317. 61317 is the async housekeeping run its predecessor cycle launched (`Async post-dispatch housekeeping: launched pid=61317` in `~/.aidevops/logs/pulse.log`); it had PPID 1, its own process group and the bare `pulse-wrapper.sh` argv.
- **Both setup reconciliations since t18675 shipped listed a housekeeping run as a cycle** (`~/.aidevops/logs/auto-update.log`): `Deferring Pulse replacement to the cycle boundary: earlier-bundle cycle 84753 (2104s) 95675 (1394s) keeps running` and `... earlier-bundle cycle 18030 (1632s) 66498 (2277s) keeps running`. 84753 and 66498 are housekeeping PIDs from the pulse.log launch lines.
- **Mechanism:** GH#33256 starts housekeeping as a disowned `( ... ) &` subshell in its own process group, so it outlives the cycle, is reparented to launchd/init and keeps the wrapper argv. `_pulse_pids` Layer 1 treats every PPID=1 wrapper process as a top-level instance. `_pulse_reconcile_defers_to_cycle_boundary` replaces immediately when any listed earlier-bundle PID is at or above `AIDEVOPS_PULSE_RECONCILE_DRAIN_MAX_AGE_S` (3600s). Housekeeping runs up to eight stages of `PREFLIGHT_GROUP_TIMEOUT` (600s), so healthy runs pass 35 minutes (above) and can pass the ceiling; a deploy then kills the young in-flight cycle, and the dispatch it was about to make, that t18675 exists to protect. The same classification makes `is-running` report a running Pulse when no cycle runs, which suppresses `pulse-watchdog-tick.sh` revival, and inflates the `status` PILE-UP count.
- **Bash 3.2:** `${BASHPID:-$$}` inside the async subshell records the cycle PID. Once that cycle exits, the next cycle sees a dead lock owner, reclaims the lock and launches a second housekeeping run beside the first. Hosts where Pulse re-execs into Bash 4+ are unaffected (the live host runs Homebrew bash), but Bash 3.2 remains a supported runtime.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a bounded classification change in two scripts with an existing reference pattern for the Bash 3.2 executing-shell PID (`.agents/scripts/pulse-logging.sh:98-102`); process-identity edge cases need care but no new interfaces or config.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-engine.sh` — add `_pulse_record_post_dispatch_housekeeping_owner`: resolve the executing shell (`BASHPID`, else `$(exec sh -c 'printf "%s" "$PPID"')` as in `pulse-logging.sh:98-102`, else `$$`), always write `pid`, and write `async-pid` only when `_PULSE_HOUSEKEEPING_ASYNC=1`; use it at both lock-acquire sites; set `_PULSE_HOUSEKEEPING_ASYNC=1` inside the async subshell of `_pulse_start_post_dispatch_housekeeping`.
- `EDIT: .agents/scripts/pulse-lifecycle-helper.sh` — add `_PULSE_HOUSEKEEPING_LOCK_DIR` (test override `AIDEVOPS_PULSE_HOUSEKEEPING_LOCK_DIR`), `_pulse_pid_is_async_housekeeping` (the marker names the PID and the process started no later than the marker was written, so a reused PID stays a cycle) and `_pulse_async_housekeeping_pid`; skip that PID in `_pulse_pids`; in `_pulse_reconcile_defers_to_cycle_boundary`, when no cycle runs, defer for a young housekeeping run and replace one at or above the ceiling as before; list the run separately in `_status`.
- `EDIT: .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh` — the async lock records the async subshell in `pid` and `async-pid`; a synchronous run records the cycle PID and writes no `async-pid`.
- `EDIT: .agents/scripts/tests/test-pulse-lifecycle-helper.sh` — housekeeping alone is not running; one cycle plus housekeeping is one instance; a PID the marker predates counts as a cycle; a pid-only lock keeps its cycle counted.
- `EDIT: .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh` — housekeeping past the drain ceiling leaves the activated-bundle cycle running; a young run with no cycle running is left to finish without a launchd kickstart.

### Complete Write Surface

- **Callers/readers:** `is-running` — `.agents/scripts/pulse-watchdog-tick.sh:173` and `:177` (revival gate; a housekeeping-only state now falls through to its existing interval-plus-grace check); `reconcile-managed` — `.agents/scripts/setup/modules/agent-deploy.sh:31`; `status` — operators and the remediation text in `.agents/scripts/runtime-audit-rules/idle-state-stuck.sh:99`; `_start`/`_restart_if_running` use `_is_running`. The housekeeping lock path is defined once in `pulse-dispatch-engine.sh:1151`.
- **Writers/mutation paths:** the lock is created only by `_pulse_acquire_post_dispatch_housekeeping_lock` (fresh `mkdir` or stale reclaim after `rm -rf`), so `async-pid` exists only for the run that owns the lock; `_pulse_release_post_dispatch_housekeeping_lock` removes the directory.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-lifecycle-helper.sh` (mock `pulse-wrapper.sh` processes for `is-running`/`status`), `.agents/scripts/tests/test-agent-deploy-pulse-runtime.sh` (launchd `reconcile-managed` drain with a fake `launchctl`) and `.agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh` (housekeeping lock and stages).
- **Schemas/config:** N/A because no settings key changes; the new env var is a test override.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` into the runtime bundle; no generated copy.
- **Migrations/backfills:** N/A because a run started by an older bundle has no `async-pid` and is classified exactly as before until it exits.
- **Cleanup/rollback paths:** `git revert`; a leftover `async-pid` from an old run is ignored once its PID is reused, because the reused process started after the marker was written.

### Implementation Steps

1. `pulse-dispatch-engine.sh`: add `_pulse_record_post_dispatch_housekeeping_owner "$lockdir"` next to `_pulse_post_dispatch_housekeeping_lockdir`; replace both `printf '%s\n' "${BASHPID:-$$}" >"${lockdir}/pid"` writes in `_pulse_acquire_post_dispatch_housekeeping_lock` with a call to it; add `_PULSE_HOUSEKEEPING_ASYNC=1` after `AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0` in the async subshell.
2. `pulse-lifecycle-helper.sh`: define `_PULSE_HOUSEKEEPING_LOCK_DIR` beside `_PULSE_SIDECAR_FLAGS_RE`; add `_pulse_pid_is_async_housekeeping` (read `async-pid`, require an exact PID match, then `date -r <marker> +%s` ≥ `now - _pulse_process_age_seconds` − 2s) and `_pulse_async_housekeeping_pid` (marker PID that is alive, matches `_PULSE_PATTERN` and passes the identity check) before `_pulse_pids`.
3. In `_pulse_pids`, `continue` for that PID before the Layer 1 PPID=1 fast path.
4. In `_pulse_reconcile_defers_to_cycle_boundary`, replace `[[ -n "$_main_pids" ]] || return 1` with: no housekeeping → `return 1`; housekeeping age ≥ ceiling → log and `return 1`; otherwise log `Deferring Pulse start to the launchd interval` and `return 0`.
5. In `_status`, print `Pulse: not running (async housekeeping only)` when it is the only process, and an `Async housekeeping: PID …` line outside the instance count; document the env override in the header and usage text.
6. Add the test cases listed above and run the verification below on `/bin/bash` 3.2.

### Hazards and Compatibility

- **Concurrency/atomicity:** the owner is written inside the `mkdir` lock by the owning shell; readers only compare PID plus start time, never signal on it.
- **Migration/rollback:** mixed versions are safe in both directions — older readers ignore `async-pid`; newer readers treat a marker-less run as before.
- **Mixed-version/backward compatibility:** `_stop_all` and `_stop_reconciliation_processes` still use the raw process list, so explicit stop and immediate replacement still retire the housekeeping run.
- **Idempotency/retry:** classification is a pure read; repeated `status`/`is-running` calls are side-effect free.
- **Partial failure/recovery:** a missing or unreadable marker, or an unavailable process age or mtime, falls back to counting the PID as a cycle (the previous behaviour).

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh .agents/scripts/pulse-dispatch-engine.sh .agents/scripts/tests/test-pulse-lifecycle-helper.sh .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh
AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh
AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh
AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh
```

- **Surface mapping:** housekeeping suite → lock owner on Bash 3.2; lifecycle suite → `is-running`/`status` classification; deploy runtime suite → `reconcile-managed` drain decision. Production proof: on the released bundle, `pulse-lifecycle-helper.sh status` lists the live housekeeping run as `Async housekeeping: PID …` and counts only the cycle, and the next setup reconciliation names only real cycles.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change housekeeping stage order, timeouts, the drain ceiling default, `_stop_all`, or the watchdog's revival thresholds.

**Not in scope (follow-up):** the gap between a cycle's exit and the next launchd start, and the dispatch-budget starvation seen in the same investigation, are separate throughput tasks.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/pulse-dispatch-engine.sh`
- `.agents/scripts/pulse-lifecycle-helper.sh`
- `.agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh`
- `.agents/scripts/tests/test-pulse-lifecycle-helper.sh`
- `.agents/scripts/tests/test-agent-deploy-pulse-runtime.sh`

## Acceptance Criteria

- [ ] `status` and `is-running` count only cycles: housekeeping alone is "not running", and one cycle plus housekeeping is one instance. Regression guard: a reused PID or a pid-only (synchronous) lock is still counted as a cycle.

  ```yaml
  verify:
    method: bash
    run: "AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh"
  ```

- [ ] Setup reconciliation never replaces an activated-bundle cycle because of the housekeeping run's age, and still drains or replaces real cycles as before.

  ```yaml
  verify:
    method: bash
    run: "AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh"
  ```

- [ ] On Bash 3.2 the housekeeping lock names the async subshell, not the cycle, and a synchronous run writes no `async-pid`.

  ```yaml
  verify:
    method: bash
    run: "AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh"
  ```

- [ ] ShellCheck reports no findings for the changed files.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh .agents/scripts/pulse-dispatch-engine.sh"
  ```

- [ ] On the released bundle, live `status` lists the housekeeping run apart from cycles.

  ```yaml
  verify:
    method: manual
    prompt: "After deploy, while an async housekeeping run is alive, confirm `pulse-lifecycle-helper.sh status` prints `Async housekeeping: PID <pid>` and counts only the cycle"
  ```
