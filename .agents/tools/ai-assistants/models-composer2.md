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

# Composer 2 Tier Model (Frontier Coding)

Use Cursor Composer 2 for complex coding tasks where implementation quality matters more than cost.

## Best Fit

- Multi-file features spanning 5+ files
- Large refactors across existing patterns or subsystems
- Code generation where correctness reduces review cost
- Complex test writing for non-trivial modules

## Avoid When

- The change is simple or single-file — use `sonnet`
- The task is primarily architecture or novel design — use `opus`
- The task is primarily large-context analysis (>100K tokens) — use `pro`

## Constraints

- Requires the Cursor OAuth pool in `oauth-pool.mjs` (t1549)
- Falls back to `sonnet` if no Cursor account is available
- Tier focus: frontier coding and deep code-pattern reasoning

## Model Details

| Field | Value |
|-------|-------|
| Provider | Cursor |
| Model | composer-2 |
| Context | 200K tokens |
| Input cost | $0.50/1M tokens |
| Output cost | $2.50/1M tokens |
| Tier | composer2 (frontier coding) |
| Requires | Cursor OAuth pool (t1549) |
