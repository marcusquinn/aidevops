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
model: sonnet
---

# Compare Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Compare AI models by capability, pricing, context window, and task suitability
- **Commands**: `/compare-models` (full, with web fetch), `/compare-models-free` (offline, embedded data)
- **Helper**: `compare-models-helper.sh [list|compare|recommend|pricing|context|providers|capabilities|discover]`
- **Discovery**: `compare-models-helper.sh discover [--probe] [--list-models] [--json]`
- **Data sources**: Embedded reference data + optional live web fetch for latest pricing

<!-- AI-CONTEXT-END -->

## Usage

### `/compare-models [models...] [--task TASK]`

Full comparison with optional live data fetch from provider pricing pages.

```bash
# Compare specific models
/compare-models claude-sonnet-4 gpt-4o gemini-2.5-pro

# Compare by task suitability
/compare-models --task "code review"

# Compare all models in a tier
/compare-models --tier medium

# Show pricing for all tracked models
/compare-models --pricing
```

### `/compare-models-free [models...] [--task TASK]`

Offline comparison using only embedded reference data. No web fetches, no API calls.
Useful when working without internet or to avoid token spend on web fetches.

## Workflow

### Step 1: Parse Arguments

```text
Positional: model names (partial match supported, e.g. "sonnet" matches "claude-sonnet-4")
Options:
  --task DESCRIPTION    Recommend models for a specific task type
  --tier low|medium|high  Filter by cost tier
  --pricing             Show pricing table only
  --context             Show context window comparison only
  --capabilities        Show capability matrix only
  --providers           List supported providers
  --free                Use offline data only (same as /compare-models-free)
```

### Step 2: Gather Data

Run the helper script to get structured model data:

```bash
# List all tracked models
~/.aidevops/agents/scripts/compare-models-helper.sh list

# Compare specific models
~/.aidevops/agents/scripts/compare-models-helper.sh compare claude-sonnet-4 gpt-4o

# Get recommendation for a task
~/.aidevops/agents/scripts/compare-models-helper.sh recommend "code review"

# Pricing table
~/.aidevops/agents/scripts/compare-models-helper.sh pricing
```

### Step 3: Enrich with Live Data (full mode only)

For `/compare-models` (not `/compare-models-free`), optionally fetch latest pricing:

- Anthropic: `https://docs.anthropic.com/en/docs/about-claude/models`
- OpenAI: `https://platform.openai.com/docs/models`
- Google: `https://ai.google.dev/pricing`

Cross-reference fetched data against embedded data and note any discrepancies.

### Step 4: Present Comparison

Output a structured comparison table:

```markdown
## Model Comparison

| Model | Provider | Context | Input $/1M | Output $/1M | Tier | Best For |
|-------|----------|---------|-----------|------------|------|----------|
| claude-opus-4 | Anthropic | 200K | $15.00 | $75.00 | high | Architecture, novel problems |
| claude-sonnet-4 | Anthropic | 200K | $3.00 | $15.00 | medium | Code, review, most tasks |
| gpt-4o | OpenAI | 128K | $2.50 | $10.00 | medium | General purpose, multimodal |
| gemini-2.5-pro | Google | 1M | $1.25 | $10.00 | medium | Large context analysis |

### Task Suitability: {task}
Recommended: {model} — {reason}
Runner-up: {model} — {reason}
Budget option: {model} — {reason}
```

### Step 5: Provide Actionable Advice

For each comparison, include:

1. **Winner by category**: Best for cost, capability, context, speed
2. **aidevops tier mapping**: How models map to haiku/flash/sonnet/pro/opus tiers
3. **Trade-offs**: What you gain/lose with each choice

## Model Discovery

Before comparing models, discover which providers the user has configured:

```bash
# Quick check: which providers have API keys configured?
~/.aidevops/agents/scripts/compare-models-helper.sh discover

# Verify keys actually work by probing provider APIs
~/.aidevops/agents/scripts/compare-models-helper.sh discover --probe

# List all live models from each verified provider
~/.aidevops/agents/scripts/compare-models-helper.sh discover --list-models

# Machine-readable output for scripting
~/.aidevops/agents/scripts/compare-models-helper.sh discover --json
```

Discovery checks three sources for API keys (in order):
1. Environment variables (e.g., `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)
2. gopass encrypted secrets (`aidevops/<KEY_NAME>`)
3. Plaintext credentials (`~/.config/aidevops/credentials.sh`)

Use discovery output to filter `/compare-models` to only show models the user can actually use.

## Related

- `tools/ai-assistants/response-scoring.md` - Evaluate actual model response quality
- `tools/context/model-routing.md` - Cost-aware model routing within aidevops
- `tools/voice/voice-ai-models.md` - Voice-specific model comparison
- `tools/voice/voice-models.md` - TTS/STT model catalog
