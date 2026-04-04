<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1687: Add interactive claim-on-create option to /new-task to prevent pulse dispatch races

## Origin

- **Created:** 2026-03-27
- **Session:** claude-code:t1687-interactive-claim
- **Created by:** human + ai-interactive
- **Conversation context:** User identified a race window where interactively created issues could be picked up by pulse workers before the user starts `/full-loop`. The nonce mechanism (t1686) solves runner-to-runner races but not the interactive-to-pulse gap.

## What

Add a "claim for this session" option to `/new-task` that assigns the current user and sets `status:in-progress` on the GitHub issue at creation time, preventing pulse workers from dispatching for the same issue during the gap between task creation and `/full-loop` startup.

## Why

When a user creates a task via `/new-task` and intends to work on it interactively, there is a window (minutes to hours) where the issue has no assignee and no status label. The pulse sees it as "unassigned, open, no PR" and may dispatch a worker, duplicating work. The existing nonce claim (t1686) solves sub-second races between automated runners but not this wider interactive gap.

## How (Approach)

1. Add option 2 ("claim for this session") to `/new-task` Step 4 presentation — runs `gh issue edit` to set assignee + `status:in-progress` immediately
2. Document idempotency in `/full-loop` Step 0.6 — the same assignee/label calls are no-ops when already set
3. Add a note in `pulse.md` issue triage explaining that claimed-on-create issues are correctly skipped
4. No changes to `dispatch-claim-helper.sh` or `dispatch-dedup-helper.sh` — the existing `is_assigned` check already handles this

Key files:

- `.agents/scripts/commands/new-task.md:64-79` — Step 4 options
- `.agents/scripts/commands/full-loop.md:73-93` — Step 0.6 label update
- `.agents/scripts/commands/pulse.md:252` — status:in-progress skip logic

## Acceptance Criteria

- [ ] `/new-task` Step 4 offers "claim for this session" option with `gh issue edit` assignee + label logic
- [ ] `/full-loop` Step 0.6 documents idempotency with claim-on-create
- [ ] `pulse.md` documents that claimed-on-create issues are correctly skipped
- [ ] Examples updated to show both "queue for dispatch" and "claim for session" flows
- [ ] Default option (1) preserves existing behaviour — no claim, pulse can pick up
- [ ] Lint clean (markdownlint)

## Context & Decisions

- **Rejected: nonce mechanism for interactive sessions** — the nonce (t1686) is designed for sub-second races between automated runners. Interactive gaps are minutes to hours; assignee + label is the right mechanism.
- **Rejected: always claim on create** — sometimes users create tasks to queue for pulse workers. The default must remain "no claim" to preserve this workflow.
- **No script changes needed** — this is purely agent instruction changes. The `gh issue edit` calls are standard GitHub API operations already used in `/full-loop`.

## Relevant Files

- `.agents/scripts/commands/new-task.md` — primary change: Step 4 options + claim logic
- `.agents/scripts/commands/full-loop.md` — idempotency documentation
- `.agents/scripts/commands/pulse.md` — skip logic documentation
- `.agents/scripts/dispatch-dedup-helper.sh:378-425` — `is_assigned()` already handles this
- `.agents/scripts/dispatch-claim-helper.sh` — no changes needed
