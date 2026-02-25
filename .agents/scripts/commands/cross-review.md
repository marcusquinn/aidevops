---
description: Dispatch a prompt to multiple AI models, diff results, and optionally score via a judge model
agent: Build+
mode: subagent
---

Run a multi-model adversarial review: dispatch the same prompt to N models in parallel, collect outputs, diff results, and optionally score via a judge model (Ouroboros-style pipeline).

Target: $ARGUMENTS

## Instructions

1. Parse the user's arguments. Common forms:

   ```bash
   /cross-review "review this PR diff" --models sonnet,opus
   /cross-review "audit this code" --models sonnet,gemini-pro,gpt-4.1 --score
   /cross-review "design this API" --score --judge opus --task-type analysis
   ```

2. Run the cross-review:

   ```bash
   # Basic cross-review (diff only)
   ~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
     --prompt "your prompt here" \
     --models "sonnet,opus"

   # With auto-scoring via judge model (default judge: opus)
   ~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
     --prompt "your prompt here" \
     --models "sonnet,gemini-pro,gpt-4.1" \
     --score

   # With custom judge model and task type
   ~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
     --prompt "your prompt here" \
     --models "sonnet,opus" \
     --score --judge sonnet --task-type review
   ```

3. Present the results:
   - Show each model's response summary
   - Show the diff between responses (for 2-model comparisons)
   - If `--score` was used, show the judge's structured scores and winner declaration
   - Note any models that failed to respond

4. If `--score` was used, scores are automatically:
   - Recorded in the model-comparisons SQLite DB (`~/.aidevops/.agent-workspace/memory/model-comparisons.db`)
   - Fed into the pattern tracker for data-driven model routing (`/route`, `/patterns`)

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--prompt` | (required) | The review prompt |
| `--models` | `sonnet,opus` | Comma-separated model tiers to compare |
| `--score` | off | Auto-score outputs via judge model |
| `--judge` | `opus` | Judge model tier (used with `--score`) |
| `--task-type` | `general` | Scoring category: `code`, `review`, `analysis`, `text`, `general` |
| `--timeout` | `600` | Seconds per model |
| `--output` | auto | Directory for raw outputs |
| `--workdir` | `pwd` | Working directory for model context |

## Model Tiers

`haiku`, `flash`, `sonnet`, `pro`, `opus` — or full model IDs like `gemini-2.5-pro`, `gpt-4.1`

## Scoring Criteria (judge model, 1-10 scale)

| Criterion | Description |
|-----------|-------------|
| correctness | Factual accuracy and technical correctness |
| completeness | Coverage of all requirements and edge cases |
| quality | Code quality, best practices, maintainability |
| clarity | Clear explanation, good formatting, readability |
| overall | Judge's holistic assessment |

## Examples

```bash
# Compare sonnet vs opus on a code review task
/cross-review "Review this function for bugs and suggest improvements: $(cat src/auth.ts)"

# Three-way comparison with auto-scoring
/cross-review "Design a rate limiting strategy for a REST API" \
  --models sonnet,opus,pro --score

# Custom judge model and task type
/cross-review "Audit this architecture" --models "sonnet,opus" --score --judge opus --task-type analysis

# Quick diff with custom timeout
/cross-review "Summarize the key changes in this diff" --models haiku,sonnet --timeout 120

# View scoring results after a cross-review
/score-responses --leaderboard
```

## Output

- Per-model responses displayed inline
- Diff summary (word counts, unified diff for 2-model comparisons)
- Judge scores table (when `--score` is set)
- Winner declaration with reasoning
- Results saved to `~/.aidevops/.agent-workspace/tmp/cross-review-<timestamp>/`
- Judge JSON saved to `<output_dir>/judge-scores.json`

## Related

- `/compare-models` — Compare model capabilities and pricing (no live dispatch)
- `/score-responses` — View and manage response scoring history
- `/route` — Get model routing recommendations based on pattern data
- `/patterns` — View model performance patterns
