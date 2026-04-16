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

## Opus 4.7 (opt-in)

Available as `claude-opus-4-7` in the OpenCode model picker (released 2026-04-16). Not wired as the default for any tier — framework defaults remain on `claude-opus-4-6`. Opt in explicitly via `custom/configs/model-routing-table.json` if you want to route specific tiers or agents to 4.7.

The framework registers 4.7 with a **250K context limit** even though the API accepts 1M, because the 1M window is functionally broken for retrieval tasks (see tradeoffs below). The 250K figure is sized so OpenCode's 80% auto-compact threshold triggers at the **200K reliability boundary** — sessions get the full still-functional window before compaction kicks in, instead of compacting prematurely at 160K (which is what an unaligned 200K cap produces).

### Tradeoffs vs 4.6

- **Long-context retrieval regression** (MRCR v2 8-needle, Anthropic's own system card §8.7.2):
  - 256K: 91.9% → 59.2% (−32.7 pts)
  - 1M: 78.3% → 32.2% (−46.1 pts)
  - For any worker that ingests large context (full-loop, cross-file refactors, whole-repo audits), this is a functional regression. Do not use 4.7 for long-session or large-codebase work.
- **Tokenizer bloat** (same paragraph, new 4.7-only tokenizer):
  - English: +58.8% tokens vs 4.6 (135 vs 85)
  - French: +34.0%, Python: +21.4%, mixed multilingual: +22.8%
  - CJK (Korean/Japanese/Chinese): +4-6% (minor — old tokenizer was already inefficient there)
  - At identical per-token pricing ($5/$25), this is a 20-60% effective cost increase on English-heavy prompts. Framework prompts and issue bodies are English-heavy.
- **Stricter literal instruction-following**: prompts tuned for 4.6's looser interpretation may behave unexpectedly. Re-tune prompts before using 4.7 for agentic workloads. Anthropic's migration guide acknowledges this explicitly.

### When 4.7 may be worth it

- Short-context, well-structured one-shot coding tasks where long-context regression doesn't apply (strong SWE-Bench gains reported).
- Tasks that benefit from the new `xhigh` effort level.
- Vision work on high-resolution images (4.7 supports up to 2576px on long edge, ~3.75MP — more than 3× prior Claude models).

### Migration guide

<https://platform.claude.com/docs/en/about-claude/models/migration-guide#migrating-to-claude-opus-4-7>
