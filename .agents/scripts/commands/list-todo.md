---
description: List tasks from TODO.md with sorting and filtering options
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Display tasks from TODO.md and optionally PLANS.md.

Arguments: $ARGUMENTS

## Default

```bash
~/.aidevops/agents/scripts/list-todo-helper.sh $ARGUMENTS
```

Display the helper output directly.

## Fallback

If the helper is unavailable, parse manually:

1. Read `TODO.md` and `todo/PLANS.md`
2. Parse tasks by status (In Progress, Backlog, Done)
3. Apply filters from arguments
4. Format as Markdown tables

## Arguments

- **Sorting:** `--priority`/`-p`, `--estimate`/`-e`, `--date`/`-d`, `--alpha`/`-a`
- **Filtering:** `--tag <tag>`/`-t <tag>`, `--owner <name>`/`-o <name>`, `--status <status>`, `--estimate-filter <range>`
- **Display:** `--plans`, `--done`, `--all`, `--compact`, `--limit <n>`, `--json`

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

## Follow-up

Wait for:

1. **Task ID or row number** — start that task (`t014`, `5`)
2. **Filter command** — rerun with new filters (`-t seo`)
3. **"done"** — end browsing

If the task has `#plan` or points to `PLANS.md`, suggest `/show-plan <name>`. Otherwise offer to start work after checking branch state and creating one if needed.

## Related

- `/show-plan <name>` — detailed plan information
- `/ready` — tasks with no blockers
- `/save-todo` — save discussion as task
