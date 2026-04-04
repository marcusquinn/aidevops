<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1398: Fix Runaway Memory Consumption

## Session Origin

Interactive session, 2026-03-05. User reported increased memory pressure and linked PR #2792 (external contributor memory pressure monitor). Root-cause analysis performed live, identifying three distinct sources of excessive RAM consumption caused by aidevops itself.

## What

Fix the three root causes of runaway memory consumption that caused the March 3 kernel panic and ongoing memory pressure:

1. Process resource guards for child processes (shellcheck, node, etc.)
2. Hardened ShellCheck invocation to prevent exponential expansion
3. Pulse self-watchdog for idle timeout
4. Session count awareness warning
5. Rewritten memory pressure monitor targeting the right signals

## Why

March 3 kernel panic: 46 swap files, 100% compressor segment limit, watchdog timeout after 94 seconds. System had no early warning and no resource limits on spawned processes. The problem is ongoing — at time of analysis, a single shellcheck process was consuming 5.7 GB RAM and 88% CPU for 35+ minutes, with 37 opencode processes totalling 2.5 GB.

## How

### Files to modify

- `.agents/scripts/pulse-wrapper.sh` — add `cleanup_runaway_processes()`, pulse self-watchdog
- `.agents/scripts/linters-local.sh` (or wherever shellcheck is invoked) — harden invocation
- `.agents/scripts/pre-edit-check.sh` — add session count warning
- `.agents/scripts/memory-pressure-monitor.sh` — new file, rewritten from PR #2792 concept

### Implementation approach

- **t1398.1:** Add function to pulse-wrapper.sh that iterates child processes, checks RSS via `ps -o rss=`, kills any exceeding `PROCESS_RSS_LIMIT_KB` (default 2097152 = 2 GB). Add runtime check for specific processes (shellcheck > 600s). Call from `run_pulse()` and `check_dedup()`.
- **t1398.2:** Find all shellcheck invocations. Remove `--external-sources` or replace with per-file invocation with `timeout 120`. Restrict `--source-path` to prevent recursive expansion.
- **t1398.3:** In `run_pulse()`, after `wait "$opencode_pid"`, add a background watchdog that monitors the opencode process for idle state (no CPU usage for >5 min) and kills it.
- **t1398.4:** In pre-edit-check.sh, count `ps aux | grep opencode | grep -v grep | wc -l`. If >5, print warning.
- **t1398.5:** New memory-pressure-monitor.sh that monitors: process count by name, individual process RSS, process runtime. Uses kern.memorystatus_level as secondary signal with threshold at 10% (not 40%). Keeps launchd integration and notification concepts from PR #2792.

## Acceptance Criteria

- [ ] No single child process can exceed 2 GB RSS without being killed
- [ ] ShellCheck cannot run for more than 2 minutes per invocation
- [ ] Zombie pulse processes self-terminate after idle timeout
- [ ] User warned when >5 concurrent interactive sessions detected
- [ ] Memory monitor tracks process-level metrics, not just OS-level pressure
- [ ] All scripts pass ShellCheck
- [ ] Existing pulse-wrapper.sh tests still pass

## Context

- PR #2792 declined — wrong signals, security issues, contributor unresponsive
- pulse-wrapper.sh already has `_kill_tree()`, `_get_process_age()`, `PULSE_STALE_THRESHOLD` — extend these patterns
- March 3 kernel panic log referenced in PR #2792 body
- Issue: GH#2854
