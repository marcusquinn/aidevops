---
description: Generate a local report of token use per AI session, including compacted sessions and MCP observations
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Generate a local token-use report for AI sessions.

Arguments: `$ARGUMENTS`

## Process

1. Run `~/.aidevops/agents/scripts/report-token-use-helper.sh report $ARGUMENTS`.
2. Return the helper summary directly, including the local `file://` report link.
3. If the user passes `--open`, the helper opens the generated HTML report.

## Usage

```bash
/report-token-use
/report-token-use --limit 50
/report-token-use --session ses_abc123
/report-token-use --since 7d
/report-token-use --runtime opencode
/report-token-use --daily-days 90
/report-token-use --json
/report-token-use --open
```

## Output

Reports are written under `~/.aidevops/_reports/token-use/<UTC-run-id>/`:

- `report.md` — canonical Markdown review copy.
- `report.json` — machine-readable session rows.
- `report.html` — local browser review file.
- Each report includes a daily usage summary for the last 90 days by default.

## Data contract

Each session row includes session name, runtime, model(s), tokens in, tokens out,
cached-read tokens, raw token total, net token total, compaction count, configured MCPs,
observed MCPs, started time, and finished time.

Net token total is input + output + reasoning + cache-write tokens. Cache reads
are excluded from net totals and retained in raw totals for context-volume review.
OpenCode reports recursively include child sessions via `session.parent_id` so
compacted sessions are counted with their root session.
