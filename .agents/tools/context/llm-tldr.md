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

TLDR extracts code structure and semantics, saving ~95% tokens vs raw code.

**Source**: [parcadei/llm-tldr](https://github.com/parcadei/llm-tldr)

## Installation

```bash
pip install llm-tldr
```

## MCP Server (OpenCode)

```json
{
  "llm-tldr": {
    "command": "tldr-mcp",
    "args": ["--project", "${workspaceFolder}"]
  }
}
```

Template: `configs/mcp-templates/llm-tldr.json`

## CLI Commands

| Command | Usage | Purpose |
|---------|-------|---------|
| `tree` | `tldr tree /path/to/project` | File structure with line counts |
| `structure` | `tldr structure /path/to/file.py` | Classes, functions, imports (no impl) |
| `context` | `tldr context /path/to/file.py` | Full analysis: imports, signatures, docstrings, types, call graph |
| `cfg` | `tldr cfg /path/to/file.py fn_name` | Control flow graph for a function |
| `dfg` | `tldr dfg /path/to/file.py fn_name` | Data flow / variable dependencies |
| `search` | `tldr search "auth logic" /path` | Semantic search (bge-large-en-v1.5, 1024-dim) |
| `impact` | `tldr impact /path/to/file.py fn_name` | What would break if this function changes |
| `dead` | `tldr dead /path/to/project` | Unused functions and classes |
| `slice` | `tldr slice /path/to/file.py var_name` | Code slice affecting a variable |

## MCP Tools (via tldr-mcp)

Same commands as CLI, prefixed `tldr_`: `tldr_tree`, `tldr_structure`, `tldr_context`, `tldr_cfg`, `tldr_dfg`, `tldr_search`, `tldr_impact`, `tldr_dead`, `tldr_slice`.

## Token Savings

| Content Type | Raw Tokens | TLDR Tokens | Savings |
|--------------|------------|-------------|---------|
| 1000-line file | ~15,000 | ~750 | 95% |
| Class definition | ~500 | ~50 | 90% |
| Function body | ~200 | ~20 | 90% |

## When to Use

- **Before editing**: `tldr context` + `tldr impact` to understand scope
- **Codebase exploration**: `tldr search` for concepts, `tldr tree` for overview
- **Code review**: `tldr dead` for unused code, `tldr dfg` for data flow

**vs other tools**: llm-tldr for structure/semantics; rg/Augment for finding code; repomix for full context.

## Integration with Memory System

```bash
~/.aidevops/agents/scripts/memory-helper.sh store "CODEBASE_PATTERN" \
  "Auth flow: validate_token -> check_permissions -> authorize" \
  "auth,flow,pattern" "myproject"
```

## Troubleshooting

- **First run**: downloads bge-large-en-v1.5 (~1.3GB)
- **Unsupported language**: supports Python, TypeScript, JavaScript, Go, Rust, Java, C, C++, Ruby, PHP, C#, Kotlin, Scala, Lua, Elixir. Others: use `tldr tree` + `tldr context` (basic parsing)
- **MCP issues**: `tldr-mcp --project /path/to/project` to test; `ps aux | grep tldr-mcp` to check running
