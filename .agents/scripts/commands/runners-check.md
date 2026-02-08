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

# 2. Open PRs from workers (need merge/review)
gh pr list --state open --json number,title,headRefName,createdAt,statusCheckRollup \
  --jq '.[] | "\(.number) [\(.headRefName)] \(.title) checks:\(.statusCheckRollup | map(.conclusion // .state) | join(","))"' 2>/dev/null

# 3. Active worktrees (worker sessions)
git worktree list 2>/dev/null

# 4. System resources
~/.aidevops/agents/scripts/supervisor-helper.sh db \
  "SELECT id, state, retries FROM tasks WHERE state NOT IN ('deployed','cancelled','failed') ORDER BY state;" 2>/dev/null
```

## Report Format

Present results as a concise dashboard:

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

### System Health
- Load, memory, worker count
- Cron pulse status: `~/.aidevops/agents/scripts/supervisor-helper.sh cron status 2>&1`

## Arguments

- No arguments: check the most recent active batch
- `--batch <id>`: check a specific batch
- `--all`: show all batches including completed
- `--fix`: auto-fix simple issues (merge green PRs, clean stale worktrees, reset stuck tasks)
