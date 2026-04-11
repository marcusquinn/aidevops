---
description: List verification queue entries from todo/VERIFY.md with filtering
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

List `todo/VERIFY.md` verification queue with status filtering.

Arguments: $ARGUMENTS

## Run

```bash
~/.aidevops/agents/scripts/list-verify-helper.sh $ARGUMENTS
```

**Fallback:** Read `todo/VERIFY.md`, parse entries between `<!-- VERIFY-QUEUE-START -->` and `<!-- VERIFY-QUEUE-END -->`, group by status: failed `[!]`, pending `[ ]`, passed `[x]`. Format as Markdown tables.

## Arguments

- `--pending` / `--passed` / `--failed` — filter by status (e.g., `--failed` for needs-attention)
- `-t <id>` / `--task <id>` — filter by task ID (e.g., `-t t168`)
- `--compact` — one-line per entry; `--json` — JSON output; `--no-color` — plain text
- No args — all entries grouped by status

## Output

Tables grouped failed → pending → passed. Columns: `# | Verify | Task | Description | PR | Merged | Reason/Checks/Verified` (column varies by section). Footer: `N pending | N passed | N failed | N total`.

## After Display

Reply with a **Verify ID** (e.g., `v001`) to run checks, `"failed"` to refilter, or `"done"` to finish.

## Related

- `/list-todo` — tasks from TODO.md
- `/ready` — tasks with no blockers
