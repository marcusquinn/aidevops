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
- **Helper**: `compare-models-helper.sh [list|compare|recommend|pricing|context|capabilities|patterns|providers|discover|bench]`
- **Discovery**: `compare-models-helper.sh discover [--probe] [--list-models] [--json]`
- **Pattern data**: `compare-models-helper.sh patterns [--task-type TYPE]` — live success rates from pattern tracker
- **Data sources**: Embedded reference data + live pattern tracker data + optional web fetch for latest pricing

<!-- AI-CONTEXT-END -->

## Usage

### `/compare-models [models...] [--task TASK]`

Full comparison with optional live data fetch from provider pricing pages.

```bash
# Compare specific models
/compare-models claude-sonnet-4-6 gpt-4o gemini-2.5-pro

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
Positional: model names (partial match supported, e.g. "sonnet" matches "claude-sonnet-4-6")
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
~/.aidevops/agents/scripts/compare-models-helper.sh compare claude-sonnet-4-6 gpt-4o

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
| claude-opus-4-6 | Anthropic | 200K | $15.00 | $75.00 | high | Architecture, novel problems |
| claude-sonnet-4-6 | Anthropic | 200K | $3.00 | $15.00 | medium | Code, review, most tasks |
| gpt-4o | OpenAI | 128K | $2.50 | $10.00 | medium | General purpose, multimodal |
| gemini-2.5-pro | Google | 1M | $1.25 | $10.00 | medium | Large context analysis |

### Task Suitability: {task}
Recommended: {model} — {reason}
Runner-up: {model} — {reason}
Budget option: {model} — {reason}
```

### Step 5: Include Pattern Data (t1098)

The helper automatically includes live success rates from the pattern tracker when data exists.
Pattern data appears in `list`, `compare`, `recommend`, `capabilities`, and the dedicated `patterns` command.

```bash
# Focused pattern data view
~/.aidevops/agents/scripts/compare-models-helper.sh patterns

# Filter by task type
~/.aidevops/agents/scripts/compare-models-helper.sh patterns --task-type code-review
```

Example output alongside static specs:

```text
sonnet: $3.00/$15.00 per 1M tokens, 200K context — 85% (n=47) success
```

### Step 5b: Prompt Version Tracking (t1396)

Track which prompt version produced each result. When `--prompt-file` is provided, the git short hash of the last commit that modified the file is automatically resolved as the version. Use `--prompt-version` to set an explicit version tag instead.

```bash
# Record a trace with prompt version (auto-resolved from git)
~/.aidevops/agents/scripts/observability-helper.sh record \
  --model claude-sonnet-4-6 --input-tokens 150 --output-tokens 320 \
  --prompt-file prompts/build.txt

# Score with explicit prompt version
~/.aidevops/agents/scripts/compare-models-helper.sh score \
  --task "review code" --prompt-file prompts/build.txt \
  --model sonnet --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9

# Cross-review with prompt version tracking
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "Review this code" --models "sonnet,opus" \
  --prompt-file prompts/build.txt --score

# Filter results by prompt version
~/.aidevops/agents/scripts/compare-models-helper.sh results --prompt-version a1b2c3d
```

This enables regression detection: run the same dataset against two prompt versions and compare scores.

### Step 6: Provide Actionable Advice

For each comparison, include:

1. **Winner by category**: Best for cost, capability, context, speed
2. **aidevops tier mapping**: How models map to haiku/flash/sonnet/pro/opus tiers
3. **Trade-offs**: What you gain/lose with each choice
4. **Pattern-backed insights**: Which tiers have proven track records for the task type

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

## Live Model Benchmarking (t1393)

Send the same prompt to multiple models and compare actual outputs with latency, tokens, cost, and optional LLM-as-judge quality scoring.

```bash
# Basic benchmark: compare two models on a prompt
~/.aidevops/agents/scripts/compare-models-helper.sh bench "Explain quicksort" claude-sonnet-4-6 gpt-4o

# With LLM-as-judge scoring (haiku-tier, ~$0.001/call)
~/.aidevops/agents/scripts/compare-models-helper.sh bench "Explain quicksort" claude-sonnet-4-6 gpt-4o gemini-2.5-pro --judge

# Benchmark from a dataset file (JSONL, each line: {"prompt":"..."})
~/.aidevops/agents/scripts/compare-models-helper.sh bench --dataset prompts.jsonl claude-sonnet-4-6 gpt-4.1 --judge

# Dry-run: show plan and estimated costs without making API calls
~/.aidevops/agents/scripts/compare-models-helper.sh bench "What is 2+2?" claude-sonnet-4-6 gpt-4o --dry-run

# View historical benchmark results
~/.aidevops/agents/scripts/compare-models-helper.sh bench --history --limit 10
```

### Output format

```text
| Model                  | Latency | Tokens (in/out) | Cost    | Judge Score |
|------------------------|---------|-----------------|---------|-------------|
| claude-sonnet-4-6      | 1.2s    | 150/320         | $0.0062 | 0.92        |
| gpt-4o                 | 0.9s    | 150/290         | $0.0048 | 0.88        |
| gemini-2.5-pro         | 1.8s    | 150/350         | $0.0071 | 0.90        |
```

### Result storage

Results are stored as JSONL at `~/.aidevops/.agent-workspace/observability/bench-results.jsonl` for historical trending:

```jsonl
{"ts":"2026-03-05T10:00:00Z","prompt_hash":"abc123","model":"claude-sonnet-4-6","latency_ms":1200,"tokens_in":150,"tokens_out":320,"cost":0.0062,"judge_score":0.92,"output_hash":"def456"}
```

### Options

| Flag | Description |
|------|-------------|
| `--judge` | Enable LLM-as-judge quality scoring (haiku-tier, ~$0.001/call) |
| `--dataset FILE` | Read prompts from JSONL file (each line: `{"prompt":"..."}`) |
| `--max-tokens N` | Max output tokens per model (default: 1024) |
| `--dry-run` | Show plan and estimated costs without making API calls |
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
