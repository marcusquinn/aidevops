---
tools:
  - bash
  - read
  - edit
  - write
model: sonnet
---

# {{PLUGIN_NAME}}

{{PLUGIN_DESCRIPTION}}

## Quick Reference

- **Purpose**: {{PLUGIN_DESCRIPTION}}
- **Namespace**: `{{NAMESPACE}}`
- **Requires**: aidevops framework (`~/.aidevops/agents/` must exist)

## Commands

| Command | Description |
|---------|-------------|
| `/{{NAMESPACE}}-help` | Show available commands |

## Subagents

| File | Purpose |
|------|---------|
| `{{NAMESPACE}}/example.md` | Example subagent |

## Workflow

1. Step one
2. Step two
3. Step three

## Integration

This plugin integrates with the aidevops framework:

- Uses `~/.config/aidevops/credentials.sh` for API keys
- Follows aidevops agent conventions (YAML frontmatter, progressive disclosure)
- Compatible with supervisor dispatch and headless workers
