---
description: List tasks from TODO.md with sorting and filtering options
agent: Build+
mode: subagent
---

Display tasks from TODO.md and optionally PLANS.md.

Arguments: $ARGUMENTS

## Quick Output (Default)

```bash
~/.aidevops/agents/scripts/list-todo-helper.sh $ARGUMENTS
```

Display output directly — the script handles all formatting (Markdown tables, grouping, summary).

## Fallback (Script Unavailable)

If the script fails, parse manually:

1. Read `TODO.md` and `todo/PLANS.md`
2. Parse tasks by status (In Progress, Backlog, Done)
3. Apply filters from arguments
4. Format as Markdown tables

## Arguments

**Sorting:** `--priority`/`-p` (security/bugfix first), `--estimate`/`-e` (shortest first), `--date`/`-d` (newest first), `--alpha`/`-a` (alphabetical).

**Filtering:** `--tag <tag>`/`-t <tag>`, `--owner <name>`/`-o <name>`, `--status <status>`, `--estimate-filter <range>` (`<2h`, `>1d`, `1h-4h`).

**Display:** `--plans` (include PLANS.md), `--done` (completed tasks), `--all` (everything), `--compact` (one-line per task), `--limit <n>`, `--json`.

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

## After Display

Wait for user input:

1. **Task ID or row number** — start working on that task (e.g., `t014` or `5`)
2. **Filter command** — re-run with new filters (e.g., `-t seo`)
3. **"done"** — end browsing

On task selection: if `#plan` tag or `→ PLANS.md` → suggest `/show-plan <name>`. Otherwise offer to start work (check branch, create if needed).

## Related

- `/show-plan <name>` — detailed plan information
- `/ready` — tasks with no blockers
- `/save-todo` — save discussion as task
