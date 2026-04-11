---
description: List tasks from TODO.md with sorting and filtering options
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run `~/.aidevops/agents/scripts/list-todo-helper.sh $ARGUMENTS` and display the output.

## Fallback

If unavailable, parse manually: read `TODO.md` and `todo/PLANS.md`, group by status (In Progress, Backlog, Done), apply argument filters, format as Markdown tables.

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

1. **Task ID or row number** — start that task (`t014`, `5`)
2. **Filter command** — rerun with new filters (`-t seo`)
3. **"done"** — end browsing

For `#plan` tasks or `PLANS.md` items, suggest `/show-plan <name>`. Otherwise offer to start work on branch.

## Related

- `/show-plan <name>` — detailed plan information
- `/ready` — tasks with no blockers
- `/save-todo` — save discussion as task
