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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compare Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Compare AI models by capability, pricing, context window, and task suitability
- **Commands**: `/compare-models` (full, with web fetch), `/compare-models-free` (offline, embedded data)
- **Helper**: `compare-models-helper.sh [list|compare|recommend|pricing|context|capabilities|patterns|providers|discover|bench]`
- **Discovery**: `compare-models-helper.sh discover [--probe] [--list-models] [--json]`
- **Pattern data**: `compare-models-helper.sh patterns [--task-type TYPE]` — live success rates from pattern tracker
- **Data sources**: Embedded reference data + live pattern tracker data + optional web fetch for latest pricing

<!-- AI-CONTEXT-END -->

## Usage

### `/compare-models [models...] [--task TASK]`

```bash
/compare-models claude-sonnet-4-6 gpt-4o gemini-2.5-pro
/compare-models --task "code review"   # --tier low|medium|high
/compare-models --pricing              # --context --capabilities --providers --free
```

### `/compare-models-free [models...] [--task TASK]`

Offline comparison using only embedded reference data. No web fetches, no API calls.

## Workflow

### Gather Data

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh list
~/.aidevops/agents/scripts/compare-models-helper.sh compare claude-sonnet-4-6 gpt-4o
~/.aidevops/agents/scripts/compare-models-helper.sh recommend "code review"
~/.aidevops/agents/scripts/compare-models-helper.sh pricing
```

### Enrich with Live Data (full mode only)

- Anthropic: `https://docs.anthropic.com/en/docs/about-claude/models`
- OpenAI: `https://platform.openai.com/docs/models`
- Google: `https://ai.google.dev/pricing`

### Present Comparison

```markdown
| Model | Provider | Context | Input $/1M | Output $/1M | Tier | Best For |
|-------|----------|---------|-----------|------------|------|----------|
| claude-opus-4-6 | Anthropic | 200K | $15.00 | $75.00 | high | Architecture, novel problems |
| claude-sonnet-4-6 | Anthropic | 200K | $3.00 | $15.00 | medium | Code, review, most tasks |
| gpt-4o | OpenAI | 128K | $2.50 | $10.00 | medium | General purpose, multimodal |
| gemini-2.5-pro | Google | 1M | $1.25 | $10.00 | medium | Large context analysis |

### Task Suitability: {task}
Recommended: {model} — {reason}
Runner-up: {model} — {reason}
Budget option: {model} — {reason}
```

### Pattern Data (t1098)

```text
sonnet: $3.00/$15.00 per 1M tokens, 200K context — 85% (n=47) success
```

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh patterns
~/.aidevops/agents/scripts/compare-models-helper.sh patterns --task-type code-review
```

### Prompt Version Tracking (t1396)

`--prompt-file` auto-resolves git short hash as version; `--prompt-version` sets explicit tag. Enables regression detection across prompt versions.

```bash
~/.aidevops/agents/scripts/observability-helper.sh record \
  --model claude-sonnet-4-6 --input-tokens 150 --output-tokens 320 \
  --prompt-file prompts/build.txt

~/.aidevops/agents/scripts/compare-models-helper.sh score \
  --task "review code" --prompt-file prompts/build.txt \
  --model sonnet --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9

~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "Review this code" --models "sonnet,opus" \
  --prompt-file prompts/build.txt --score

~/.aidevops/agents/scripts/compare-models-helper.sh results --prompt-version a1b2c3d
```

### Actionable Advice

For each comparison include:

1. **Winner by category**: Best for cost, capability, context, speed
2. **aidevops tier mapping**: How models map to haiku/flash/sonnet/pro/opus tiers
3. **Trade-offs**: What you gain/lose with each choice
4. **Pattern-backed insights**: Which tiers have proven track records for the task type

## Model Discovery

Run before comparing to filter results to models the user can actually use:

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh discover           # check configured API keys
~/.aidevops/agents/scripts/compare-models-helper.sh discover --probe   # verify keys work
~/.aidevops/agents/scripts/compare-models-helper.sh discover --list-models  # list live models
~/.aidevops/agents/scripts/compare-models-helper.sh discover --json    # machine-readable
```

Key lookup order: env vars → gopass secrets → `~/.config/aidevops/credentials.sh`.

## Live Model Benchmarking (t1393)

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh bench "Explain quicksort" claude-sonnet-4-6 gpt-4o
~/.aidevops/agents/scripts/compare-models-helper.sh bench "Explain quicksort" claude-sonnet-4-6 gpt-4o gemini-2.5-pro --judge
~/.aidevops/agents/scripts/compare-models-helper.sh bench --dataset prompts.jsonl claude-sonnet-4-6 gpt-4.1 --judge
~/.aidevops/agents/scripts/compare-models-helper.sh bench "What is 2+2?" claude-sonnet-4-6 gpt-4o --dry-run
~/.aidevops/agents/scripts/compare-models-helper.sh bench --history --limit 10
```

Output format:

```text
| Model                  | Latency | Tokens (in/out) | Cost    | Judge Score |
|------------------------|---------|-----------------|---------|-------------|
| claude-sonnet-4-6      | 1.2s    | 150/320         | $0.0062 | 0.92        |
| gpt-4o                 | 0.9s    | 150/290         | $0.0048 | 0.88        |
| gemini-2.5-pro         | 1.8s    | 150/350         | $0.0071 | 0.90        |
```

Results stored at `~/.aidevops/.agent-workspace/observability/bench-results.jsonl`.

| Flag | Description |
|------|-------------|
| `--judge` | LLM-as-judge quality scoring (haiku-tier, ~$0.001/call) |
| `--dataset FILE` | Read prompts from JSONL file (`{"prompt":"..."}` per line) |
| `--max-tokens N` | Max output tokens per model (default: 1024) |
| `--dry-run` | Show plan and estimated costs without API calls |
| `--history` | Show historical benchmark results |
| `--limit N` | Limit history output (default: 20) |
| `--version TAG` | Tag results with a prompt version (e.g., git short hash) |

## Related

- `scripts/commands/compare-models-free.md` - `/compare-models-free` slash command handler
- `scripts/commands/score-responses.md` - `/score-responses` slash command handler
- `scripts/commands/route.md` - `/route` slash command handler
- `tools/ai-assistants/response-scoring.md` - Evaluate actual model response quality
- `tools/context/model-routing.md` - Cost-aware model routing within aidevops
- Cross-session memory system - Pattern data source for live success rates (replaces archived `pattern-tracker-helper.sh`)
- `tools/voice/voice-ai-models.md` - Voice-specific model comparison
- `tools/voice/voice-models.md` - TTS/STT model catalog
