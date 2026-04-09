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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Opus Tier Model

Highest-capability tier for tasks where stronger reasoning materially changes the outcome.

## Use For

- Architecture and system design decisions
- Novel problems with no established pattern
- Security audits requiring deep reasoning
- Multi-step plans with hard dependencies
- Trade-off analysis across many variables
- Evaluating other models' outputs

## Routing Rules

- Default to sonnet unless the task genuinely needs extra reasoning depth.
- Route routine implementation, code review, and docs → sonnet.
- Route very large context needs (100K+ tokens) → pro.

## Constraints

- Do not use for tasks solvable by sonnet — opus costs 5× more per output token.
- Do not use for simple classification or formatting — route to haiku.

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
