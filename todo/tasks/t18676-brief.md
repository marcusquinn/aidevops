<!-- aidevops:brief-schema=v2 -->

# fix(pulse): keep SIGPIPE ignored after a closed consumer so bash 3.2 PID emitters exit 0

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse PID emitter SIGPIPE bash 3.2` → 0 hits — no relevant lessons
- [x] Discovery pass: issue search for `_pulse_pids SIGPIPE` and `consumer closes early` found no open duplicate; closed #24429 covers a different (REST fallback) path; the check under test came from GH#23716 (#23719)
- [x] File refs verified at origin/main 6aa2b31d20: `_pulse_emit_pid` (`.agents/scripts/pulse-lifecycle-helper.sh:645`), `_pulse_restore_pipe_trap` (`:652`), `_pulse_pids` (`:703`), `_pulse_pids_sidecar` (`:743`); test `test_pulse_pids_suppresses_broken_pipe_when_consumer_exits_early` (`.agents/scripts/tests/test-pulse-lifecycle-helper.sh:964`)
- [x] Tier: `tier:simple` — exact edits below in one helper file
- [x] Seeded draft PR decision recorded: skipped — the edits are fully specified below

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** found while verifying t18675 (GH#34452) under macOS `/bin/bash` 3.2; reproduced on unmodified origin/main, so it predates that change.

## What

`_pulse_pids` and `_pulse_pids_sidecar` exit 0 under macOS `/bin/bash` 3.2.57 when their consumer closes the pipe early, as they already do under bash 5. `bash`/`/bin/bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh` both report 59/59.

## Why

- Under `/bin/bash` 3.2.57 the lifecycle suite fails 1 of 59: `_pulse_pids exits 0 when consumer closes early (expected='0' actual='141')`. The same failure occurs on origin/main c6b40ba7b6 without any local change; bash 5.3 passes.
- Root cause (verified with an isolated reproduction of the test body and `set -x`): the emit loop behaves correctly — the second `printf` returns 1 (EPIPE, SIGPIPE ignored), `_pulse_emit_pid` returns 1 and the loop breaks. Bash 3.2's `printf` builtin writes through stdio, so the bytes of the failed write stay buffered. `_pulse_restore_pipe_trap` then runs `trap - PIPE`, and the buffered bytes are flushed when the pipeline subshell exits, which raises SIGPIPE with the default disposition and kills the producer with status 141.
- Confirmation: the same reproduction with `_pulse_restore_pipe_trap` overridden by a no-op exits 0 on bash 3.2.
- Impact today is limited to the failing check (the two piped production callers, `pulse-lifecycle-helper.sh:929` and `:937`, use the output inside log-message arguments, so a 141 cannot trip `errexit`). It becomes a real abort for any future `x=$(_pulse_pids | head -1)` assignment under `set -euo pipefail` on hosts where `/usr/bin/env bash` resolves to `/bin/bash`.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** two functions in one file get the same three-line change, spelled out below; no design judgment remains.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-lifecycle-helper.sh` — in `_pulse_pids` and `_pulse_pids_sidecar`, record when `_pulse_emit_pid` reports a closed consumer and skip `_pulse_restore_pipe_trap` in that case; update the `_pulse_emit_pid` comment.

### Complete Write Surface

- **Callers/readers:** `_status`, `_is_running`, `_pulse_find_active_runtime_pid_since`, `_pulse_start_managed`, `_pulse_reconcile_defers_to_cycle_boundary` and the start path (`pulse-lifecycle-helper.sh:929`, `:937`) call these functions; their output is unchanged.
- **Writers/mutation paths:** N/A because the change only alters the SIGPIPE disposition left behind by `_pulse_pids`/`_pulse_pids_sidecar` after a closed consumer; no file, lock or process state is written (searched both function bodies).
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-lifecycle-helper.sh` (`:964-1045` covers emit, Broken-pipe noise suppression and `_pulse_restore_pipe_trap`).
- **Schemas/config:** N/A because no config, schema or environment knob is read or added; the helper's `Env:` header block is unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` into the runtime bundle; no generated copy to regenerate.
- **Migrations/backfills:** N/A because the helper keeps no stored state; evidence: the edited functions only read `pgrep`/`ps` output.
- **Cleanup/rollback paths:** `git revert` of the fix commit restores the unconditional `_pulse_restore_pipe_trap "$_pipe_trap"` calls.

### Implementation Steps

All edits are in `.agents/scripts/pulse-lifecycle-helper.sh`. Each `oldString` occurs only inside `_pulse_pids` (`:703-735`) and `_pulse_pids_sidecar` (`:743-764`) — counts verified at origin/main 6aa2b31d20 — so use `replaceAll` for steps 1–3.

