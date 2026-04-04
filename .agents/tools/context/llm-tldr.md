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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# llm-tldr - Semantic Code Analysis

TLDR extracts code structure and semantics, saving ~95% tokens vs raw code. Install: `pip install llm-tldr`. Source: [parcadei/llm-tldr](https://github.com/parcadei/llm-tldr). MCP config template: `configs/mcp-templates/llm-tldr.json`.

**vs other tools**: llm-tldr for structure/semantics; rg/Augment for finding code; repomix for full context.

## Commands

CLI: `tldr <cmd>` — MCP (via `tldr-mcp`): same commands prefixed `tldr_`.

| Command | When to use | Purpose |
|---------|-------------|---------|
| `tree /path` | Codebase overview | File structure with line counts |
| `structure file.py` | Before editing | Classes, functions, imports (no impl) |
| `context file.py` | Before editing | Full analysis: imports, signatures, docstrings, types, call graph |
| `impact file.py fn` | Before editing | What would break if this function changes |
| `search "auth logic" /path` | Exploration | Semantic search (bge-large-en-v1.5, 1024-dim) |
| `cfg file.py fn` | Code review | Control flow graph for a function |
| `dfg file.py fn` | Code review | Data flow / variable dependencies |
| `dead /path` | Code review | Unused functions and classes |
| `slice file.py var` | Debugging | Code slice affecting a variable |

## Troubleshooting

- **First run**: downloads bge-large-en-v1.5 (~1.3GB)
- **Unsupported language**: supports Python, TypeScript, JavaScript, Go, Rust, Java, C, C++, Ruby, PHP, C#, Kotlin, Scala, Lua, Elixir — others fall back to `tldr tree` + `tldr context` (basic parsing)
- **MCP issues**: `tldr-mcp --project /path/to/project` to test; `ps aux | grep tldr-mcp` to check running
