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

The response scoring framework enables structured evaluation of AI model outputs. Unlike `compare-models` which compares model specs (pricing, context windows, capabilities), this framework evaluates **actual responses** to specific prompts.

### When to Use

- Evaluating which model performs best for a specific task type
- Building evidence-based model selection for your workflow
- Comparing model outputs before/after prompt engineering changes
- Creating reproducible benchmarks for your use cases

## Scoring Criteria

All criteria use a 1-5 scale with weighted averaging:

### Correctness (30%)

Factual accuracy and technical correctness of the response.

| Score | Description |
|-------|-------------|
| 1 | Major errors or incorrect approach |
| 2 | Several errors that affect usability |
| 3 | Mostly correct with minor issues |
| 4 | Correct with negligible issues |
| 5 | Fully correct, no errors |

### Completeness (25%)

Coverage of all requirements and edge cases.

| Score | Description |
|-------|-------------|
| 1 | Missing major requirements |
| 2 | Covers some requirements, misses important ones |
| 3 | Covers main requirements, misses edge cases |
| 4 | Comprehensive, misses only minor edge cases |
| 5 | Comprehensive coverage including edge cases |

### Code Quality (25%)

Clean code, best practices, and maintainability.

| Score | Description |
|-------|-------------|
| 1 | Poor structure, no error handling |
| 2 | Basic structure, minimal best practices |
| 3 | Reasonable structure, some best practices |
| 4 | Good structure, follows most best practices |
| 5 | Clean, idiomatic, well-structured with error handling |

### Clarity (20%)

Clear explanation, good formatting, and readability.

| Score | Description |
|-------|-------------|
| 1 | Confusing or poorly organized |
| 2 | Somewhat understandable but disorganized |
| 3 | Understandable but could be clearer |
| 4 | Clear and well-organized |
| 5 | Crystal clear, well-organized, easy to follow |

## Workflow

### Step 1: Create an Evaluation Prompt

```bash
# Simple prompt
response-scoring-helper.sh prompt add \
  --title "FizzBuzz in Python" \
  --text "Write a Python function that prints FizzBuzz for numbers 1-100" \
  --category "coding" \
  --difficulty "easy"

# Prompt from file
response-scoring-helper.sh prompt add \
  --title "REST API Design" \
  --file prompts/rest-api.txt \
  --category "architecture" \
  --difficulty "hard"
```

### Step 2: Record Model Responses

Send the prompt to each model and record the responses:

```bash
# Record response with metadata
response-scoring-helper.sh record \
  --prompt 1 \
  --model claude-sonnet-4 \
  --text "def fizzbuzz():\n    for i in range(1, 101):\n        ..." \
  --time 2.3 \
  --tokens 150 \
  --cost 0.0005

# Record from file
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
  --correctness 5 \
  --completeness 4 \
  --code-quality 5 \
  --clarity 4

response-scoring-helper.sh score \
  --response 2 \
  --correctness 4 \
  --completeness 5 \
  --code-quality 3 \
  --clarity 4
```

### Step 4: Compare Results

```bash
# Side-by-side comparison
response-scoring-helper.sh compare --prompt 1

# JSON output for programmatic use
response-scoring-helper.sh compare --prompt 1 --json
```

### Step 5: View Aggregate Rankings

```bash
# Overall leaderboard
response-scoring-helper.sh leaderboard

# Filter by category
response-scoring-helper.sh leaderboard --category coding

# Export for analysis
response-scoring-helper.sh export --csv > scores.csv
```

## Integration with compare-models

The response scoring framework complements the model comparison tools:

| Tool | Purpose |
|------|---------|
| `compare-models-helper.sh` | Compare model specs (pricing, context, capabilities) |
| `model-availability-helper.sh` | Check which models are available |
| `model-registry-helper.sh` | Track model versions and deprecations |
| **`response-scoring-helper.sh`** | **Evaluate actual model response quality** |

### Typical Workflow

1. Use `compare-models-helper.sh recommend "task"` to identify candidate models
2. Use `model-availability-helper.sh check <model>` to verify availability
3. Use `response-scoring-helper.sh` to evaluate actual outputs
4. Use leaderboard data to inform `model-routing.md` tier assignments

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
- `scripts/model-availability-helper.sh` - Provider health checks
- `scripts/model-registry-helper.sh` - Model version tracking
