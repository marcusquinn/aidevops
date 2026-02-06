# Product Requirements Document: Autonomous Supervisor

<!--TOON:prd{id,feature,author,status,est,est_ai,est_test,est_read,logged}:
prd-autonomous-supervisor,Autonomous Supervisor,Build+,draft,8h,5h,2h,1h,2026-02-06T04:00Z
-->

## Overview

**Feature:** Autonomous Supervisor Loop
**Author:** Build+
**Date:** 2026-02-06
**Status:** Draft
**Estimate:** ~8h (ai:5h test:2h read:1h)

### Problem Statement

aidevops has all the components for autonomous multi-task execution (runners, worktrees, mail, memory, full-loop, cron, Matrix, web research) but no supervisor to tie them together. Tasks are fire-and-forget: if a worker stalls, hits an error, or needs clarification, nobody notices. There is no evaluate-and-re-prompt cycle, no batch orchestration with concurrency control, and no automatic TODO updates on completion or failure.

### Goal

A stateless supervisor pulse that manages long-running parallel objectives from dispatch through completion, with automatic retry, escalation, and self-improvement. Token-efficient: the supervisor itself is bash + SQLite, only invoking AI for evaluation decisions.

## User Stories

### Primary User Story

As a developer, I want to dispatch a batch of tasks (e.g., t083-t094) and have them execute in parallel worktrees with automatic monitoring, retry on failure, and TODO updates on completion, so I can work on other things while objectives complete autonomously.

### Additional User Stories

- As a developer, I want blocked tasks to notify me via Matrix/mail with context about what's needed, so I can unblock them without checking manually.
- As a developer, I want the supervisor to learn from failures (via memory) so the same mistakes aren't repeated across tasks.
- As a developer, I want to add new objectives to TODO.md and have the supervisor pick them up automatically via cron, without running a command.
- As a developer, I want visual Tabby tab dispatch when running in Tabby, and headless dispatch otherwise, detected automatically.

## Functional Requirements

### Core Requirements

1. **Supervisor pulse** (`supervisor-helper.sh pulse`): Stateless bash script that reads state from SQLite, checks worker status, evaluates outcomes, dispatches new work, and exits. Runs via cron every 5 minutes or via fswatch.

2. **Worker lifecycle management**: For each task: create worktree, dispatch `opencode run --format json "/full-loop tXXX"`, monitor JSON log, classify outcome, retry or escalate.

3. **Outcome evaluation**: Parse worker JSON output for completion signals (`FULL_LOOP_COMPLETE`, PR URL), errors, or stalls. Use a cheap AI call (Sonnet, ~30s) for ambiguous outcomes that need reasoning.

4. **Re-prompt on failure**: `opencode run --session <id> --continue "Previous attempt failed with: ... Please fix and retry."` Up to N retries (default 3) before marking blocked.

5. **TODO.md updates**: On completion: add `completed:YYYY-MM-DD`. On block: add `blocked-by:user "reason"`. Commit and push after updates.

6. **Concurrency control**: Semaphore limiting parallel workers (default 4). Queue remaining tasks. Start next when a slot frees.

7. **Worktree isolation**: Each task gets `~/Git/{repo}-feature-{tXXX}/` via `wt switch -c feature/tXXX`. Cleanup after PR merge.

### Secondary Requirements

8. **Matrix/mail escalation**: When a task is blocked, send notification via `mail-helper.sh` and optionally Matrix (`matrix-dispatch-helper.sh`).

9. **Memory integration**: Store failure patterns via `memory-helper.sh --auto`. Before dispatching, recall relevant memories for the task domain.

10. **Dependency awareness**: Respect `blocked-by:` fields in TODO.md. Don't dispatch tasks whose dependencies aren't complete.

11. **Cron auto-pickup**: Tasks tagged with `#auto-dispatch` or in a designated "Dispatch Queue" section of TODO.md get picked up by the supervisor pulse without manual trigger.

12. **Tabby visual mode**: When `$TERM_PROGRAM=Tabby`, dispatch workers as visible tabs. Otherwise headless.

13. **Cross-repo support**: Supervisor manages tasks across multiple repos. Task entries include repo path or are dispatched with explicit project directory.

14. **Self-assessment**: After each batch completes, the supervisor runs a retrospective: what failed, why, what to remember. Stores insights in memory for future batches.

## Non-Goals (Out of Scope)

- Building a new AI model or fine-tuning for evaluation (use existing models via opencode)
- Replacing the full-loop workflow (supervisor wraps it, doesn't replace it)
- GUI dashboard (CLI + Matrix notifications are sufficient)
- Multi-machine distribution (single machine, multiple worktrees)

## Technical Considerations

### Architecture

```
supervisor-helper.sh (bash, stateless pulse)
    ├── State: SQLite (supervisor.db) - task queue, worker status, retry counts
    ├── Workers: opencode run in worktrees (JSON output to log files)
    ├── Evaluation: opencode run --model sonnet (cheap, short) for ambiguous outcomes
    ├── Communication: mail-helper.sh + matrix-dispatch-helper.sh
    ├── Memory: memory-helper.sh for cross-batch learning
    ├── Git: wt/worktree-helper.sh for isolation
    └── Trigger: cron (*/5) or fswatch on TODO.md
```

### State Schema (SQLite)

```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,           -- t083
    repo TEXT NOT NULL,            -- /Users/x/Git/aidevops
    description TEXT,
    status TEXT DEFAULT 'queued',  -- queued|dispatched|running|evaluating|retrying|complete|blocked|failed
    session_id TEXT,               -- opencode session ID
    worktree TEXT,                 -- worktree path
    log_file TEXT,                 -- JSON log path
    retries INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    model TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error TEXT,                    -- last error/block reason
    created_at TEXT,
    started_at TEXT,
    completed_at TEXT,
    pr_url TEXT
);

CREATE TABLE batches (
    id TEXT PRIMARY KEY,
    name TEXT,
    concurrency INTEGER DEFAULT 4,
    status TEXT DEFAULT 'active',  -- active|paused|complete
    created_at TEXT
);

CREATE TABLE batch_tasks (
    batch_id TEXT,
    task_id TEXT,
    FOREIGN KEY (batch_id) REFERENCES batches(id),
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
```

### Dependencies

- `opencode run --format json --session --continue` (confirmed working)
- `wt switch -c` or `worktree-helper.sh add` (confirmed working)
- `mail-helper.sh` (confirmed working)
- `memory-helper.sh` (confirmed working)
- `coordinator-helper.sh` (extend, don't replace)
- `full-loop-helper.sh` (workers use this via `/full-loop`)
- SQLite3 (already used by mail and memory)

### Constraints

- Supervisor pulse must complete in <30 seconds (stateless, no long-running AI calls in the pulse itself)
- Evaluation AI calls are dispatched as background workers, results checked next pulse
- Max token budget per evaluation: ~5K tokens (Sonnet, not Opus)
- Worktree disk usage: monitor and warn if >10 active worktrees

## Testing

- Unit: test supervisor state transitions with mock SQLite data
- Integration: dispatch 2-3 trivial tasks, verify lifecycle
- Stress: dispatch t083-t094 (12 tasks, concurrency 4)
- Failure: simulate worker failure, verify retry and escalation
