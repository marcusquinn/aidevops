<!-- aidevops:brief-schema=v2 -->

# fix(worker-lifecycle): stop the fix-the-fixer log watcher deadlocking workers before model invocation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `verbose lifecycle watcher command substitution hang fix-the-fixer worker wedged` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no recent commits, merged or open PRs on `.agents/scripts/worker-lifecycle-verbose.sh`
- [x] File refs verified at origin/main 9b61091128: `_start_verbose_lifecycle_watcher` (`.agents/scripts/worker-lifecycle-verbose.sh:83`), its only caller `_start_run_attempt_observers` (`.agents/scripts/headless-runtime-attempt.sh:337`), cleanup (`headless-runtime-attempt.sh:346`) and the only enabler (`headless-runtime-helper.sh:431`)
- [x] Tier: `tier:standard` — one function in one module, behaviour proven by a process-level probe on Bash 3.2 and 5.3
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. A `fix-the-fixer` worker for marcusquinn/cloudron-netbird-app#165 held a worker slot for over five hours without starting its model.

## What

A worker whose issue carries `fix-the-fixer` starts its model immediately after the verbose lifecycle watcher starts, and the watcher and its log follower exit when the worker exits, when cleanup stops them, after the watch timeout, or once all four checkpoints fire.

## Why

- `_start_run_attempt_observers` captures the watcher PID with `_t3077_watcher_pid=$(_start_verbose_lifecycle_watcher "$output_file" "$$" 2>/dev/null)`. The function backgrounds the watcher subshell without redirecting its stdout, so the subshell inherits the command-substitution pipe. The capture waits for EOF on that pipe; the watcher waits for lines in the worker log; the model that writes them starts only after the capture returns. Deadlock.
- Every loop exit (worker gone, timeout, four checkpoints) was checked only after a line arrived, so nothing could release it.
- Live evidence on this runner: wrapper PID 76334 for #165 last logged `pre_attempt_observers_start` at 2026-10-11T10:44:27Z and had no `post_attempt_observers_start` five hours later. `lsof` shows the wrapper's fd 3 is the read end of a pipe whose write end is fd 1 of watcher PID 98795; the watcher's `tail -F` follows a 0-byte worker log. Its 180s fix-the-fixer activity watchdog never armed, because it starts after model launch.
- #170 in the same repo wedged at the same stage from 2026-10-10T21:38:24Z until its exit trap recorded `reason=worker_runtime_not_invoked last_stage=pre_attempt_observers_start` at 23:44:59Z. Both fix-the-fixer dispatches in the retained worker logs wedged; the 56 other retained worker logs all passed the stage.
- The `tail -F` follower also leaked: cleanup sent TERM to the watcher, which killed the subshell but not the follower, and a follower writing to a pipe without a reader only dies on its next write. One follower from 2026-10-03 was still running eight days later on a 0-byte log.
- `fix-the-fixer` is applied to issues whose workers already failed, so every such repair attempt wedged a slot for hours and recorded another failure.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a narrow process-plumbing fix in one function with a verified mechanism (lsof pipe identity) and a reproducible probe; the module is not listed in `.agents/configs/self-hosting-files.conf`.

## How

### Files to Modify

- `EDIT: .agents/scripts/worker-lifecycle-verbose.sh:83-143` — redirect the watcher subshell's stdout to `/dev/null`; read with `read -t` on a poll interval (`AIDEVOPS_VERBOSE_LIFECYCLE_WATCH_POLL_SECONDS`, default 5) so worker exit and the timeout are checked without log lines; start the follower as `sh -c 'printf "%s\n" "$$"; exec tail -F -n 0 "$1"'` so the watcher learns its PID; stop the follower on every exit path and from a TERM trap.
- `NEW: _verbose_lifecycle_stop_follower` in the same file — validates the PID before `kill` (never signals an empty or non-numeric target) and is safe under `set -e`.

### Complete Write Surface

- **Callers/readers:** `_start_run_attempt_observers` (`headless-runtime-attempt.sh:337`) is the only caller; `_cleanup_verbose_lifecycle_watcher` (`:346`) reads `watcher.pid` from the sentinel directory. `rg -n "_start_verbose_lifecycle_watcher|_cleanup_verbose_lifecycle_watcher" .agents/scripts` finds no others.
- **Writers/mutation paths:** the watcher writes only sentinel files and runtime events through `_emit_verbose_checkpoint`; `_emit_worker_runtime_event` sends its own output to `/dev/null`, so discarding the watcher's stdout loses nothing. The `[lifecycle]` lines it prints go to stderr, which the caller already discards.
- **Existing verification/tests:** `.agents/scripts/tests/test-fix-the-fixer-observability.sh` (structural plus checkpoint opt-in behaviour). It is not wired into CI.
- **Schemas/config:** new optional env `AIDEVOPS_VERBOSE_LIFECYCLE_WATCH_POLL_SECONDS` (positive integer, default 5); `AIDEVOPS_VERBOSE_LIFECYCLE_WATCH_TIMEOUT` keeps its meaning and is now enforced.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to the runtime bundle on release/update; no generated copies.
- **Migrations/backfills:** N/A because nothing is persisted. Workers already wedged on an older bundle stay wedged; recover them separately after deployment.
- **Cleanup/rollback paths:** reverting the file restores the old behaviour, deadlock included.

