---
description: Lightweight model for triage, classification, and simple transforms
mode: subagent
model: anthropic/claude-haiku-5-5
model-tier: simple
model-fallback: google/gemini-2.5-flash-preview-05-20
fallback-chain:
  - anthropic/claude-haiku-5-5
  - anthropic/claude-haiku-4-5-20251001
  - google/gemini-2.5-flash-preview-05-20
  - openrouter/anthropic/claude-haiku-4-5
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Anthropic Haiku Model Profile

Concrete model profile that the runtime routing table may select for `simple`
work. Task and agent authors request a workload tier, never this provider family.

## Routing Rules

- Map this profile only into `simple` when current cost, availability, and
  equivalent-workload evidence support it.
- Route implementation and review work through `standard`.
- Route architecture decisions and novel problems through `thinking`.

## Use For

- Classification and triage (bug vs feature, priority assignment)
- Simple text transforms (rename, reformat, extract fields)
- Commit message generation from diffs
- Routing decisions (which subagent to use)

## Constraints

- Keep responses under 500 tokens when possible.
- Do not attempt unresolved implementation or architecture decisions — escalate
  to `standard` or `thinking`.
- Prioritize speed over thoroughness.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-haiku-5-5 (released 2026-10-07; fixed ID, no dated snapshot) |
| Context | 1M tokens |
| Max output | 128K tokens |
| Training cutoff | June 2026 ([Claude Haiku 5.5 overview](https://platform.claude.com/docs/en/models/haiku-5-5/overview)) |
| Input cost | $0.10/1M tokens for prompts up to 100K tokens; $0.50/1M above |
| Output cost | $0.50/1M tokens for prompts up to 100K tokens; $2.50/1M above |
| Cache read / 5m write | $0.01 / $0.125 per 1M tokens up to 100K; $0.05 / $0.625 above |
| Thinking | Adaptive, on by default; effort `low`–`max`, API default `medium` |
| Workload tier | Candidate for `simple` (aidevops routes it at `medium`) |

Source: [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing).
Previous model `claude-haiku-4-5` (200K context, $1/$5) stays available.

## Haiku 5.5 Caveats

- **Prompt-length pricing**: a request whose prompt exceeds 100,000 tokens pays
  5x on every token class. aidevops cost estimates use the base tier only.
- **Direct Messages API callers** (not OpenCode): omit `temperature`, `top_p`
  and `top_k`; a non-default value returns 400. Assistant prefill returns 400.
  Thinking is on by default and counts toward `max_tokens`, so select response
  blocks by `type` and leave room for thinking. See the
  [migration guide](https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide).
- **Tokenizer**: the same text counts about 30% more tokens than on Haiku 4.5.
