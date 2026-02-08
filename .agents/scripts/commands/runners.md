---
description: Supervise parallel task dispatch via opencode run workers (batch tasks, PRs, or descriptions)
agent: Build+
mode: subagent
---

Supervise parallel task execution using the supervisor. Accepts task IDs, PR URLs, or descriptions.

Arguments: $ARGUMENTS

## Supervisor Role (CRITICAL)

**This session is a supervisor. Its sole purpose is orchestration.**

The session that runs `/runners` becomes a long-running supervisor. It must:

1. **Dispatch** tasks to `opencode run` worker processes (each in its own worktree)
2. **Monitor** worker health, progress, and outcomes via `supervisor-helper.sh pulse`
3. **React** to failures (retry, reassign, skip) and successes (merge PRs, dispatch next wave)
4. **Self-improve** the orchestration process when patterns of failure emerge
5. **Persist** until the batch completes or the user intervenes

**The supervisor MUST NOT do task work itself.** Every task is executed by a separate
`opencode run` worker process in its own worktree with its own context window. The
supervisor does not have enough token context to both orchestrate AND implement tasks.
Attempting to do both will exhaust context and fail at both jobs.

**What the supervisor does:**

- Run `supervisor-helper.sh` commands (add, batch, pulse, status, dispatch, cleanup)
- Read worker logs to diagnose failures (`tail` log files, check exit codes)
- Merge PRs created by workers (`gh pr merge`)
- Update TODO.md with completion timestamps
- Install and maintain the cron pulse for unattended operation
- Identify process improvements and apply them (fix dispatch scripts, adjust timeouts)

**What the supervisor does NOT do:**

- Read source code to understand task requirements
- Write or edit implementation files
- Run linters, tests, or quality checks on task output
- Research topics or fetch documentation for tasks
- Use the Task tool to spawn subagents for task work

**Unblock by dispatching, not by solving:** When the supervisor encounters a problem
that requires implementation work (a script bug, a missing config, a process gap, a
blocker for other tasks), it does NOT attempt to fix it inline. Instead:

1. Create a new TODO entry for the fix (e.g., `t154 Fix pre-edit-check.sh color vars`)
2. Add it to the current batch: `$SH add t154 --repo "$(pwd)" --description "..."`
3. Dispatch it immediately if it blocks other tasks, or queue it for the next wave
4. Continue supervising — the worker handles the fix

This applies to any question or issue that arises during supervision. The supervisor's
job is to identify problems and route them to workers, not to solve them.

**Context budget discipline:** Keep supervisor context lean. Avoid reading large files,
long log outputs, or task-specific content. Use `tail -20` not `cat`. Use `--compact`
flags where available. If a worker log is large, grep for `EXIT:` or `error` rather
than reading the whole thing.

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

# Install cron pulse for unattended operation
$SH cron install --batch "$BATCH_ID"

# Run first pulse to start dispatching
$SH pulse --batch "$BATCH_ID"
```

## Step 5: Supervise (Monitor + React Loop)

**This is the core supervisor loop.** The session stays here until the batch completes.
Each iteration should be lightweight — check status, react to changes, report progress.

### Pulse cycle

```bash
# Poll every 2-5 minutes (cron handles the mechanical pulse;
# the supervisor adds judgment and reaction)
$SH pulse --batch "$BATCH_ID"
```

After each pulse, evaluate:

1. **Completed workers** — Check if PRs were created. Merge if CI passes.
2. **Failed workers** — Read last 20 lines of log. Diagnose: timeout? crash? bad prompt?
   - If retryable: `$SH dispatch $TASK_ID` (supervisor-helper handles retry count)
   - If systemic (same error pattern across workers): create a fix task and dispatch it
3. **Stale workers** — Check `ps aux | grep opencode` for zombie processes. Kill if needed.
4. **Queued tasks** — Verify slots are available for next dispatch.
5. **Blockers and issues** — If a problem blocks other tasks or requires code changes,
   create a new TODO, add it to the batch, and dispatch it as a worker task. Do not
   attempt to fix it in the supervisor session.

### Progress display

```text
## Progress: 8/12 complete (2 running, 2 queued)

| Task | Status | Worker PID | PR | Notes |
|------|--------|------------|-----|-------|
| t083 | deployed | - | #382 merged | |
| t084 | running | 78330 | - | 12m elapsed |
| t085 | queued | - | - | waiting for slot |
| t087 | failed | - | - | retry 2/3: timeout |
```

### Self-improvement triggers

During the monitor loop, watch for these patterns and act:

| Pattern | Action |
|---------|--------|
| Multiple workers fail with same error | Create fix task, add to batch, dispatch as worker |
| Workers timing out consistently | Increase timeout or simplify task prompts |
| Workers creating PRs that fail CI | Create task to fix linters/quality config, dispatch |
| Cron pulse not firing | Reinstall: `$SH cron install` (this is a supervisor command, not task work) |
| System load too high | Reduce concurrency: `$SH batch-update --concurrency N` |
| Worker stuck (no log output for >10m) | Kill process, mark failed, retry |
| Missing script/config blocks tasks | Create task for the fix, dispatch with high priority |

**Remember:** "Fix root cause" means "dispatch a worker to fix it", not "fix it here".
The only things the supervisor does directly are supervisor-helper commands, git
operations on TODO.md, `gh pr merge`, and process kills.

### Context preservation

To keep the supervisor session running for hours without exhausting context:

- **Do NOT read full worker logs** — use `tail -20` or `grep -E 'error|EXIT|FAIL'`
- **Do NOT read task source files** — workers handle that
- **Do NOT use Task tool for research** — that's worker territory
- **Summarize, don't accumulate** — after each pulse, output a compact status table
- **Commit TODO.md updates promptly** — don't let state accumulate in memory

## Step 6: Batch Complete

When all tasks reach a terminal state:

```bash
# Run retrospective
$SH retrospective "$BATCH_ID"

# Clean up worktrees for completed tasks
$SH cleanup

# Kill any orphaned processes
$SH kill-workers

# Uninstall cron pulse (batch is done)
$SH cron uninstall
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

### Post-batch actions

1. **Update TODO.md** — Mark completed tasks `[x]` with `completed:` timestamps
2. **Merge ready PRs** — `gh pr merge --squash` for PRs with green CI
3. **Store learnings** — If process improvements were made, `/remember` them
4. **Clean worktrees** — `wt merge` to remove merged branches

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
