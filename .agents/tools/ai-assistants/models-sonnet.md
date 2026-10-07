---
description: Balanced model for code implementation, review, and most development tasks
mode: subagent
model: anthropic/claude-sonnet-5-5
model-tier: standard
model-fallback: openai/gpt-5.4
fallback-chain:
  - anthropic/claude-sonnet-5-5
  - openai/gpt-5.4
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-5-5
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

# Anthropic Sonnet Model Profile

Concrete model profile that the runtime routing table may select for `standard`
work. Task and agent authors request a workload tier, never this provider family.

## Use For

- Code writing, debugging, review, and test authoring
- Documentation derived from code
- Interactive development tasks

## Routing Rules

- Map this profile into a tier only when current capability, cost, availability,
  and equivalent-workload evidence support it.
- Route bounded classification and formatting through `simple`.
- Route architecture decisions and novel problems through `thinking`.
- Treat large-context requirements as routing evidence, not a provider-named tier.

## Constraints

- Do not use for work classified as `simple` when a cheaper routed model is reliable.
- Do not use for `thinking` work unless the active routing table selects it.
- Sonnet 5.5 with thinking off needs Anthropic's `between_tools` thinking
  setting; the old thinking-off form does not carry over. See Anthropic's
  Sonnet 5.5 migration guide.
- Higher-risk cybersecurity requests visibly fall back to Sonnet 5 under
  Anthropic's cyber safeguards; routine software work is unaffected.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-sonnet-5-5 (released 2026-09-28) |
| Context | 1M tokens |
| Max output | 128K tokens |
| Input cost | $2.00/1M tokens |
| Output cost | $10.00/1M tokens |
| Cache read / write | $0.10 / $2.50 per 1M tokens (cache read is 0.05x input) |
| Effort defaults | Medium in Claude Code/apps, High on the Claude Platform |
| Workload tier | Candidate for `standard` |

Source: Anthropic launch announcement (`anthropic.com/claude-sonnet-5-5`);
context, output and cache read re-checked against Anthropic's pricing page and
Haiku 5.5 model comparison on 2026-10-07.
Same price as Sonnet 5, 30%+ faster output, and up to 30% lower cost per task.
