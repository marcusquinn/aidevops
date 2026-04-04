---
description: Frontier-level coding model via Cursor Composer 2 — complex multi-file implementation and large refactors
mode: subagent
model: cursor/composer-2
model-tier: composer2
model-fallback: anthropic/claude-sonnet-4-6
fallback-chain:
  - cursor/composer-2
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.3-codex
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Composer 2 Tier Model (Frontier Coding)

Cursor Composer 2 for complex coding tasks where implementation quality matters more than cost.
Context: 200K tokens. Cost: $0.50/1M input, $2.50/1M output. Requires Cursor OAuth pool (t1549).

## Best Fit

- Multi-file features spanning 5+ files
- Large refactors across existing patterns or subsystems
- Code generation where correctness reduces review cost
- Complex test writing for non-trivial modules

## Avoid When

- Simple or single-file change — use `sonnet`
- Primarily architecture or novel design — use `opus`
- Primarily large-context analysis (>100K tokens) — use `pro`
