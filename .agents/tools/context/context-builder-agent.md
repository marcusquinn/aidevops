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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Context Builder Agent

Generates token-efficient repository context using Repomix CLI with Tree-sitter compression (~80% token reduction).

**Full operational guidance:** `tools/context/context-builder.md`

## Quick Start

```bash
# Recommended: compressed pack (~80% token reduction)
context-builder-helper.sh compress [path]

# Full pack
context-builder-helper.sh pack [path] [xml|markdown|json]

# Remote repo
context-builder-helper.sh remote user/repo [branch]
```

Output: `~/.aidevops/.agent-workspace/work/context/`

## Workflow

1. Before complex tasks → `compress` mode
2. Debugging specific dirs → `pack` mode
3. External repos → `remote` mode with compression
4. **Remote repos:** fetch README + check size before packing — see `tools/context/context-builder.md` "Remote Repository Guardrails"
