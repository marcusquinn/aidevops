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

Highest-capability tier for tasks where stronger reasoning materially changes the outcome.

## Use For

- Architecture and system design decisions
- Novel problems with no established pattern to follow
- Security audits that require deep reasoning
- Multi-step plans with hard dependencies
- Trade-off analysis across many variables
- Evaluating other models' outputs

## Routing Rules

- Use opus only when the task genuinely needs the extra reasoning depth.
- Default most implementation work to sonnet.
- Use pro when the main constraint is large context, not judgment.
- Justify the spend: opus costs about 1.7x sonnet ($5/$25 vs $3/$15 per 1M input/output tokens).

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
