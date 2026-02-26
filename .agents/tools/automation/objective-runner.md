---
description: Long-running objective execution with safety guardrails
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: true
---

# @objective-runner - Safe Long-Running Objectives

<!-- AI-CONTEXT-START -->

> **ARCHIVED (t1336):** `objective-runner-helper.sh` has been archived to `scripts/archived/`.
> Use `/full-loop` instead — it provides the same iterative execution with AI judgment
> rather than deterministic bash guardrails.

## Quick Reference

- **Use instead**: `/full-loop "objective description"` for iterative task execution
- **Runner dispatch**: `runner-helper.sh` for single-shot named agents
- **Batch tasks**: `supervisor-helper.sh` for multi-task orchestration
- **Archived script**: `scripts/archived/objective-runner-helper.sh` (1,334 lines, reference only)

<!-- AI-CONTEXT-END -->

## Why Archived

The objective runner was a bash-based loop with deterministic guardrails (budget limits,
step counts, checkpoint reviews, rollback). `/full-loop` replaces this with AI-guided
iteration that makes better decisions about when to stop, retry, or escalate.

See `scripts/archived/objective-runner-helper.sh` for the original implementation.

## Related

- `/full-loop` - End-to-end development loop (replacement)
- `scripts/runner-helper.sh` - Single-shot named agents
- `scripts/supervisor-helper.sh` - Batch task orchestration
- `workflows/plans.md` - Task planning and tracking
