---
description: Quick health check of supervisor batch queue, workers, PRs, and system resources
agent: Build+
mode: subagent
---

Quick diagnostic of the supervisor queue. Shows batch status, stuck tasks, open PRs, and issues.

Arguments: $ARGUMENTS

## Steps

Run these commands in parallel and present a unified report:

```bash
# 1. Active batch status
~/.aidevops/agents/scripts/supervisor-helper.sh status 2>&1

# 2. TODO.md queue analysis (subtask-aware)
# Count ALL open items including subtasks — subtasks are the actual dispatchable units
TODO_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/TODO.md"
if [[ -f "$TODO_FILE" ]]; then
  total_open=$(grep -c '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null || echo 0)
  parent_open=$(grep -c '^- \[ \]' "$TODO_FILE" 2>/dev/null || echo 0)
  subtask_open=$((total_open - parent_open))
  # Dispatchable: open, has #auto-dispatch (or parent does), not blocked, not claimed
  dispatchable=$(grep -E '^[[:space:]]*- \[ \] t[0-9]+' "$TODO_FILE" 2>/dev/null | \
    grep -v 'assignee:\|started:' | \
    grep -v 'blocked-by:' | \
    grep -c '#auto-dispatch' 2>/dev/null || echo 0)
  # Subtasks whose parent has #auto-dispatch (inherited dispatchability)
  # For each open subtask, check if its parent line has #auto-dispatch
  inherited=0
  while IFS= read -r line; do
    task_id=$(echo "$line" | grep -oE 't[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$task_id" ]]; then
      parent_id=$(echo "$task_id" | sed 's/\.[0-9]*$//')
      if grep -qE "^- \[.\] ${parent_id} .*#auto-dispatch" "$TODO_FILE" 2>/dev/null; then
        # Check not blocked or claimed
        if ! echo "$line" | grep -qE 'assignee:|started:'; then
          if ! echo "$line" | grep -qE 'blocked-by:'; then
            inherited=$((inherited + 1))
          fi
        fi
      fi
    fi
  done < <(grep -E '^[[:space:]]+- \[ \] t[0-9]+\.[0-9]+' "$TODO_FILE" 2>/dev/null | grep -v '#auto-dispatch')
  total_dispatchable=$((dispatchable + inherited))
  blocked=$(grep -E '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null | grep -c 'blocked-by:' || echo 0)
  claimed=$(grep -E '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null | grep -cE 'assignee:|started:' || echo 0)
  echo "=== TODO.md Queue ==="
  echo "Total open: $total_open ($parent_open parents, $subtask_open subtasks)"
  echo "Dispatchable: $total_dispatchable (tagged: $dispatchable, inherited: $inherited)"
  echo "Blocked: $blocked"
  echo "Claimed/in-progress: $claimed"
fi

# 3. Open PRs from workers (need merge/review)
gh pr list --state open --json number,title,headRefName,createdAt,statusCheckRollup \
  --jq '.[] | "\(.number) [\(.headRefName)] \(.title) checks:\(.statusCheckRollup | map(.conclusion // .state) | join(","))"' 2>/dev/null

# 4. Active worktrees (worker sessions)
git worktree list 2>/dev/null

# 5. System resources
~/.aidevops/agents/scripts/supervisor-helper.sh db \
  "SELECT id, state, retries FROM tasks WHERE state NOT IN ('deployed','cancelled','failed') ORDER BY state;" 2>/dev/null
```

## Report Format

Present results as a concise dashboard:

### Queue Depth (subtask-aware)

- **Total open**: X (Y parents, Z subtasks) — subtasks are the actual work units
- **Dispatchable now**: N (M tagged #auto-dispatch, K inherited from parent)
- **Blocked**: B (waiting on dependencies)
- **Claimed/in-progress**: C (assigned to workers or interactive sessions)
- Flag if dispatchable count is 0 but open count is high (queue stall)

### Batch Status

- Batch name, total/completed/queued/running/failed counts
- Any tasks stuck in retrying or evaluating for >10 minutes

### Action Items

Flag these for the user (most important first):

1. **PRs ready to merge** — all CI green, no review comments
2. **PRs with CI failures** — need investigation
3. **Tasks stuck** — in retrying/evaluating too long
4. **Tasks at max retries** — need manual intervention or re-queue
5. **Stale worktrees** — for tasks already deployed/merged
6. **Subtasks missing #auto-dispatch** — parent has tag but subtasks don't (dispatch gap)

### System Health

- Load, memory, worker count
- Cron pulse status: `~/.aidevops/agents/scripts/supervisor-helper.sh cron status 2>&1`

## Arguments

- No arguments: check the most recent active batch
- `--batch <id>`: check a specific batch
- `--all`: show all batches including completed
- `--fix`: auto-fix simple issues (merge green PRs, clean stale worktrees, reset stuck tasks)
