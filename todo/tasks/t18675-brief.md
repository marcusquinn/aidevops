<!-- aidevops:brief-schema=v2 -->

# fix(pulse): stop setup reconciliation killing in-flight Pulse cycles on every deploy

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse reconcile-managed setup deploy kills in-flight cycle drain` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged PRs on `.agents/scripts/pulse-lifecycle-helper.sh` beyond GH#33777 (#33784, watchdog revive loop); issue searches for reconcile/interrupted-cycle duplicates returned nothing
- [x] File refs verified at origin/main 0b77031120: `_reconcile_managed` (`.agents/scripts/pulse-lifecycle-helper.sh:858`), `_stop_reconciliation_processes` (`:726`), `_pulse_start_managed` (`:272`), `_pulse_pid_uses_active_runtime` (`:504`), `_pulse_pids` (`:617`), `_setup_restart_pulse_if_running` (`setup.sh:1976`, called unconditionally from `setup.sh:2115`)
- [x] Tier: `tier:standard` — one decision function in the lifecycle helper plus fixture coverage in the existing deploy suite
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. Interrupted cycles were the largest single loss of dispatch time on this runner, and every interrupted record lined up with the end of a setup run.

## What

Setup's Pulse reconciliation no longer kills a launchd-managed Pulse cycle that is still running from an earlier runtime bundle. The cycle finishes on its own bundle and launchd starts the activated bundle at the next start. A cycle older than a drain ceiling (default 3600s) is still replaced immediately, as today.

## Why

- Every `setup.sh` run ends with `_setup_restart_pulse_if_running` → `pulse-lifecycle-helper.sh reconcile-managed`, including scoped `--stage` runs. `_stop_reconciliation_processes` snapshots every `pulse-wrapper.sh` / `pulse-merge-routine.sh` process regardless of the bundle it runs, sends TERM, waits 2s, escalates to KILL, then `launchctl kickstart -k`.
- On 2026-10-11 (UTC) this runner recorded 39 cycles in `pulse-cycle-index.jsonl`: 9 `progressed` (16 workers dispatched), 13 `idle`, 17 `partial/interrupted` (4 dispatched). All 17 interrupted records were written 2–16s after a setup run's last timed stage (`setup_tabby` in `setup-stage-timings.log`), i.e. at the reconciliation step. They had run 17–1,566s; 10,605s of cycle wall time was discarded that day.
- There were 42 setup runs that day. `auto-update.log` alone shows 22 "Stopping pre-reconciliation Pulse process(es)" events, 19 escalated to SIGKILL; three of them redeployed the commit the killed cycle was already running (same `<version>-<sha>` bundle prefix).
- Productive cycles take long on this runner: progressed cycles ran 1,717–2,296s wall (max 2,445s over two days), and dispatch happens late in the cycle, so a deploy landing mid-cycle usually throws away the dispatch it was about to make.
- Killing is not needed for code consistency. A running cycle executes one immutable bundle: `pulse-wrapper.sh` resolves its physical script directory and holds a runtime-bundle lease (`pulse-wrapper.sh:204-233`), and old bundles stay on disk while leased. The supervisor LaunchAgent runs the stable link `~/.aidevops/agents/scripts/pulse-wrapper.sh` with `StartInterval` 120 and `KeepAlive`/`SuccessfulExit=false`, so the next start after the cycle exits resolves to the activated bundle.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a guarded early exit in one lifecycle function, with the immediate path unchanged; correctness hinges on process classification already implemented in the helper.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-lifecycle-helper.sh` — add `_pulse_process_age_seconds` (portable `ps -o etime=` parser; macOS `ps` has no `etimes`), `_pulse_launchd_supervisor_loaded` (`launchctl print gui/<uid>/<label>` succeeds), and `_pulse_reconcile_defers_to_cycle_boundary`. In `_reconcile_managed`, between the supervisor-disabled branch and the stop/start branch, add `elif _pulse_reconcile_defers_to_cycle_boundary; then` that retires only standalone merge routines (`_stop_reconciliation_processes standalone-merge`, selected through `_pulse_pid_descends_from`) and does not kickstart launchd. Document `AIDEVOPS_PULSE_RECONCILE_DRAIN` and `AIDEVOPS_PULSE_RECONCILE_DRAIN_MAX_AGE_S` in the header and `_usage`.
- `EDIT: .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh` — fixture cases with the existing fake `launchctl`: an earlier-bundle cycle under the ceiling and the merge routine it spawned are left running with no `kickstart`, while a standalone merge routine is retired; the same cycle with the ceiling at 0 is replaced by the active bundle through `kickstart -k`.

### Decision rules