### Implementation Steps

1. Add `_verbose_lifecycle_stop_follower`.
2. In `_start_verbose_lifecycle_watcher`, validate the poll interval, set the TERM trap, read the follower PID from its first line, poll with `read -r -t`, and treat a failed read as a quiet interval only while the follower is alive (Bash 3.2 returns 1 for both timeout and EOF).
3. Redirect the subshell's stdout with `) >/dev/null &` and stop the follower after the loop.
4. Run ShellCheck, the observability suite, and the process probe below on `/bin/bash` 3.2 and Bash 5.

### Hazards and Compatibility

- **Concurrency/atomicity:** unchanged; one watcher per attempt, keyed by the wrapper PID.
- **Signal timing:** Bash 3.2 runs a trapped TERM only after the current `read -t` returns, so cleanup takes up to one poll interval; Bash 5 runs it immediately. The wrapper does not wait for the watcher.
- **Mixed-version/backward compatibility:** workers started by an older bundle keep the old code until they exit.
- **Partial lines:** a read timeout can split a line that arrives mid-poll and miss one checkpoint pattern. Checkpoints are best-effort diagnostics, so this is acceptable.
- **Load:** one `kill -0` and `date` per poll per fix-the-fixer worker.

### Complexity Impact

- **Target function:** `_start_verbose_lifecycle_watcher` in `.agents/scripts/worker-lifecycle-verbose.sh`
- **Current line count:** 61 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +18 lines
- **Projected post-change:** 79 lines (79% of threshold)
- **Action required:** None — the follower stop is a separate 6-line helper.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/worker-lifecycle-verbose.sh
bash .agents/scripts/tests/test-fix-the-fixer-observability.sh
```

- **Surface mapping:** ShellCheck covers the edited module; the suite proves the module still loads and the checkpoint contract holds.
- **Process probe (Bash 3.2.57 and 5.3.20):** a wrapper with the production call shape (`set -euo pipefail`, `$(... 2>/dev/null)` capture) returned the watcher PID in 0s; all four runtime events fired; the watcher and follower were gone after four checkpoints, after cleanup TERM, after the wrapper exited without cleanup, and after a 3s watch timeout with a silent log.
- **Negative control:** the same probe against the deployed old module never returned from the capture until the watcher was killed externally.
- **Broad verification trigger:** Not required — one module, no shared contract, root tooling or release infrastructure change.

### Recoverability Checkpoint

- [x] Focused functional verification passes: process probe on Bash 3.2 and 5.3; `bash .agents/scripts/tests/test-fix-the-fixer-observability.sh` (34/34)
- [x] WIP commit created before broad gates: `wip: t18672 verbose lifecycle watcher deadlock`
- [x] Evidence-triggered broad verification then run: not required — single module

### Scope Boundaries

Initial implementation map. Directly necessary adjacent integration follows
`reference/worker-discipline.md` "Integration scope recovery".

**Hard boundaries:** do not change which issues enable verbose lifecycle, the checkpoint names, or the runtime event mapping; do not kill or redispatch live workers from this change.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request
and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/worker-lifecycle-verbose.sh`
- `TODO.md`
- `todo/tasks/t18672-brief.md`

## Acceptance Criteria

- [ ] The background watcher does not hold the caller's command-substitution pipe.

  ```yaml
  verify:
    method: codebase
    pattern: "^\t\) >/dev/null &$"
    path: ".agents/scripts/worker-lifecycle-verbose.sh"
  ```

- [ ] Worker exit and the watch timeout are checked on a poll, without waiting for log lines.

  ```yaml
  verify:
    method: codebase
    pattern: "read -r -t .\$poll. line"
    path: ".agents/scripts/worker-lifecycle-verbose.sh"
  ```

- [ ] The log follower is stopped on loop exit and on TERM.

  ```yaml
  verify:
    method: codebase
    pattern: "_verbose_lifecycle_stop_follower .\$_follower_pid."
    path: ".agents/scripts/worker-lifecycle-verbose.sh"
  ```

- [ ] ShellCheck and the observability suite pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-fix-the-fixer-observability.sh"
  ```

## Context & Decisions

- **Redirect, not restructure:** callers keep `$(...)` for the PID; the fix is inside the function so no caller can reintroduce the pipe.
- **Polling over blocking reads:** a blocking read is what made worker exit and the timeout unreachable; a 5s poll costs almost nothing.
- **Follower PID from its own output:** process substitution exposes no PID in Bash 3.2, and macOS `tail` has no `--pid`.
- **Not in scope:** recovering the wedged #165 worker (maintainer session, after this deploys), and why the stall/age reapers did not catch a pre-model wedge (separate follow-up if it recurs).

## Relevant Files

- `.agents/scripts/worker-lifecycle-verbose.sh:82` — `_verbose_lifecycle_stop_follower`
- `.agents/scripts/worker-lifecycle-verbose.sh:102` — `_start_verbose_lifecycle_watcher`
- `.agents/scripts/headless-runtime-attempt.sh:337` — the PID capture that inherited the pipe
- `.agents/scripts/headless-runtime-helper.sh:431` — enables verbose lifecycle for `fix-the-fixer` issues

## Dependencies

- **Blocked by:** none
- **Blocks:** redispatch of `fix-the-fixer` issues; worker slots held by wedged wrappers
- **External:** none
