---
description: Store a memory entry for cross-session recall
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Store knowledge, patterns, or learnings for future sessions.

Content to remember: $ARGUMENTS

## Memory Types

| Type | Use For | Example |
|------|---------|---------|
| `WORKING_SOLUTION` | Fixes that worked | "Fixed CORS by adding headers to nginx" |
| `FAILED_APPROACH` | What didn't work (avoid repeating) | "Don't use sync fs in Lambda" |
| `CODEBASE_PATTERN` | Project conventions | "All API routes use /api/v1 prefix" |
| `USER_PREFERENCE` | Developer preferences | "Prefers tabs over spaces" |
| `TOOL_CONFIG` | Tool setup notes | "SonarCloud needs SONAR_TOKEN in CI" |
| `DECISION` | Project-level process/policy choices | "Adopted conventional commits for all repos" |
| `CONTEXT` | Background info | "Legacy API deprecated in Q3" |
| `ARCHITECTURAL_DECISION` | System-level architecture choices and trade-offs | "Chose SQLite over Postgres for single-node simplicity" |
| `ERROR_FIX` | Bug fixes and patches | "Patched null pointer in auth middleware" |
| `OPEN_THREAD` | Unresolved questions or follow-ups | "Investigate race condition in job scheduler" |

## Workflow

1. **Analyze** — extract: content (concise, actionable), type, tags (comma-separated), project (optional)
2. **Confirm** — present to user: `Type: {type}  Content: "{content}"  Tags: {tags}  Project: {project or "global"}` — options: 1. Confirm  2. Change type  3. Edit content  4. Cancel
3. **Store** — after confirmation:

   ```bash
   ~/.aidevops/agents/scripts/memory-helper.sh store --type "{type}" --content "{content}" --tags "{tags}" --project "{project}"
   ```

4. **Confirm** — `Remembered: "{content}" ({type}) — Recall with: /recall {keyword}`

## Auto-Remember Triggers (MANDATORY)

Proactively suggest `/remember` on these patterns — do NOT wait for the user to ask. Suggest immediately; don't skip minor learnings; keep suggestions concise and actionable.

| User Says | Memory Type |
|-----------|-------------|
| "that fixed it", "it works now", "solved", "the trick is", "workaround" | `WORKING_SOLUTION` |
| "I prefer", "I like", "always use", "never use" | `USER_PREFERENCE` |
| "don't do X", "X doesn't work", "avoid X" | `FAILED_APPROACH` |
| "let's go with", "decided to", "we'll use" | `DECISION` |
| "architecture", "service boundary", "tech stack", "data flow" | `ARCHITECTURAL_DECISION` |
| "configure X as", "set X to", "X needs Y" | `TOOL_CONFIG` |

```text
That worked! Want me to remember this for future sessions?

/remember {concise, actionable description}

(Reply 'y' to confirm, or edit the description)
```

## Storage

`~/.aidevops/.agent-workspace/memory/memory.db` (SQLite FTS5) — Stats: `memory-helper.sh stats`
