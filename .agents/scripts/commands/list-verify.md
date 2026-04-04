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

**Fallback (script unavailable):** Read `todo/VERIFY.md`, parse entries between `<!-- VERIFY-QUEUE-START -->` and `<!-- VERIFY-QUEUE-END -->`, group by status: failed `[!]`, pending `[ ]`, passed `[x]`, format as Markdown tables.

## Arguments

- `--pending` / `--passed` / `--failed` — filter by status
- `-t <id>` / `--task <id>` — filter by task ID (e.g., `t168`)
- `--compact` — one-line per entry; `--json` — JSON output; `--no-color`

## Examples

```bash
/list-verify           # all entries, grouped by status
/list-verify --failed  # failed only (needs attention)
/list-verify -t t168   # specific task
/list-verify --json    # JSON output
```

## Output Format

Tables grouped failed → pending → passed. Columns: `# | Verify | Task | Description | PR | Merged | Reason/Checks/Verified` (column varies by section).
Footer: `N pending | N passed | N failed | N total`.

## After Display

- **Verify ID** (e.g., `v001`) — run verification checks for that entry
- **"failed"** — re-filter to failed only
- **"done"** — end browsing

## Related

- `/list-todo` — tasks from TODO.md
- `/ready` — tasks with no blockers
