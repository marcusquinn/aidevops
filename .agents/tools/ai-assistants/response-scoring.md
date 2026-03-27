---
description: Evaluate and score AI model responses side-by-side with structured criteria
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
model: sonnet
---

# Response Scoring Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Evaluate AI model responses against structured scoring criteria
- **Command**: `/score-responses` (interactive evaluation)
- **Helper**: `response-scoring-helper.sh [init|prompt|record|score|compare|leaderboard|export|history|criteria]`
- **Criteria**: Correctness (30%), Completeness (25%), Code Quality (25%), Clarity (20%)
- **Storage**: SQLite at `~/.aidevops/.agent-workspace/response-scoring.db`

<!-- AI-CONTEXT-END -->

## Overview

Enables structured evaluation of actual AI model outputs. Unlike `compare-models` (which compares specs — pricing, context windows, capabilities), this framework evaluates **actual responses** to specific prompts.

**When to use**: evaluating model fit for a task type, benchmarking prompt engineering changes, building evidence-based model selection.

## Scoring Criteria (1–5 scale, weighted average)

| Criterion | Weight | 1 | 3 | 5 |
|-----------|--------|---|---|---|
| Correctness | 30% | Major errors | Mostly correct, minor issues | Fully correct |
| Completeness | 25% | Missing major requirements | Covers main requirements, misses edge cases | Comprehensive, all edge cases |
| Code Quality | 25% | Poor structure, no error handling | Reasonable structure, some best practices | Clean, idiomatic, well-structured |
| Clarity | 20% | Confusing, poorly organized | Understandable but could be clearer | Crystal clear, well-organized |

Scores 2 and 4 fall between the anchors above.

## Workflow

### Step 1: Create an Evaluation Prompt

```bash
response-scoring-helper.sh prompt add \
  --title "FizzBuzz in Python" \
  --text "Write a Python function that prints FizzBuzz for numbers 1-100" \
  --category "coding" \
  --difficulty "easy"

# From file
response-scoring-helper.sh prompt add \
  --title "REST API Design" \
  --file prompts/rest-api.txt \
  --category "architecture" \
  --difficulty "hard"
```

### Step 2: Record Model Responses

```bash
response-scoring-helper.sh record \
  --prompt 1 \
  --model claude-sonnet-4-6 \
  --text "def fizzbuzz():\n    for i in range(1, 101):\n        ..." \
  --time 2.3 \
  --tokens 150 \
  --cost 0.0005

response-scoring-helper.sh record \
  --prompt 1 \
  --model gpt-4o \
  --file responses/gpt4o-fizzbuzz.txt \
  --time 1.8 \
  --tokens 180 \
  --cost 0.0006
```

### Step 3: Score Each Response

```bash
response-scoring-helper.sh score \
  --response 1 \
  --correctness 5 --completeness 4 --code-quality 5 --clarity 4

response-scoring-helper.sh score \
  --response 2 \
  --correctness 4 --completeness 5 --code-quality 3 --clarity 4
```

### Step 4: Compare Results

```bash
response-scoring-helper.sh compare --prompt 1
response-scoring-helper.sh compare --prompt 1 --json   # programmatic use
```

### Step 5: View Aggregate Rankings

```bash
response-scoring-helper.sh leaderboard
response-scoring-helper.sh leaderboard --category coding
response-scoring-helper.sh export --csv > scores.csv
```

## Integration with compare-models

| Tool | Purpose |
|------|---------|
| `compare-models-helper.sh` | Compare model specs (pricing, context, capabilities) |
| `model-availability-helper.sh` | Check which models are available |
| `model-registry-helper.sh` | Track model versions and deprecations |
| **`response-scoring-helper.sh`** | **Evaluate actual model response quality** |

**Typical workflow**: `compare-models-helper.sh recommend "task"` → `model-availability-helper.sh check <model>` → `response-scoring-helper.sh` → use leaderboard data to inform `model-routing.md` tier assignments.

## Pattern Tracker Integration (t1099)

Scoring results automatically feed into the shared pattern tracker database:

- **On score**: recorded as `SUCCESS_PATTERN` (weighted avg ≥ 3.5/5.0) or `FAILURE_PATTERN` (< 3.5/5.0), tagged with model tier and task category.
- **On compare**: winner among 2+ models recorded as `SUCCESS_PATTERN` with comparison metadata.
- **Bulk sync**: `response-scoring-helper.sh sync` (use `--dry-run` to preview).
- **Disable sync**: `SCORING_NO_PATTERN_SYNC=1`
- **Model tier mapping**: full model names (e.g., `claude-sonnet-4-6`) auto-mapped to routing tiers (`sonnet`).

Enables `/route <task>` and `/patterns recommend --task-type <type>` to use real A/B data for model selection.

## Database Schema

```sql
prompts     -- Evaluation prompts with category and difficulty
responses   -- Model responses with timing and cost metadata
scores      -- Per-criterion scores (1-5) with scorer attribution
comparisons -- Comparison records with winner tracking
```

## Related

- `tools/ai-assistants/compare-models.md` - Model spec comparison
- `tools/context/model-routing.md` - Cost-aware model routing
- Cross-session memory system - Pattern tracking and model recommendations (replaces archived `pattern-tracker-helper.sh`)
- `scripts/model-availability-helper.sh` - Provider health checks
- `scripts/model-registry-helper.sh` - Model version tracking