1. Declare the flag in both emitters (2 occurrences, `:704`, `:744`):

   ```text
   oldString: local _pids="" _pid="" _ppid="" _ppid_cmd="" _cmd="" _pipe_trap=""
   newString: local _pids="" _pid="" _ppid="" _ppid_cmd="" _cmd="" _pipe_trap="" _consumer_closed=0
   ```

2. Record a closed consumer (3 occurrences, `:721`, `:731`, `:759`):

   ```text
   oldString: _pulse_emit_pid "$_pid" || break
   newString: _pulse_emit_pid "$_pid" || { _consumer_closed=1; break; }
   ```

3. Restore the caller's trap only when the loop completed (2 occurrences, `:733`, `:762`):

   ```text
   oldString: _pulse_restore_pipe_trap "$_pipe_trap"
   newString: [[ "$_consumer_closed" -eq 1 ]] || _pulse_restore_pipe_trap "$_pipe_trap"
   ```

4. Update the `_pulse_emit_pid` comment (`:641-644`, single occurrence):

   ```text
   oldString:
   # stderr output unless stderr is suppressed at the emit site. Callers ignore
   # SIGPIPE for the full emit loop and restore the prior trap afterwards; return 1
   # to tell the caller to stop emitting without treating the closed pipe as
   # discovery failure.
   newString:
   # stderr output unless stderr is suppressed at the emit site. Callers ignore
   # SIGPIPE for the emit loop and restore the prior trap only when the loop
   # completes. After a closed consumer they leave SIGPIPE ignored: bash 3.2
   # printf keeps the failed write in its stdio buffer and flushes it at exit, so
   # the default disposition would kill the producer with status 141. Return 1 to
   # tell the caller to stop emitting without treating the closed pipe as
   # discovery failure.
   ```

5. Run the Verification Before Dispatch commands below; `/bin/bash` must report 59/59.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the change is confined to one process's signal disposition after its consumer exits; no locks, shared files or other processes are involved.
- **Migration/rollback:** no ordering concerns; reverting restores the unconditional restore, which only re-exposes the bash 3.2 exit status 141.
- **Mixed-version/backward compatibility:** output, return codes and `_pulse_restore_pipe_trap` behaviour are unchanged for completed loops and on bash 5. When an emitter runs in the current shell (not a pipeline or command substitution) and stdout closes, SIGPIPE now stays ignored for the rest of that shell, so later writes fail with EPIPE instead of killing it; the consumer is already gone then.
- **Idempotency/retry:** each call re-reads `trap -p PIPE` and sets its own disposition, so repeated or retried calls behave the same.
- **Partial failure/recovery:** an emitter interrupted mid-loop leaves SIGPIPE ignored, which is the state that lets its process exit 0; nothing needs cleanup.

### Complexity Impact

- **Target functions:** `_pulse_pids` (33 lines) and `_pulse_pids_sidecar` (22 lines) in `.agents/scripts/pulse-lifecycle-helper.sh`.
- **Lines added:** 0 net — each edit changes an existing line in place.
- **Projected totals:** 33 and 22 lines, well under the 80-line warning and 100-line gate.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh
bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh
/bin/bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh
```

- **Surface mapping:** the failing check sources the helper into the test shell, so running the suite with macOS `/bin/bash` exercises `_pulse_pids` under 3.2.57.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change `_pulse_restore_pipe_trap`, `_pulse_emit_pid`'s return contract, PID selection, or the tests' expectations.

**Not in scope (follow-up):** other scripts that use a similar ignore/restore SIGPIPE pattern.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/pulse-lifecycle-helper.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] Under macOS `/bin/bash` 3.2.57 the lifecycle suite passes 59/59, including `_pulse_pids exits 0 when consumer closes early`.

  ```yaml
  verify:
    method: bash
    run: "/bin/bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh"
  ```

- [ ] Both emitters skip the trap restore only after a closed consumer.

  ```yaml
  verify:
    method: codebase
    pattern: "_consumer_closed\" -eq 1 \\]\\] \\|\\| _pulse_restore_pipe_trap"
    path: ".agents/scripts/pulse-lifecycle-helper.sh"
  ```

- [ ] Under bash 5 the suite still passes, including both `_pulse_restore_pipe_trap` checks.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-lifecycle-helper.sh"
  ```

- [ ] ShellCheck reports no findings for the changed file.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/pulse-lifecycle-helper.sh"
  ```
