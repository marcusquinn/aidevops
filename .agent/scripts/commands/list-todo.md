---
description: List tasks from TODO.md with sorting and filtering options
agent: Build+
mode: subagent
---

Display tasks from TODO.md and optionally PLANS.md with fast script-based output.

Arguments: $ARGUMENTS

## Quick Output (Default)

Run the helper script for instant output:

```bash
~/.aidevops/agents/scripts/list-todo-helper.sh $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Fallback (Script Unavailable)

If the script fails or is unavailable, read and parse the files manually:

1. Read `TODO.md` and `todo/PLANS.md`
2. Parse tasks by status (In Progress, Backlog, Done)
3. Apply any filters from arguments
4. Format as Markdown tables

## Arguments

**Sorting options:**
- `--priority` or `-p` - Sort by priority (security/bugfix first)
- `--estimate` or `-e` - Sort by time estimate (shortest first)
- `--date` or `-d` - Sort by logged date (newest first)
- `--alpha` or `-a` - Sort alphabetically

**Filtering options:**
- `--tag <tag>` or `-t <tag>` - Filter by tag (seo, security, etc.)
- `--owner <name>` or `-o <name>` - Filter by assignee (marcus, etc.)
- `--status <status>` - Filter by status (pending, in-progress, done)
- `--estimate-filter <range>` - Filter by estimate (<2h, >1d, 1h-4h)

**Display options:**
- `--plans` - Include plan details from PLANS.md
- `--done` - Include completed tasks
- `--all` - Show everything (pending + done + plans)
- `--compact` - One-line per task (no tables)
- `--limit <n>` - Limit results
- `--json` - Output as JSON

## Examples

```bash
/list-todo                           # All pending, grouped by status
/list-todo --priority                # Sorted by priority
/list-todo -t seo                    # Only #seo tasks
/list-todo -o marcus -e              # Marcus's tasks, shortest first
/list-todo --estimate-filter "<2h"   # Quick wins under 2 hours
/list-todo --plans                   # Include plan details
/list-todo --all --compact           # Everything, one line each
```

## Output Format

The script outputs Markdown tables:

```markdown
## Tasks Overview

### In Progress (N)

| # | ID | Task | Est | Tags | Owner |
|---|-----|------|-----|------|-------|
| 1 | t001 | Task description | ~2h | #tag | @owner |

---

### Backlog (N pending)

| # | ID | Task | Est | Tags | Owner | Logged |
|---|-----|------|-----|------|-------|--------|
| 1 | t002 | Another task | ~4h | #feature | - | 2025-01-15 |

**Blocked tasks** (N):
- t003 blocked-by:t001

---

**Summary:** N pending | N in progress | N done | N active plans

---

**Options:**
1. Work on a specific task (enter task ID like `t014` or row number from `#` column)
2. Filter/sort differently (e.g., `--priority`, `-t seo`)
3. Done browsing
```

## After Display

Wait for user input:

1. **Task ID or row number** - Start working on that task (e.g., `t014` or `5`)
2. **Filter command** - Re-run with new filters (e.g., `-t seo`)
3. **"3" or "done"** - End browsing

When user selects a task:
- Check if it's a plan reference (`#plan` tag or `→ PLANS.md`)
- If plan: suggest `/show-plan <name>`
- If task: offer to start work (check branch, create if needed)

## Related Commands

- `/show-plan <name>` - Show detailed plan information
- `/ready` - Show only tasks with no blockers
- `/save-todo` - Save current discussion as task
