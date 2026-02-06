---
description: TLDR semantic code analysis with 95% token savings
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# llm-tldr - Semantic Code Analysis

TLDR extracts code structure and semantics, saving ~95% tokens compared to raw code.

**Source**: [parcadei/llm-tldr](https://github.com/parcadei/llm-tldr)

## Installation

```bash
pip install llm-tldr
```

## MCP Server (OpenCode)

Add to your MCP config:

```json
{
  "llm-tldr": {
    "command": "tldr-mcp",
    "args": ["--project", "${workspaceFolder}"]
  }
}
```

Or use the template: `configs/mcp-templates/llm-tldr.json`

## CLI Commands

### Tree - File Structure

```bash
tldr tree /path/to/project
```

Shows file tree with line counts.

### Structure - Code Skeleton

```bash
tldr structure /path/to/file.py
```

Extracts classes, functions, imports without implementation details.

### Context - Full Analysis

```bash
tldr context /path/to/file.py
```

Comprehensive analysis including:
- Imports and dependencies
- Class/function signatures
- Docstrings
- Type hints
- Call relationships

### CFG - Control Flow Graph

```bash
tldr cfg /path/to/file.py function_name
```

Shows control flow for a specific function.

### DFG - Data Flow Graph

```bash
tldr dfg /path/to/file.py function_name
```

Shows data dependencies and variable flow.

### Semantic Search

```bash
tldr search "authentication logic" /path/to/project
```

Uses bge-large-en-v1.5 embeddings (1024-dim) for semantic code search.

### Impact Analysis

```bash
tldr impact /path/to/file.py function_name
```

Shows what would be affected by changing a function.

### Dead Code Detection

```bash
tldr dead /path/to/project
```

Finds unused functions and classes.

### Slice - Code Slice

```bash
tldr slice /path/to/file.py variable_name
```

Extracts code slice affecting a variable.

## MCP Tools (via tldr-mcp)

When running as MCP server, provides these tools:

| Tool | Purpose |
|------|---------|
| `tldr_tree` | Get project file structure |
| `tldr_structure` | Extract code skeleton |
| `tldr_context` | Full semantic analysis |
| `tldr_cfg` | Control flow graph |
| `tldr_dfg` | Data flow graph |
| `tldr_search` | Semantic code search |
| `tldr_impact` | Impact analysis |
| `tldr_dead` | Dead code detection |
| `tldr_slice` | Code slicing |

## Token Savings

| Content Type | Raw Tokens | TLDR Tokens | Savings |
|--------------|------------|-------------|---------|
| 1000-line file | ~15,000 | ~750 | 95% |
| Class definition | ~500 | ~50 | 90% |
| Function body | ~200 | ~20 | 90% |

## Use Cases

### Before Editing Code

```bash
# Get structure before making changes
tldr context src/auth/handler.py

# Check what would be affected
tldr impact src/auth/handler.py validate_token
```

### Understanding Codebase

```bash
# Find authentication logic
tldr search "where do we validate JWT tokens" ./src

# Get project overview
tldr tree ./src
```

### Code Review

```bash
# Check for dead code
tldr dead ./src

# Understand data flow
tldr dfg src/payment/processor.py process_payment
```

## Comparison with Other Tools

| Tool | Purpose | Token Efficiency |
|------|---------|------------------|
| llm-tldr | Semantic extraction | 95% savings |
| osgrep | Semantic search | Good for finding |
| Augment | Codebase retrieval | Good for context |
| repomix | Full packing | No savings |

**Recommendation**: Use llm-tldr for understanding code structure, osgrep/Augment for finding code, repomix for full context when needed.

## Integration with Memory System

After using TLDR to understand code:

```bash
# Remember the pattern you discovered
~/.aidevops/agents/scripts/memory-helper.sh store "CODEBASE_PATTERN" \
  "Auth flow: validate_token -> check_permissions -> authorize" \
  "auth,flow,pattern" "myproject"
```

## Troubleshooting

### Embedding Model Download

First run downloads bge-large-en-v1.5 (~1.3GB). Be patient.

### Unsupported Language

TLDR supports: Python, TypeScript, JavaScript, Go, Rust, Java, C, C++, Ruby, PHP, C#, Kotlin, Scala, Lua, Elixir.

For other languages, use `tldr tree` and `tldr context` (basic parsing).

### MCP Connection Issues

```bash
# Test MCP server directly
tldr-mcp --project /path/to/project

# Check if running
ps aux | grep tldr-mcp
```
