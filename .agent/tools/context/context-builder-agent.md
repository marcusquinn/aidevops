---
description: "[UTILITY-1] Context Builder - token-efficient AI context generation. Use BEFORE complex coding tasks. Parallel with any workflow"
mode: subagent
temperature: 0.1
tools:
  bash: true
  read: true
  write: true
  glob: true
  task: true
note: Uses repomix CLI directly (not MCP) for better control and reliability
---

# Context Builder Agent

Specialized agent for generating token-efficient context for AI coding assistants.

## Purpose

Generate optimized repository context using Repomix CLI with Tree-sitter compression.
Achieves ~80% token reduction while preserving code structure understanding.

## Reference Documentation

Read `tools/context/context-builder.md` for complete operational guidance.

## Available Commands

**Helper Script** (preferred):

```bash
# Helper script location
~/.aidevops/agents/scripts/context-builder-helper.sh

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

**Direct CLI** (when helper unavailable):

```bash
# Pack with compression (recommended)
npx repomix@latest . --compress --output context.xml

# Pack remote repository
npx repomix@latest --remote user/repo --compress --output context.xml

# Pack with patterns
npx repomix@latest . --include "src/**/*.ts" --ignore "**/*.test.ts"

# Token analysis
npx repomix@latest . --token-count-tree 100

# Output to stdout
npx repomix@latest . --stdout | pbcopy
```

## When to Use

| Scenario | Command | Token Impact |
|----------|---------|--------------|
| Architecture review | `compress` or `--compress` | ~80% reduction |
| Full implementation details | `pack` | Full tokens |
| Quick file subset | `quick . "**/*.ts"` | Minimal |
| External repo analysis | `remote user/repo` | Compressed |

## Output Location

All context files are saved to: `~/.aidevops/.agent-workspace/work/context/`

## Workflow Integration

1. **Before complex tasks**: Generate compressed context first
2. **For debugging**: Use full pack mode for specific directories
3. **For external repos**: Use remote mode with compression
