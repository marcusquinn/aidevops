---
description: Token-use, session-cost, compaction, and MCP activity reporting
agent: Reports
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Token Use Reports

Use this doc for AI session token, model, compaction, cost, and MCP activity
reports. Keep collection deterministic; use the report agent for interpretation
only after the helper has written the local evidence bundle.

## Quick Reference

```bash
~/.aidevops/agents/scripts/report-token-use-helper.sh report --limit 25
~/.aidevops/agents/scripts/report-token-use-helper.sh report --session ses_abc123 --open
~/.aidevops/agents/scripts/report-token-use-helper.sh data --json --since 7d
```

## Output Contract

- Local artifacts live under `~/.aidevops/_reports/token-use/<UTC-run-id>/`.
- `report.md` is canonical; `report.json` supports automation; `report.html`
  is the browser review copy.
- The command prints the `file://` link for `report.html` and opens it only when
  `--open` is supplied.

## Data Sources

| Runtime | Primary source | Notes |
|---|---|---|
| OpenCode | `~/.local/share/opencode/opencode.db` | Uses `session.parent_id` to aggregate compacted child sessions with their root session. |
| OpenCode tools | `~/.aidevops/.agent-workspace/observability/llm-requests.db` | Adds model request counts, tool-call counts, and observed MCP tool names when available. |
| Claude fallback | `~/.aidevops/.agent-workspace/observability/metrics.jsonl` | Best-effort token totals; compaction and MCP fields may be empty. |

## Report Fields

- Session name and root session ID.
- Runtime and model(s) used.
- Tokens in, tokens out, reasoning, cached-read, cached-write, and net total.
- Compaction count and child session count.
- Active/configured MCP servers and observed MCP tools.
- Date-time started and date-time finished.

Net token total is input + output + reasoning + cache-read + cache-write tokens.

## Privacy

Generated artifacts are local to the user's aidevops directory and are not meant
for public issues, PRs, or committed reports unless private identifiers have been
reviewed and sanitized.