`_pulse_reconcile_defers_to_cycle_boundary` returns 1 (keep today's immediate replacement) when any of these hold:

1. `AIDEVOPS_PULSE_RECONCILE_DRAIN=0`;
2. the launchd supervisor job is not loaded (Linux, cron/systemd, manual starts keep today's behaviour);
3. no main Pulse PID is running (`_pulse_pids` empty — nothing to lose, start now);
4. any earlier-bundle main PID has an unreadable age or an age at or above the ceiling.

Otherwise it logs which PIDs keep running and returns 0. Main PIDs already proven to run the activated bundle (`_pulse_pid_uses_active_runtime`) are reported as current and never signalled.

Merge routines are split by process tree. One spawned inside a cycle (`pulse-dispatch-preflight-lib.sh:176`, `${SCRIPT_DIR}/pulse-merge-routine.sh`) runs from that cycle's leased bundle and finishes with it. The standalone launchd job runs the stable link (`schedulers-platform.sh:455`), and `pulse-merge-routine.sh:54` resolves `SCRIPT_DIR` without `pwd -P` and takes no lease, so after activation it would call new-bundle helpers from old in-memory code. It is still retired while a cycle drains; its 60s job restarts it on the activated bundle.

### Complete Write Surface

- **Callers/readers:** `reconcile-managed` is called only by `_restart_pulse_if_running` (`.agents/scripts/setup/modules/agent-deploy.sh:17`), from `setup.sh:2022`. `stop`, `restart`, `restart-if-running`, and the supervisor-disabled path are unchanged.
- **Writers/mutation paths:** while a cycle drains, only standalone merge routines are signalled and launchd is not kickstarted; no files written.
- **Existing verification/tests:** `test-agent-deploy-pulse-runtime.sh`, `test-pulse-lifecycle-helper.sh`, `test-pulse-launchd-setup.sh`.
- **Schemas/config:** two optional environment knobs; no config schema change.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/`; setup runs the activated bundle's helper, so the release that ships this fix already reconciles with it.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** `AIDEVOPS_PULSE_RECONCILE_DRAIN=0`, or revert the commit.

### Hazards and Compatibility

- **Convergence:** an earlier-bundle cycle keeps running for at most the ceiling after the first deferring setup; the next setup after that replaces it. Operators who need new code immediately still run `pulse-lifecycle-helper.sh restart`.
- **Single instance:** launchd does not start a second instance of the job while the cycle runs, so deferral cannot create two top-level revisions of the main Pulse (GH#27885 acceptance).
- **Bootstrap recovery:** `pulse-runtime-recovery.sh` runs `setup.sh --stage ai-session` from inside a starting wrapper; that wrapper is young, so it now defers instead of terminating itself before the recovery re-exec.
- **Bash 3.2:** here-strings, pattern substitution and `10#` arithmetic only.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh
bash .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh
bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh
bash .agents/scripts/tests/test-pulse-launchd-setup.sh
/bin/bash .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh
```

- **Surface mapping:** the deploy suite drives the real `_restart_pulse_if_running` → `reconcile-managed` with fixture bundles and a fake `launchctl`.
- **Live check after deployment:** the next setup logs "Deferring Pulse replacement to the cycle boundary" instead of "Stopping pre-reconciliation Pulse process(es)", and `pulse-cycle-index.jsonl` stops gaining `interrupted` records 2–16s after `setup_tabby`.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change `stop`, `restart`, `restart-if-running`, the supervisor-disabled path, SIGTERM/SIGKILL timing, or setup's call sites.

**Not in scope (follow-up):** systemd/cron schedulers on Linux keep immediate replacement; setup running reconciliation on scoped `--stage` runs; redeploys of an unchanged commit creating a new bundle.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/pulse-lifecycle-helper.sh`
- `.agents/scripts/tests/test-agent-deploy-pulse-runtime.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] With a loaded launchd supervisor, reconciliation leaves an earlier-bundle cycle under the ceiling running and does not call `kickstart`.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh"
  ```

- [ ] A cycle at or above the ceiling, a disabled drain, an unloaded supervisor, or no running cycle keep today's immediate replacement.

  ```yaml
  verify:
    method: codebase
    pattern: "_pulse_reconcile_defers_to_cycle_boundary"
    path: ".agents/scripts/pulse-lifecycle-helper.sh"
  ```

- [ ] Existing lifecycle and launchd setup suites pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh && bash .agents/scripts/tests/test-pulse-launchd-setup.sh"
  ```

- [ ] ShellCheck reports no findings for the changed files.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh .agents/scripts/tests/test-agent-deploy-pulse-runtime.sh"
  ```
