---
description: Highest-capability model for architecture decisions, novel problems, and complex multi-step reasoning
mode: subagent
model: anthropic/claude-opus-4-6
model-tier: opus
model-fallback: openai/gpt-5.4
fallback-chain:
  - anthropic/claude-opus-4-6
  - openai/gpt-5.4
  - anthropic/claude-sonnet-4-6
  - openrouter/anthropic/claude-opus-4-6
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

# Opus Tier Model

## When to Use

- Architecture and system design decisions
- Novel problems with no established pattern
- Security audits requiring deep reasoning
- Multi-step plans with hard dependencies
- Trade-off analysis across many variables
- Evaluating other models' outputs
- Do not use for routine implementation — route to sonnet; large-context (100K+ tokens) → pro

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-opus-4-6 |
| Context | 200K tokens (1M beta) |
| Max output | 128K tokens |
| Input cost | $5.00/1M tokens |
| Output cost | $25.00/1M tokens |
| Tier | opus (highest capability, highest cost) |
