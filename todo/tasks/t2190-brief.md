---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2190: Linux worker launch failure — self-diagnose and fix

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive (marcusquinn)
- **Created by:** marcusquinn (human-directed AI-interactive)
- **Parent task:** none
- **Conversation context:** Marcus noticed workers weren't self-assigning on alex-solovyev's Linux machine. Investigation of GH#19664 timeline showed self-assignment *is* working, but gets reverted by `recover_failed_launch_state` within ~45s because `has_worker_for_repo_issue` can't find the worker process after dispatch. Alex is offline and on Linux; marcus can't access his machine. This task is briefed for alex's worker to self-diagnose when his pulse picks it up.

## What

Diagnose why, on alex-solovyev's Linux host, dispatched workers self-assign successfully but then exit before `check_worker_launch` can see them running (within `PULSE_LAUNCH_GRACE_SECONDS=35`). Produce one of:

- **Outcome B — PR with fix:** If root cause is identifiable and fix is obvious, commit the fix and open a PR with `Resolves #19678`. Example fixes: bug in `list_active_workers.awk` process matching on Linux, Node-wrapper ITIMER issue extended from canary to dispatch, env var missing on Linux, auth path mismatch, etc.
- **Outcome C — findings report + recommendation:** If root cause is identifiable but the fix is architectural / cross-platform / breaking, post a decision comment on #19678 with premise check, analysis, recommended path, and specific question for marcus. Apply `needs-maintainer-review`. Do NOT do this for ambiguity about style or scope — only genuine architectural trade-offs.

Outcome A (premise falsified) is unlikely here — the timeline evidence on GH#19664 is unambiguous (see below) — but if the worker finds the symptom no longer reproduces after `aidevops update`, that is a valid Outcome A close with a comment citing current pulse log and `ps` output showing workers running healthily.

## Why

Alex's contributor dashboard (#18669, last pulse 2026-04-17T14:47:04Z) shows:

```
| Active Workers | 0    |
| Max Workers    | 3    |
| Worktrees      | 42   |
```

Every pulse cycle: dispatches a worker → creates worktree → self-assigns → posts DISPATCH_CLAIM + ops comment → worker dies silently → 35s grace elapses → `recover_failed_launch_state` unassigns + sets `status:available` → next cycle tries the same issue again. Worktrees accumulate (42 and growing), no work gets done, marcus's pulse duplicates effort after the 30-min DISPATCH_CLAIM TTL. This blocks all auto-dispatch throughput from alex's machine and is the root cause behind the misleading "workers don't self-assign anymore" symptom.

PR #19627 (merged 2026-04-18 00:57Z) fixed a *related* Linux-only bug in `_run_canary_test` where `perl -e "alarm N; exec @ARGV"` couldn't reap the Go grandchild spawned by opencode's Node.js npm wrapper (`ITIMER_REAL` not inherited across `spawnSync`). That fix only touched the canary path. The real worker dispatch in `_dlw_nohup_launch` and `headless-runtime-helper.sh run` may have a structurally similar failure on Linux — or it may be something entirely different. Investigation is needed.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? — **No** (fix scope unknown until diagnosis complete)
- [ ] Every target file under 500 lines? — **No** (several candidate files >500 lines)
- [ ] Exact `oldString`/`newString` for every edit? — **No** (this is a diagnostic task)
- [ ] No judgment or design decisions? — **No** (root cause analysis is judgment-heavy)
- [ ] No error handling or fallback logic to design? — **No** (likely involves process-tree timeout fallback ladders)
- [ ] No cross-package or cross-module changes? — **Possibly no** (may touch headless-runtime + pulse-dispatch + worker-lifecycle)
- [ ] Estimate 1h or less? — **No** (diagnosis + fix likely 2-4h)
- [ ] 4 or fewer acceptance criteria? — **Yes**

**Selected tier:** `tier:thinking`

**Tier rationale:** Unknown root cause, Linux-specific environmental bug, requires reading logs + process trees + comparing to macOS, potentially cross-module fix. Opus-level reasoning is justified — Sonnet is likely to pattern-match to "add more logging" or "raise the grace timeout" without reaching the actual cause.

## PR Conventions

Leaf (non-parent) issue. Use `Resolves #19678` in the PR body.

## How (Approach)

### Worker Quick-Start

```bash
# 1. The symptom you are reproducing (do this FIRST before changing anything):
#    Observe a real dispatch cycle and confirm the worker dies within 35s.
tail -f ~/.aidevops/logs/pulse-wrapper.log &
# Wait for the next pulse cycle to dispatch something, then:
grep -E "Dispatched worker PID|Launch validation failed|no_worker_process|cli_usage_output|Dispatching worker" \
    ~/.aidevops/logs/pulse-wrapper.log | tail -30

# 2. For the most recent dispatched issue, look at the worker's own log:
safe_slug="marcusquinn-aidevops"  # or whatever repo
latest_issue=$(grep -oE "Dispatched worker PID [0-9]+ for #[0-9]+" \
    ~/.aidevops/logs/pulse-wrapper.log | tail -1 | grep -oE "#[0-9]+" | tr -d '#')
cat /tmp/pulse-${safe_slug}-${latest_issue}.log

# 3. Catch the worker in the act: dispatch a manual worker and watch its process tree
#    (only do this if the live observation in step 1 didn't give a clear cause)
```

