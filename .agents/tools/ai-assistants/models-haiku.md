---
description: Lightweight model for triage, classification, and simple transforms
mode: subagent
model: anthropic/claude-haiku-4-5-20251001
model-tier: haiku
model-fallback: google/gemini-2.5-flash-preview-05-20
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

# Haiku Tier Model

Lowest-cost tier for fast, simple tasks where reasoning depth is not required.

## Use For

- Classification and triage (bug vs feature, priority assignment)
- Simple text transforms (rename, reformat, extract fields)
- Commit message generation from diffs
- Routing decisions (which subagent to use)

## Routing Rules

- Default to haiku only when the task is clearly classification, formatting, or simple extraction.
- Route code writing, debugging, and review → sonnet.
- Route architecture decisions and novel problems → opus.

## Constraints

- Keep responses under 500 tokens when possible.
- Do not attempt complex reasoning or architecture decisions — escalate to sonnet or opus.
- Prioritize speed over thoroughness.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-haiku-4-5 |
| Context | 200K tokens |
| Max output | 64K tokens |
| Input cost | $1.00/1M tokens |
| Output cost | $5.00/1M tokens |
| Tier | haiku (lowest cost) |
