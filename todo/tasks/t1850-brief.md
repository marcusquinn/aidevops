---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1850: Fix /runners dispatch pattern blocking in agent Bash tool

## Origin

- **Created:** 2026-04-02
- **Session:** opencode:gemini-3-flash
- **Created by:** ai-interactive
- **Conversation context:** Issue #15403 reports that `cmd_run()` in `headless-runtime-helper.sh` blocks the agent's Bash tool because its `stderr` is not detached when backgrounded.

## What

1. Update `scripts/commands/runners.md` to include redirection in the dispatch examples.
2. Add a `--detach` flag to `cmd_run()` in `.agents/scripts/headless-runtime-helper.sh` that self-daemonizes the process.

## Why

The current dispatch pattern blocks the interactive session for the worker's entire runtime (10-30 minutes), making the agent appear stuck.

## How (Approach)

1. Modify `scripts/commands/runners.md` to use `</dev/null >>/tmp/worker-${session_key}.log 2>&1 &`.
2. Modify `.agents/scripts/headless-runtime-helper.sh`:
   - Add `--detach` to `_parse_run_args`.
   - In `cmd_run()`, if `detach` is true, fork the process and return the child PID.
   - Use `setsid` or double-fork if necessary to fully detach.

## Acceptance Criteria

- [ ] `scripts/commands/runners.md` updated with redirected dispatch examples.
  ```yaml
  verify:
    method: codebase
    pattern: "</dev/null >>/tmp/worker-\$\{session_key\}.log 2>&1 &"
    path: "scripts/commands/runners.md"
  ```
- [ ] `headless-runtime-helper.sh run --detach` returns immediately with the child PID.
  ```yaml
  verify:
    method: bash
    run: "./.agents/scripts/headless-runtime-helper.sh run --detach --role worker --session-key test-detach --dir . --title 'Test' --prompt 'echo test' | grep 'Dispatched PID:'"
  ```
- [ ] The detached worker continues to run in the background.
  ```yaml
  verify:
    method: bash
    run: "pid=$(./.agents/scripts/headless-runtime-helper.sh run --detach --role worker --session-key test-bg --dir . --title 'Test' --prompt 'sleep 5' | awk '{print $NF}'); ps -p $pid >/dev/null"
  ```
- [ ] Tests pass (`./.agents/scripts/linters-local.sh`)
- [ ] Lint clean (`shellcheck .agents/scripts/headless-runtime-helper.sh`)

## Relevant Files

- `.agents/scripts/headless-runtime-helper.sh:1816` — `cmd_run()` implementation
- `scripts/commands/runners.md` — dispatch documentation

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Analyze `cmd_run` and `_parse_run_args` |
| Implementation | 1h | Add `--detach` and update docs |
| Testing | 30m | Verify detachment and backgrounding |
| **Total** | **1h 45m** | |