### Files to Modify

This is investigative. Likely candidates by probability:

- `EDIT: .agents/scripts/headless-runtime-lib.sh` — if the Node/Go ITIMER pattern from canary (PR #19627) also affects the real worker launch path, the fix is to extend the `timeout(1)/gtimeout/perl-alarm` ladder from `_run_canary_test` to wherever `opencode run` is invoked in the worker path.
- `EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh:354` (`_dlw_nohup_launch`) — if the `nohup env ... helper.sh run ...` invocation doesn't survive Linux's job control the same way it does on macOS.
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:105` (`has_worker_for_repo_issue`) / `.agents/scripts/list_active_workers.awk` — if the detection logic misses Linux-specific `ps` output (e.g., `ps axo command` column truncation when stdout is a pipe, different cmdline format for `nohup env`-wrapped processes).
- `EDIT: .agents/scripts/worker-lifecycle-common.sh:730` (`list_active_worker_processes`) — if `ps axo pid,stat,etime,command` truncates on Linux without `-w`.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh:60` (`check_worker_launch`) — only touch as a last resort if the detection is correct and the worker really does need a different grace window or a more robust liveness signal than pgrep.

Only touch files that the diagnosis justifies. Do **not** blindly raise `PULSE_LAUNCH_GRACE_SECONDS` — that would hide the bug, not fix it.

### Implementation Steps

**Phase 1 — diagnose (do not edit anything yet):**

1. **Confirm the symptom is still present:**

   ```bash
   # If you're reading this, your pulse dispatched you. First check pulse log:
   grep -E "Launch validation failed for issue #19678|no_worker_process.*19678|Dispatched worker PID.*#19678" \
       ~/.aidevops/logs/pulse-wrapper.log | tail -10
   ```

   If your own dispatch for this very task shows `Launch validation failed` + `no_worker_process` in the pulse log — congratulations, the bug is reproducing against YOU. Your worker log at `/tmp/pulse-marcusquinn-aidevops-19678.log` is the freshest evidence available. Prioritise reading that over anything else.

2. **Read the most recent failing worker log fully:**

   ```bash
   # Find the most recent Launch validation failed and get its log
   latest_fail_issue=$(grep -oE "Launch validation failed for issue #[0-9]+" \
       ~/.aidevops/logs/pulse-wrapper.log | tail -1 | grep -oE "#[0-9]+" | tr -d '#')
   ls -la /tmp/pulse-*-${latest_fail_issue}.log
   cat /tmp/pulse-*-${latest_fail_issue}.log  # or use Read tool
   ```

   Classification the log content drives:
   - `opencode run [message..]`, `run opencode with a message`, or `Options:` text → `cli_usage_output` path. Something is calling `opencode` without the expected args. Check `HEADLESS_RUNTIME_HELPER` resolution, `--prompt` argument quoting, `--dir` validity.
   - Empty or tiny (< 500 bytes) → process died during bootstrap. Look for auth failure, missing binary, PATH issue, node version mismatch.
   - Stack trace from bash / node / go → read the trace, that's the cause.
   - Normal-looking output that cuts off mid-sentence → worker got SIGKILLed. Check OOM killer (`dmesg | grep -i killed | tail`), systemd memory limits (`systemctl --user show aidevops-supervisor-pulse.service | grep Memory`).

3. **Capture the actual process tree of a freshly dispatched worker:**

   Use the `WORKER_ISSUE_NUMBER` env var to find just-dispatched workers — it's unique per dispatch and easier to grep than the path:

   ```bash
   # Watch for a new dispatch (runs in a separate terminal):
   watch -n 2 'ps -eo pid,ppid,stat,etime,cmd | grep -E "WORKER_ISSUE_NUMBER|headless-runtime-helper.sh|opencode" | grep -v grep'
   # When a pulse cycle dispatches a worker, observe:
   #   a) what processes appear
   #   b) which ones exit first (PID disappears)
   #   c) what the surviving process tree looks like at t+10s, t+30s, t+60s
   ```

   Compare what survives to what the awk regex in `.agents/scripts/list_active_workers.awk` requires:

   ```awk
   is_headless_wrapper = (cmdline ~ /headless-runtime-helper\.sh/ && cmdline ~ / run / && cmdline ~ /--role[[:space:]]+worker/)
   has_worker_binary   = (cmdline ~ /opencode/ || cmdline ~ /headless-runtime-helper\.sh/)
   has_worker_prompt   = (cmdline ~ /\/full-loop/ || cmdline ~ /\/review-issue-pr/)
   # Must match: (is_headless_wrapper OR has_worker_prompt) AND has_worker_binary AND NOT zombie/stopped
   ```

   If a running process exists but the awk doesn't match it → detection bug (likely column truncation). If no process exists at all → launch bug.

4. **Check the procps version and `ps` cmdline-truncation behavior on this host:**

   ```bash
   ps --version
   # Pipe a known-long command line through ps and see if it's truncated:
   ps axo pid,stat,etime,command | awk '{ print length($0), $0 }' | sort -nr | head -5
   ```

   If procps truncates to ~80 columns when stdout is a pipe, `has_worker_for_repo_issue` may be matching against a truncated command line that no longer contains `--session-key` or `--role worker`. The fix is to force `-ww` (unlimited width) in `list_active_worker_processes`.

5. **Verify PR #19627 is actually deployed on this host:**

   ```bash
   grep -c "gtimeout\|timeout --kill-after" ~/.aidevops/agents/scripts/headless-runtime-lib.sh
   # Should return 2+ if the canary fix is deployed. 0 = auto-update hasn't pulled it; run `aidevops update`.
   ```

   Also check the last auto-update timestamp and the deployed version vs current main:

   ```bash
   cat ~/.aidevops/agents/VERSION
   cat /Users/alexey/Git/aidevops/.agents/VERSION  # or wherever the source checkout lives
   ```

   If deployed < source, run `aidevops update` and re-test. The canary fix being missing would not directly cause `no_worker_process` on the real dispatch path, but it indicates that whatever general process-tree-orphaning pattern exists on Linux will affect the worker launch too — and the investigation should look for an analogous bug in the real path.

**Phase 2 — propose fix based on what Phase 1 revealed:**

Common cause → fix mapping (choose based on evidence, don't guess):

- **Cause: Node npm-wrapper opencode spawnSync orphans Go child on launch too.** Symptom: worker log shows normal startup then silence; `.opencode` (Go) processes accumulate in the pulse service cgroup. Fix: apply the same `timeout(1) --kill-after=5s` wrapper from `_run_canary_test` to the real worker invocation in `headless-runtime-helper.sh run` path, OR switch to installing `opencode` via the native distribution instead of npm.

- **Cause: `ps` command-column truncation.** Symptom: worker process visible with `pgrep -af opencode` but `has_worker_for_repo_issue` returns false. Fix: add `-ww` to `ps axo ...` in `list_active_worker_processes` (`worker-lifecycle-common.sh:735`).

- **Cause: `nohup env ... helper.sh run ...` doesn't survive pulse-wrapper exit on Linux.** Symptom: worker visible briefly during the pulse cycle, disappears when pulse exits. Fix: wrap in `setsid nohup ...` or use `systemd-run --user --scope` to detach fully.

- **Cause: auth token missing in worker env.** Symptom: log shows 401 / auth error. Fix: ensure the relevant env vars propagate through `nohup env ...` invocation (many env vars are stripped by `env` unless explicitly passed).

- **Cause: OOM kill.** Symptom: dmesg shows `Out of memory: Killed process NNNN (opencode)`. Fix: reduce worker concurrency cap via `MAX_WORKERS_TARGET` or add systemd memory headroom. This is an Outcome C (escalation to marcus) — architectural decision about resource sizing.

Write a commit per fix — don't bundle unrelated changes.

### Verification

Replace the tests block below with the specific verifier for the fix you land.

```bash
# Regression guard A — launch detection doesn't false-negative on Linux
# (applies if fix is in list_active_workers.awk or ps cmdline handling)
bash .agents/scripts/tests/test-pulse-wrapper-worker-count.sh

# Regression guard B — dispatch flow still passes its full suite
bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh

# End-to-end smoke: after landing the fix and running `aidevops update`,
# confirm the next pulse cycle's worker survives >60s and check_worker_launch
# finds it. Expected log pattern:
#   [pulse-wrapper] Dispatched worker PID NNN for #MMM in ...
#   (no "Launch validation failed" for that issue within 60s)
#   [pulse-wrapper] ... (normal worker progress after 60s)
tail -f ~/.aidevops/logs/pulse-wrapper.log | grep -E "Dispatched worker|Launch validation"
```

## Acceptance Criteria

- [ ] Root cause of `no_worker_process` on Linux is identified in the PR description or the Outcome C comment. Not "might be", not "probably" — a concrete cause with log evidence, process-tree snapshot, or reproducer command attached.
  ```yaml
  verify:
    method: manual
    prompt: "Does the PR body or closing comment name a specific root cause with evidence?"
  ```
- [ ] Either a fix PR is open linking `Resolves #19678`, OR a decision comment with recommended path is posted on #19678 with `needs-maintainer-review` applied.
  ```yaml
  verify:
    method: bash
    run: "gh pr list --repo marcusquinn/aidevops --search 'Resolves #19678' --state all --json number --jq 'length > 0' | grep -q true || gh issue view 19678 --repo marcusquinn/aidevops --json labels --jq '.labels[] | .name' | grep -q needs-maintainer-review"
  ```
- [ ] After fix lands (or recommendation is implemented), a new pulse cycle on the Linux host dispatches a worker that survives >60s with no `Launch validation failed` entry for its issue.
  ```yaml
  verify:
    method: manual
    prompt: "Run a pulse cycle on Linux, confirm next dispatched worker's PID is still alive 60s after dispatch and no recovery fired. Post a comment on #19678 with log excerpt."
  ```
- [ ] `shellcheck` passes on any modified `.sh` files.
  ```yaml
  verify:
    method: bash
    run: "find .agents/scripts/ -name '*.sh' -newer .agents/VERSION -exec shellcheck {} +"
  ```

## Context & Decisions

- **Why this is dispatched to alex-solovyev specifically:** The bug is environment-specific to alex's Linux host (process-tree behavior, possibly opencode install variant, possibly systemd service envs). A worker on marcus's macOS cannot reproduce it. We assign the issue to `alex-solovyev` so the non-self-assignee dedup rule blocks marcus's pulse from picking it up while alex's pulse can self-dispatch on it.
- **Why tier:thinking rather than tier:standard:** The symptom has multiple plausible root causes (npm-wrapper orphaning, `ps` truncation, nohup detachment, auth env, OOM). Sonnet is likely to pattern-match to the first candidate without weighing evidence; Opus should read the logs, weigh causes, and pick the right fix. False confidence here costs worktree accumulation and blocks unblocking.
- **Chicken-and-egg risk:** This task is meant to be run by a worker on the very host where workers are failing. If your launch also fails, marcus will pick up the residual symptom manually when alex is back online. That is an acceptable fallback — don't panic if the task goes `status:queued → status:available` a few times. Cross-runner dispatch TTL is 1800s; marcus's pulse won't steal this from alex until that expires AND alex's assignment is removed.
- **What NOT to do:**
  - Do not raise `PULSE_LAUNCH_GRACE_SECONDS` beyond 60s as a "fix" — that hides the bug.
  - Do not disable `recover_failed_launch_state` — it is load-bearing for actual orphan recovery.
  - Do not delete orphaned worktrees to "clean up" without first diagnosing. `worktree-helper.sh clean --auto --force-merged` is appropriate AFTER fix lands.

## Relevant Files

- `.agents/scripts/pulse-dispatch-worker-launch.sh:354` — `_dlw_nohup_launch` builds and runs the worker command
- `.agents/scripts/pulse-dispatch-engine.sh:60` — `check_worker_launch` polls for worker appearance, fires recovery if not found
- `.agents/scripts/pulse-dispatch-core.sh:105` — `has_worker_for_repo_issue` matches against ps output
- `.agents/scripts/list_active_workers.awk` — awk rules for worker process detection
- `.agents/scripts/worker-lifecycle-common.sh:730` — `list_active_worker_processes` invokes `ps axo pid,stat,etime,command`
- `.agents/scripts/pulse-cleanup.sh:668` — `recover_failed_launch_state` unassigns and resets status when launch fails
- `.agents/scripts/headless-runtime-lib.sh:~1500` — canary timeout ladder (reference pattern for dispatch-path fix if Node/Go ITIMER is the cause)
- GH#19664 — exemplar timeline showing self-assign + 45s-later revert on alex's host
- GH#19623 / PR #19627 — related Linux-only canary bug (fixed)
- GH#18669 — alex's contributor health dashboard showing 0 workers / 42 worktrees

## Dependencies

- **Blocked by:** none (all information needed is on-host)
- **Blocks:** all auto-dispatch throughput from alex's Linux host; orphan worktree accumulation; marcus/alex pulse duplicate dispatches
- **External:** access to alex-solovyev's Linux host (implicit — the worker runs there)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Phase 1 diagnose | 30-60m | Read logs, capture process tree, classify failure type |
| Phase 2 fix | 30m-2h | Scope depends on root cause — awk/ps fix is 15m, Node-wrapper timeout ladder is ~1h |
| Testing | 30m | Regression tests + live pulse cycle verification |
| **Total** | **1.5-3.5h** | |

<!-- Reading budget: Phase 1 may read ~3,000 lines across pulse-dispatch-worker-launch.sh,
     pulse-dispatch-engine.sh, worker-lifecycle-common.sh, list_active_workers.awk,
     and headless-runtime-lib.sh. Tier:thinking is justified by synthesis across files. -->
