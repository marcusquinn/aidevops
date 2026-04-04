---
description: Balanced model for code implementation, review, and most development tasks
mode: subagent
model: anthropic/claude-sonnet-4-6
model-tier: sonnet
model-fallback: openai/gpt-5.3-codex
fallback-chain:
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.3-codex
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-6
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

# Sonnet Tier Model (Default)

Default tier for most development work: balanced capability, cost, and speed.

## Use For

- Code writing, debugging, review, and test authoring
- Documentation derived from code
- Interactive development tasks

## Routing Rules

- Default: use sonnet unless the task clearly needs less, more, or much larger context.
- Route simple classification and formatting → haiku.
- Route architecture decisions and novel problems → opus.
- Route very large context needs (100K+ tokens) → pro.

## Constraints

- Do not use for tasks that are purely classification or reformatting — route to haiku.
- Do not use for novel architecture decisions or complex trade-offs — route to opus.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-sonnet-4-6 |
| Context | 200K tokens (1M beta) |
| Max output | 64K tokens |
| Training cutoff | January 2026 |
| Input cost | $3.00/1M tokens |
| Output cost | $15.00/1M tokens |
| Tier | sonnet (default, balanced) |
