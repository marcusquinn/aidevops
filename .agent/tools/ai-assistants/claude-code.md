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

**When to use**:
- Complex multi-file refactoring that benefits from fresh context
- Tasks requiring extended thinking or different model capabilities
- Parallel execution of independent subtasks
- Second opinion on complex architectural decisions

**When NOT to use**:
- Simple file edits (use native Edit tool)
- Quick searches (use grep/osgrep)
- Single-file changes (overhead not worth it)

<!-- AI-CONTEXT-END -->

## Overview

The Claude Code MCP allows spawning Claude Code as a sub-agent. This is useful for:

1. **Context isolation**: Sub-agent gets fresh context, avoiding token bloat
2. **Parallel execution**: Multiple sub-agents can work on independent tasks
3. **Model flexibility**: Sub-agent can use different model/settings
4. **Complex workflows**: Multi-step tasks that benefit from dedicated focus

## Usage

Invoke this subagent when you need Claude Code capabilities:

```text
@claude-code Refactor the authentication module to use JWT tokens
```

The subagent will:
1. Load the `claude-code-mcp` tools
2. Execute the task using Claude Code
3. Return results to the parent agent

## Available Tools

When this subagent is invoked, these tools become available:

| Tool | Description |
|------|-------------|
| `claude_code` | Execute a prompt via Claude Code CLI |

## Example Prompts

```text
# Complex refactoring
@claude-code Refactor src/auth/ to use the new token validation library

# Multi-file analysis
@claude-code Analyze all API endpoints and create a comprehensive test suite

# Architecture review
@claude-code Review the database schema and suggest optimizations

# Parallel tasks (invoke multiple times)
@claude-code Update all React components to use the new design system
@claude-code Migrate all API routes to the new error handling pattern
```

## Configuration

The MCP is configured in `opencode.json`:

```json
{
  "mcp": {
    "claude-code-mcp": {
      "type": "local",
      "command": ["npx", "-y", "@steipete/claude-code-mcp"],
      "enabled": false
    }
  },
  "tools": {
    "claude-code-mcp_*": false
  }
}
```

The MCP starts on-demand when this subagent is invoked, avoiding startup overhead.

## Best Practices

1. **Be specific**: Provide clear, detailed prompts for best results
2. **Scope appropriately**: Don't use for trivial tasks
3. **Check results**: Review sub-agent output before proceeding
4. **Avoid loops**: Don't have sub-agents spawn more sub-agents

## Related

- `tools/ai-assistants/overview.md` - AI assistant comparison
- `tools/ai-orchestration/openprose.md` - Multi-agent orchestration DSL
