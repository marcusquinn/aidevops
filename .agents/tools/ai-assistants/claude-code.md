---
description: Claude Code MCP - spawn Claude as a sub-agent for complex tasks
mode: subagent
tools:
  read: true
  bash: true
  claude-code-mcp_*: true
  # TODO(permission-migration): Replace with permission: claude-code-mcp: allow
  # once anomalyco/opencode#6892 is resolved.
mcp:
  - claude-code-mcp
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Claude Code MCP

<!-- AI-CONTEXT-START -->

- **Purpose**: Spawn Claude Code as a sub-agent for complex, multi-step tasks
- **MCP**: `claude-code-mcp` (loaded on-demand when this subagent is invoked)
- **Source**: https://github.com/steipete/claude-code-mcp
- **Install**: `npm install -g @steipete/claude-code-mcp`
- **Use when**: complex multi-file refactoring, parallel independent subtasks, second opinion on architecture
- **Skip when**: simple file edits, quick searches, single-file changes (overhead not worth it)

<!-- AI-CONTEXT-END -->

## Invocation

```text
@claude-code Refactor src/auth/ to use the new token validation library
@claude-code Analyze all API endpoints and create a comprehensive test suite
```

## Configuration

`opencode.json`:

```json
{
  "mcp": {
    "claude-code-mcp": {
      "type": "local",
      "command": ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
      "enabled": false
    }
  },
  "tools": {
    "claude-code-mcp_*": false
  }
}
```

The MCP stays disabled globally and starts on demand when this subagent is invoked.

## Best Practices

- Be specific; detailed prompts improve results.
- Review sub-agent output before acting on it.
- Avoid nested sub-agents; they multiply token usage and cost quickly.

## Background agent summaries

Claude Code can make extra model calls to write progress summaries for running
background agents (`query_source=agent_summary`). These calls cost tokens but
do not appear in the session transcript, so transcript-based cost accounting
undercounts them (GH#35929).

| Path | Summary calls |
|------|---------------|
| Interactive Claude Code with background agents | Possible without any setting |
| `claude -p` / Agent SDK | Only when `CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES` is set (opt-in) |
| OpenCode direct provider | Not applicable: this code does not run |

- **Check exposure**: `claude-code-diagnose.sh agent-summary` reports the CLI
  version, install owner, opt-in state (environment and
  `~/.claude/settings.json` `env`) and one of `potentially-affected`,
  `not-present` or `unverified`. It makes no model call.
- **Measure spend**: with Claude Code OTel enabled, aggregate
  `claude_code.api_request` events by `query_source=agent_summary`. Report
  totals only; do not export prompt content.
- **No supported opt-out is known.** Leave `CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES`
  unset; it enables summaries, it does not disable them. Do not use preloads,
  `BUN_OPTIONS` or timer interception to suppress them. Follow the upstream
  Claude Code feature request for a supported control instead.

## Related

- `tools/ai-assistants/overview.md` - AI assistant comparison
- `tools/ai-orchestration/openprose.md` - Multi-agent orchestration DSL
