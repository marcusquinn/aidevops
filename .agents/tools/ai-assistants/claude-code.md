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

## Related

- `tools/ai-assistants/overview.md` - AI assistant comparison
- `tools/ai-orchestration/openprose.md` - Multi-agent orchestration DSL
