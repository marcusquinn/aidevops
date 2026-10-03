---
description: Compare AI model capabilities, pricing, and context windows across providers
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compare Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Compare AI models by capability, pricing, context window, and dispatch same prompt to several models for side-by-side review
- **Commands**: `/compare-models` (catalog, with optional web fetch for latest pricing), `/compare-models-free` (offline, registry-only)
- **Helper**: `compare-models-helper.sh [list|cross-review|score|results|help]`
- **New model evaluation**: "How good is a new model at our work?" is a different question — see Model Evaluation below, not this catalog

<!-- AI-CONTEXT-END -->

## Two different questions

| Question | Tool |
|----------|------|
| "What models exist, what do they cost, what's their context window?" | `compare-models-helper.sh list` (this doc) |
| "Same prompt, different models — where do the answers diverge?" | `compare-models-helper.sh cross-review` (`/cross-review`) |
| "How good is a new model at our actual work?" | `model-replay`, `model-ab`, `frontier-harness-eval` (Model Evaluation below) |

## Usage

### `/compare-models [--provider NAME]`

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh list
~/.aidevops/agents/scripts/compare-models-helper.sh list --provider Anthropic
```

Reads the live model registry (`model-registry-helper.sh`), synced from subagent
frontmatter, OpenCode's model catalog, and provider APIs.

### `/compare-models-free`

Same as `/compare-models` but skips any web fetch for the latest published
pricing — registry data only.

### `/cross-review --prompt "..."`

Dispatch the same prompt to several models and diff the results:

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "Review this code for security issues: ..."
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "Review this PR diff" --score   # auto-score via judge model
~/.aidevops/agents/scripts/compare-models-helper.sh results
```

Full reference: `workflows/cross-review.md`.

## Model Evaluation ("how good is a new model at our work?")

This catalog answers "what models exist and what do they cost" — it does not
measure quality on real work. For that, use:

- `workflows/model-replay.md` — isolated replay of past tasks against a
  candidate model, scored by deterministic checks. Use when you want a
  repeatable, offline-ish benchmark against tasks this repo has already solved.
- `model-ab-*.mjs` — live A/B enrollment on real issues/PRs, comparing outcomes
  for a candidate model against the current default. Use when you want
  evidence from real dispatched work, not a replay.
- `tools/ai-assistants/frontier-harness-eval.md` — local FrontierHarness pilot
  comparing stock OpenCode against the aidevops plugin/framework guide. Use
  for framework-level (not single-model) comparisons.

Pick model-replay for a quick, controlled check; model-ab for live-traffic
evidence; frontier-harness-eval for framework-vs-stock comparisons.

## Related

- `scripts/commands/compare-models-free.md` - `/compare-models-free` slash command handler
- `scripts/commands/cross-review.md` - `/cross-review` slash command handler
- `tools/context/model-routing.md` - Cost-aware model routing within aidevops
- `workflows/model-replay.md` - Isolated historical task replay for candidate models
- `tools/voice/voice-ai-models.md` - Voice-specific model comparison
- `tools/voice/voice-models.md` - TTS/STT model catalog
