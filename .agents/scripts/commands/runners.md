---
description: Orchestrate parallel task dispatch via supervisor (batch tasks, PRs, or descriptions)
agent: Build+
mode: subagent
---

Orchestrate parallel task execution using the supervisor. Accepts task IDs, PR URLs, or descriptions.

Arguments: $ARGUMENTS

## Step 1: Parse Input

Parse `$ARGUMENTS` to determine the input type and options:

```bash
# Extract arguments (ignore flags)
ARGS="$ARGUMENTS"
```

**Input types** (auto-detected):

| Pattern | Type | Example |
|---------|------|---------|
| `t\d+` | Task IDs from TODO.md | `/runners t083 t084 t085` |
| `--prs <url>` | Open PRs from GitHub | `/runners --prs https://github.com/user/repo/pulls` |
| `--pr <number>...` | Specific PR numbers | `/runners --pr 382 383 385` |
| Free text | Description (creates tasks) | `/runners "Fix CI on all open PRs"` |

**Options:**

| Flag | Description |
|------|-------------|
| `--concurrency N` | Max parallel workers (default: suggest) |
| `--timeout Nm` | Max time per task, e.g. `30m`, `2h` (default: suggest) |
| `--model <model>` | Override model (default: anthropic/claude-opus-4-6) |
| `--dry-run` | Show plan without dispatching |
| `--batch-name <name>` | Name for the batch (default: auto-generated) |

## Step 2: Resolve Tasks

### For task IDs (`t083 t084 ...`):

```bash
# Look up each task in TODO.md
for tid in $TASK_IDS; do
  desc=$(grep -E "^- \[ \] $tid " TODO.md | head -1 | sed -E 's/^- \[ \] [^ ]* //')
  echo "$tid: $desc"
done
```

### For `--prs <url>`:

```bash
# Fetch open PRs from the repo
REPO=$(echo "$URL" | sed -E 's|https://github.com/([^/]+/[^/]+).*|\1|')
gh pr list --repo "$REPO" --state open --json number,title,headRefName
```

Create a task for each PR: `"Fix CI and merge PR #NNN: <title>"`

### For `--pr <numbers>`:

```bash
# Fetch specific PRs
for pr_num in $PR_NUMBERS; do
  gh pr view "$pr_num" --json number,title,headRefName
done
```

### For free text:

Use the description as a single task, or ask the AI to break it into subtasks.

## Step 3: Suggest Concurrency and Timeout

**IMPORTANT**: If `--concurrency` or `--timeout` are not specified, calculate suggestions and ask the user to confirm.

### Concurrency suggestion logic:

```text
task_count = number of tasks
estimated_minutes = sum of ~Nm estimates from TODO.md (or 15m default per task)

if task_count <= 2:     suggest 1 (sequential)
elif task_count <= 6:   suggest 2
elif task_count <= 12:  suggest 3
else:                   suggest 4

# Adjust down if estimated_minutes per task > 30m (heavy tasks)
# Adjust down if model is opus (expensive)
```

### Timeout suggestion logic:

```text
if task has ~Nm estimate in TODO.md: use that * 2 (buffer)
elif task is PR fix:                 suggest 20m
elif task is new feature:            suggest 45m
else:                                suggest 30m
```

### Present to user:

```text
## Batch Plan

| # | Task | Est. Time |
|---|------|-----------|
| 1 | t083: Create Bing Webmaster Tools subagent | ~15m |
| 2 | t084: Create Rich Results Test subagent | ~10m |
| ... | ... | ... |

**Suggested settings:**
- Concurrency: 3 (12 tasks, ~15m each)
- Timeout per task: 30m
- Model: anthropic/claude-opus-4-6
- Estimated total time: ~60m (4 waves of 3)

Proceed with these settings?
1. Yes, start dispatch
2. Change concurrency to: ___
3. Change timeout to: ___
4. Change model to: ___
5. Dry run (show commands without executing)
```

Wait for user confirmation before proceeding. If user provides a number or custom values, use those.

## Step 4: Create Batch and Dispatch

After user confirms:

```bash
SH=~/.aidevops/agents/scripts/supervisor-helper.sh

# Add tasks to supervisor
for task in $TASKS; do
  $SH add "$task_id" --repo "$(pwd)" --description "$task_desc"
done

# Create batch
BATCH_ID=$($SH batch "$BATCH_NAME" --concurrency "$CONCURRENCY" --tasks "$TASK_IDS_CSV")

# Run first pulse to start dispatching
$SH pulse --batch "$BATCH_ID"
```

## Step 5: Monitor Loop

After initial dispatch, enter a monitoring loop:

```bash
# Poll every 60 seconds until batch completes
while true; do
  sleep 60
  $SH pulse --batch "$BATCH_ID"

  # Check if batch is complete
  STATUS=$($SH batch-status "$BATCH_ID")
  if [[ "$STATUS" == "complete" || "$STATUS" == "all_terminal" ]]; then
    break
  fi
done
```

Display progress updates to the user after each pulse:

```text
## Progress: 8/12 complete

| Task | Status | PR | Notes |
|------|--------|----|-------|
| t083 | complete | #382 | |
| t084 | running | | retry 1/3 |
| t085 | queued | | waiting for slot |
| ... | ... | ... | ... |
```

## Step 6: Batch Complete

When all tasks reach a terminal state:

```bash
# Run retrospective
$SH retrospective "$BATCH_ID"

# Clean up worktrees
$SH cleanup

# Kill any orphaned processes
$SH kill-workers
```

Report final summary:

```text
## Batch Complete

- Completed: 10/12
- Failed: 2 (t087: auth_error, t088: max retries)
- PRs created: #382, #383, #385, #386, #387, #388, #389, #390, #391
- Total time: 47m
- Retries used: 5

Failed tasks may need manual attention. Run `/runners --retry <batch-id>` to retry failed tasks.
```

## Step 7: Post-PR Lifecycle (if applicable)

If tasks created PRs, offer to run the post-PR lifecycle:

```text
10 PRs were created. Would you like to:
1. Run PR lifecycle (check CI, merge when ready, deploy)
2. Skip (PRs stay open for manual review)
3. Run for specific PRs only
```

If user chooses 1:

```bash
# Transition completed tasks to pr_review and run lifecycle
for task in $COMPLETED_TASKS; do
  $SH pr-lifecycle "$task"
done
```

## Examples

```bash
# Dispatch TODO tasks
/runners t083 t084 t085 t086

# Process all open PRs
/runners --prs https://github.com/marcusquinn/aidevops/pulls

# Fix specific PRs
/runners --pr 382 383 385 --concurrency 2

# Custom batch with timeout
/runners t090 t091 t092 --concurrency 2 --timeout 45m

# Dry run to preview
/runners t083 t084 t085 --dry-run

# Retry failed tasks from a previous batch
/runners --retry batch-20260206053218-75029
```
