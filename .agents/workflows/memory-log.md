---
description: Show recent auto-captured memories with filtering
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Show recent auto-captured memories from AI sessions.

Arguments: `$ARGUMENTS`

## Workflow

Run `memory-helper.sh log` with optional filters:

| Argument | Effect |
|----------|--------|
| (none) | Last 20 auto-captures |
| `--limit N` | Limit to N entries |
| `--json` | JSON output |

Output: `N. [TYPE] Content | time ago` (e.g., `1. [WORKING_SOLUTION] Fixed CORS by adding nginx headers | 2 hours ago`). If empty: trigger with `memory-helper.sh store --auto --content "..."`.

## Auto-capture triggers

Agents store memories with `--auto` when they detect:

| Type | Example |
|------|---------|
| `WORKING_SOLUTION` | "Fixed CORS with nginx headers" |
| `FAILED_APPROACH` | "setTimeout doesn't work for async" |
| `DECISION` | "Chose SQLite over Postgres" |
| `TOOL_CONFIG` | "SonarCloud needs SONAR_TOKEN" |
| `USER_PREFERENCE` | "Prefers tabs over spaces" |

## Privacy

- `<private>...</private>` tags are stripped before storage
- Secret patterns (API keys, tokens) are rejected
- Use `privacy-filter-helper.sh scan` for comprehensive scanning

## Related Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Manually store a memory |
| `/recall {query}` | Search all memories |
| `/recall --auto-only` | Auto-captured only |
| `/recall --manual-only` | Manual only |
| `memory-helper.sh stats` | Memory statistics |
