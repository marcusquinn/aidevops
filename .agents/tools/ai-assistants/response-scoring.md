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

## When to Use

- Evaluating which model performs best for a specific task type
- Building evidence-based model selection for your workflow
- Comparing model outputs before/after prompt engineering changes
- Creating reproducible benchmarks for your use cases

Distinct from `compare-models` (model specs) — this evaluates **actual responses**.

## Scoring Criteria (1–5 scale, weighted average)

| Criterion | Weight | 1 | 3 | 5 |
|-----------|--------|---|---|---|
| Correctness | 30% | Major errors | Mostly correct, minor issues | Fully correct |
| Completeness | 25% | Missing major requirements | Covers main, misses edge cases | Comprehensive including edge cases |
| Code Quality | 25% | Poor structure, no error handling | Reasonable structure, some best practices | Clean, idiomatic, well-structured |
| Clarity | 20% | Confusing, poorly organized | Understandable but could be clearer | Crystal clear, well-organized |

## Workflow

### 1. Create an Evaluation Prompt

```bash
response-scoring-helper.sh prompt add \
  --title "FizzBuzz in Python" \
  --text "Write a Python function..." \
  --category "coding" \
  --difficulty "easy"
# Or from file: --file prompts/rest-api.txt
```

### 2. Record Model Responses

```bash
response-scoring-helper.sh record \
  --prompt 1 \
  --model claude-sonnet-4-6 \
  --text "def fizzbuzz():..." \
  --time 2.3 --tokens 150 --cost 0.0005
# Or from file: --file responses/gpt4o-output.txt
```

### 3. Score Each Response

```bash
response-scoring-helper.sh score \
  --response 1 \
  --correctness 5 --completeness 4 --code-quality 5 --clarity 4
```

### 4. Compare and Rank

```bash
response-scoring-helper.sh compare --prompt 1        # or --json
response-scoring-helper.sh leaderboard               # or --category coding
response-scoring-helper.sh export --csv > scores.csv
```

## Integration with compare-models

| Tool | Purpose |
|------|---------|
| `compare-models-helper.sh recommend "task"` | Identify candidate models by spec |
| `model-availability-helper.sh check <model>` | Verify model is available |
| `response-scoring-helper.sh` | **Evaluate actual response quality** |
| `model-routing.md` | Use leaderboard data to inform tier assignments |

## Pattern Tracker Integration (t1099)

Scores feed into the shared pattern tracker database:

- **On score**: Recorded as `SUCCESS_PATTERN` (weighted avg >= 3.5/5.0) or `FAILURE_PATTERN` (< 3.5/5.0), tagged with model tier and task category
- **On compare**: Winner recorded as `SUCCESS_PATTERN` with comparison metadata
- **Bulk sync**: `response-scoring-helper.sh sync` (use `--dry-run` to preview)
- **Disable sync**: `SCORING_NO_PATTERN_SYNC=1`
- **Model tier mapping**: Full names (e.g., `claude-sonnet-4-6`) auto-mapped to routing tiers (`sonnet`)

Enables `/route <task>` and `/patterns recommend --task-type <type>` to use real A/B data.

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
