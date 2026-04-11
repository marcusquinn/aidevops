---
description: Search and retrieve memories from previous sessions
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Search stored memories for relevant knowledge.

Search query: $ARGUMENTS

## Workflow

1. Run: `~/.aidevops/agents/scripts/memory-helper.sh recall "{query}"`
2. Present results with type, tags, project, and age. Offer to apply selected memory to current context.
3. No results: suggest different keywords, broader terms, or `--recent`.
4. Search proactively when starting a project, encountering errors, making architecture decisions, or setting up tools. Check `--project {current-project}` at session start.

## Options

| Command | Purpose |
|---------|---------|
| `/recall {query}` | Search by keywords |
| `/recall --type WORKING_SOLUTION` | Filter by type |
| `/recall --project myapp` | Filter by project |
| `/recall --recent` | Show 10 most recent |
| `/recall --stats` | Show memory statistics |

## Memory Types

`WORKING_SOLUTION`, `FAILED_APPROACH`, `USER_PREFERENCE`, `CODEBASE_PATTERN`, `DECISION`, `TOOL_CONFIG`

## Maintenance

Stale memories (>90 days, never accessed) are candidates for pruning.

```bash
~/.aidevops/agents/scripts/memory-helper.sh validate
~/.aidevops/agents/scripts/memory-helper.sh prune --dry-run
~/.aidevops/agents/scripts/memory-helper.sh prune
```
