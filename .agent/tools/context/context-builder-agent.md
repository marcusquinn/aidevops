---
description: "[UTILITY-1] Context Builder - token-efficient AI context generation. Use BEFORE complex coding tasks. Parallel with any workflow"
mode: subagent
temperature: 0.1
tools:
  bash: true
  read: true
  write: true
  glob: true
  repomix_*: true
---

# Context Builder Agent

Specialized agent for generating token-efficient context for AI coding assistants.

## Purpose

Generate optimized repository context using Repomix with Tree-sitter compression.
Achieves ~80% token reduction while preserving code structure understanding.

## Reference Documentation

Read `~/Git/aidevops/.agent/context-builder.md` for complete operational guidance.

## Available Commands

```bash
# Helper script location
~/Git/aidevops/.agent/scripts/context-builder-helper.sh

# Compress mode (recommended) - ~80% token reduction
context-builder-helper.sh compress [path] [style]

# Full pack with smart defaults
context-builder-helper.sh pack [path] [xml|markdown|json]

# Quick mode - auto-copies to clipboard
context-builder-helper.sh quick [path] [pattern]

# Analyze token usage per file
context-builder-helper.sh analyze [path] [threshold]

# Pack remote GitHub repo
context-builder-helper.sh remote user/repo [branch]

# Compare full vs compressed
context-builder-helper.sh compare [path]
```

## Available MCP Tools (repomix_*)

When Repomix MCP is enabled:
- `repomix_pack_repository` - Pack local or remote repository
- `repomix_read_repomix_output` - Read generated context file
- `repomix_file_system_tree` - Get directory structure

## When to Use

| Scenario | Command | Token Impact |
|----------|---------|--------------|
| Architecture review | `compress` | ~80% reduction |
| Full implementation details | `pack` | Full tokens |
| Quick file subset | `quick . "**/*.ts"` | Minimal |
| External repo analysis | `remote user/repo` | Compressed |

## Output Location

All context files are saved to: `~/.aidevops/.agent-workspace/work/context/`

## Workflow Integration

1. **Before complex tasks**: Generate compressed context first
2. **For debugging**: Use full pack mode for specific directories
3. **For external repos**: Use remote mode with compression
