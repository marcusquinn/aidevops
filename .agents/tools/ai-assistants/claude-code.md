---
description: Claude Code MCP - spawn Claude as a sub-agent for complex tasks
mode: subagent
tools:
  read: true
  bash: true
  claude-code-mcp_*: true
---

# Claude Code MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Spawn Claude Code as a sub-agent for complex, multi-step tasks
- **MCP**: `claude-code-mcp` (loaded on-demand when this subagent is invoked)
- **Source**: https://github.com/steipete/claude-code-mcp
- **Install**: `npm install -g @steipete/claude-code-mcp`
- **Tool exposure**: `claude-code-mcp_*` tools become available when invoked

**When to use**:
- Complex multi-file refactoring that benefits from fresh context
- Tasks requiring extended thinking or different model capabilities
- Parallel execution of independent subtasks
- Second opinion on complex architectural decisions

**When NOT to use**:
- Simple file edits (use native Edit tool)
- Quick searches (use grep/rg)
- Single-file changes (overhead not worth it)

<!-- AI-CONTEXT-END -->

Use this subagent when fresh context or parallel execution is worth the overhead. It loads the `claude-code-mcp` tools, runs the prompt in Claude Code, and returns the result to the parent agent.

## Invocation

```text
@claude-code Refactor the authentication module to use JWT tokens
```

## Example Prompts

```text
@claude-code Refactor src/auth/ to use the new token validation library
@claude-code Analyze all API endpoints and create a comprehensive test suite
@claude-code Review the database schema and suggest optimizations
@claude-code Update all React components to use the new design system
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
- Scope appropriately; trivial edits are cheaper with native tools.
- Review sub-agent output before acting on it.
- Avoid nested sub-agents; they multiply token usage and cost quickly.

## Related

- `tools/ai-assistants/overview.md` - AI assistant comparison
- `tools/ai-orchestration/openprose.md` - Multi-agent orchestration DSL
