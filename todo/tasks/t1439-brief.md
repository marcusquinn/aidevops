<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1439: Fix pulse status last-pulse reporting and honor configured max worker cap

## Origin

- **Created:** 2026-03-11
- **Session:** OpenCode interactive request
- **Created by:** OpenCode gpt-5.4
- **Parent task:** none
- **Conversation context:** The user asked for a tracked aidevops planning task covering a pulse fix where status should report the real last pulse time and worker dispatch should honor the configured max worker limit. The goal is to secure a valid task ID and linked issue so follow-up implementation can use a PR title starting with `t1439:`.

## What

Fix the pulse orchestration path so two related behaviors stay accurate: status output must show the actual last pulse timestamp, and worker scheduling must enforce the configured max worker cap when deciding how many workers can run. The implementation should cover both the user-visible reporting path and the concurrency-control path, with regression checks that prevent the values from drifting apart again.

## Why

- Pulse status currently reports misleading or stale last-pulse information, which makes operators misread whether the scheduler is healthy.
- Pulse worker accounting can ignore the configured ceiling, which risks over-dispatching workers and weakening repo fairness and system safety.
- Both issues affect trust in pulse observability and control, so they should be fixed together under one tracked task.

## How (Approach)

1. Inspect the current pulse status reporting path and identify where the displayed last-pulse value is sourced and formatted.
2. Inspect the worker-cap calculation and dispatch gate to find where configured max workers can be bypassed or misapplied.
3. Update the shared pulse logic so status reporting uses the authoritative last-pulse source and dispatch decisions clamp to the configured worker cap.
4. Add focused regression coverage for both the status output and the max-worker enforcement path.

## Acceptance Criteria

- [ ] Pulse status reports the authoritative last-pulse timestamp instead of stale or incorrect derived data.
- [ ] Pulse dispatch never schedules more workers than the configured max worker cap allows.
- [ ] Regression coverage exists for both the last-pulse reporting path and the max-worker cap enforcement path.

## Context & Decisions

- Keep this as one bugfix task because the reporting bug and the worker-cap bug both live in pulse orchestration behavior and affect operator trust.
- Preserve the standard aidevops planning workflow: atomic task ID first, linked GitHub issue, TODO tracking on main, and a brief for follow-up implementation.
- The future implementation PR should use the repository convention `t1439: ...`.

## Relevant Files

- `.agents/scripts/supervisor-archived/pulse.sh` — likely home of pulse status reporting and dispatch logic.
- `TODO.md` — planning tracker entry for the task.
- `todo/tasks/t1439-brief.md` — implementation brief for the follow-up work.

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | inspect pulse status and worker-cap code paths |
| Implementation | 1h | patch reporting and cap enforcement |
| Testing | 30m | add focused regression checks |
| **Total** | **~2h** | |
