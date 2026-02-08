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

## Quick Reference

- **Start**: `objective-runner-helper.sh start "objective" [options]`
- **Status**: `objective-runner-helper.sh status <id>`
- **Pause**: `objective-runner-helper.sh pause <id>`
- **Resume**: `objective-runner-helper.sh resume <id>`
- **Rollback**: `objective-runner-helper.sh rollback <id>`
- **Audit**: `objective-runner-helper.sh audit <id> [--tail N]`
- **List**: `objective-runner-helper.sh list [--state running|paused|complete|failed]`
- **Directory**: `~/.aidevops/.agent-workspace/objectives/`

<!-- AI-CONTEXT-END -->

## What It Does

The objective runner executes open-ended, long-running objectives with configurable safety guardrails. Unlike runners (single-shot) or the Ralph loop (iteration-limited), the objective runner adds budget tracking, scope constraints, checkpoint reviews, and rollback capability.

## When to Use

| Scenario | Tool |
|----------|------|
| Single task, quick result | `runner-helper.sh` |
| Feature implementation with PR | `/full-loop` |
| Batch of independent tasks | `supervisor-helper.sh` |
| **Open-ended goal with safety needs** | **`objective-runner-helper.sh`** |

Use the objective runner when:

- The goal is open-ended (e.g., "improve coverage to 80%", "refactor all legacy modules")
- You need cost/token budget enforcement
- You want periodic human checkpoints
- You need the ability to rollback all changes
- You want a full audit trail of every action

## Safety Guardrails

### 1. Budget Limits

Cap total tokens and estimated cost per objective.

```bash
objective-runner-helper.sh start "Fix all linting errors" \
  --max-tokens 200000 \
  --max-cost 2.00
```

When a limit is reached, the objective pauses (not fails) so you can review progress and decide whether to increase the limit.

### 2. Step Limits

Maximum iterations before the objective must stop.

```bash
objective-runner-helper.sh start "Optimize database queries" \
  --max-steps 30
```

Default: 50 steps. Each step is one AI dispatch cycle.

### 3. Scope Constraints

Restrict which paths and tools the AI can access.

```bash
objective-runner-helper.sh start "Refactor auth module" \
  --allowed-paths "src/auth,tests/auth,docs/auth" \
  --allowed-tools "read,edit,bash,grep"
```

The AI receives these constraints as instructions in its prompt. Violations are detectable in the audit log.

### 4. Checkpoint Reviews

Pause for human approval every N steps.

```bash
objective-runner-helper.sh start "Migrate to new API" \
  --checkpoint-every 5
```

At each checkpoint, the objective pauses. Review progress with `status` and `audit`, then `resume` to continue.

### 5. Rollback

One-command undo of all changes. Works best with git worktrees.

```bash
# If things went wrong
objective-runner-helper.sh rollback obj-20260208-143022-12345
```

For worktrees: removes the worktree and branch entirely.
For main repo: resets uncommitted changes (`git checkout -- .`).

### 6. Audit Log

Every action is logged with timestamps to `audit.log`.

```bash
objective-runner-helper.sh audit obj-20260208-143022-12345 --tail 100
```

Audit entries include: start/stop events, guardrail hits, step dispatches with duration/tokens/cost, completion signals, and rollback actions.

## Architecture

```text
objective-runner-helper.sh
    |
    v
+-------------------+
| Coordinator Loop  |  (stateless, bash-only)
|                   |
| For each step:    |
|  1. Check guards  |  <-- budget, steps, checkpoint
|  2. Build prompt  |  <-- scope constraints injected
|  3. Dispatch AI   |  <-- opencode run
|  4. Parse output  |  <-- completion signals
|  5. Update state  |  <-- tokens, cost, step count
|  6. Audit log     |  <-- every action recorded
+-------------------+
    |
    v
~/.aidevops/.agent-workspace/objectives/<id>/
    ├── config.json   # Guardrail configuration
    ├── state.json    # Progress tracking
    ├── audit.log     # Full audit trail
    └── runs/         # Per-step output logs
```

## Examples

```bash
# Simple objective with defaults (50 steps, $5 budget)
objective-runner-helper.sh start "Improve test coverage to 80%"

# Constrained objective with checkpoints every 5 steps
objective-runner-helper.sh start "Refactor auth module" \
  --max-steps 20 \
  --checkpoint-every 5 \
  --max-cost 2.00 \
  --allowed-paths "src/auth,tests/auth"

# Preview without executing
objective-runner-helper.sh start "Fix all linting errors" --dry-run

# Monitor progress
objective-runner-helper.sh status obj-20260208-143022-12345
objective-runner-helper.sh list --state running

# Review audit trail
objective-runner-helper.sh audit obj-20260208-143022-12345

# Rollback if needed
objective-runner-helper.sh rollback obj-20260208-143022-12345
```

## Integration

| System | How |
|--------|-----|
| **Runners** | `--runner name` uses an existing runner's AGENTS.md identity |
| **Supervisor** | Supervisor can dispatch objectives as tasks |
| **Memory** | Start/complete events stored automatically |
| **Cron** | Schedule periodic objectives via `cron-helper.sh` |
| **Git** | Worktree isolation for safe rollback |

## Completion Signals

The AI is instructed to emit these signals:

| Signal | Meaning |
|--------|---------|
| `<promise>OBJECTIVE_COMPLETE</promise>` | Goal achieved |
| `<promise>OBJECTIVE_BLOCKED</promise>` | Needs human input |

If neither signal is emitted, the loop continues to the next step (until guardrails trigger).

## Related

- `scripts/runner-helper.sh` - Single-shot named agents
- `scripts/supervisor-helper.sh` - Batch task orchestration
- `tools/context/context-guardrails.md` - Context budget management
- `workflows/plans.md` - Task planning and tracking
