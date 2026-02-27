---
description: Quick health check of worker status, PRs, TODO queue, and system resources
agent: Build+
mode: subagent
---

Quick diagnostic of the dispatch system. Shows worker status, open PRs, TODO queue, and worktrees.

Arguments: $ARGUMENTS

## Steps

Run these commands in parallel and present a unified report:

```bash
# 1. Active workers (count opencode /full-loop processes)
MAX_WORKERS=$(cat ~/.aidevops/logs/pulse-max-workers 2>/dev/null || echo 4)
WORKER_COUNT=$(ps axo command | grep '/full-loop' | grep -v grep | wc -l | tr -d ' ')
AVAILABLE=$((MAX_WORKERS - WORKER_COUNT))
echo "=== Worker Status ==="
echo "Running: $WORKER_COUNT / $MAX_WORKERS (available slots: $AVAILABLE)"

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
  inherited=0
  while IFS= read -r line; do
    task_id=$(echo "$line" | grep -oE 't[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$task_id" ]]; then
      parent_id=$(echo "$task_id" | sed 's/\.[0-9]*$//')
      if grep -qE "^- \[.\] ${parent_id} .*#auto-dispatch" "$TODO_FILE" 2>/dev/null; then
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

# 5. Pulse scheduler status
if [[ "$(uname)" == "Darwin" ]]; then
  launchctl list 2>/dev/null | grep -i 'aidevops.*pulse' || echo "No launchd pulse found"
else
  crontab -l 2>/dev/null | grep -i 'pulse' || echo "No cron pulse found"
fi
```

## Report Format

Present results as a concise dashboard:

### Worker Status

- **Running**: X / Y max (Z available slots)
- Flag if all slots are full (no capacity for new work)
- Flag if 0 workers running but dispatchable tasks exist (possible scheduler issue)

### Queue Depth (subtask-aware)

- **Total open**: X (Y parents, Z subtasks) — subtasks are the actual work units
- **Dispatchable now**: N (M tagged #auto-dispatch, K inherited from parent)
- **Blocked**: B (waiting on dependencies)
- **Claimed/in-progress**: C (assigned to workers or interactive sessions)
- Flag if dispatchable count is 0 but open count is high (queue stall)

### Action Items

Flag these for the user (most important first):

1. **PRs ready to merge** — all CI green, no review comments
2. **PRs with CI failures** — need investigation
3. **Stale worktrees** — for tasks already deployed/merged
4. **Subtasks missing #auto-dispatch** — parent has tag but subtasks don't (dispatch gap)
5. **Pulse scheduler not running** — if no launchd/cron entry found

### System Health

- Worker count, available slots
- Pulse scheduler status (launchd on macOS, cron on Linux)
- Recent pulse log: `tail -20 ~/.aidevops/logs/pulse.log`

## Arguments

- No arguments: show current system status
- `--fix`: auto-fix simple issues (merge green PRs, clean stale worktrees)
