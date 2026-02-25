---
description: Dispatch the same prompt to multiple AI models, diff results, and optionally auto-score via a judge model
agent: Build+
mode: subagent
---

Dispatch a prompt to multiple AI models in parallel, collect and diff their responses, and optionally score them via a judge model.

Target: $ARGUMENTS

## Instructions

1. Parse the user's arguments. Common forms:

   ```bash
   /cross-review "review this PR diff" --models sonnet,opus
   /cross-review "audit this code" --models sonnet,gemini-pro,gpt-4.1 --score
   /cross-review "design this API" --score --judge opus
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

   # With custom judge model
   ~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
     --prompt "your prompt here" \
     --models "sonnet,opus" \
     --score --judge sonnet
   ```

3. Present the results:
   - Show each model's response summary
   - Show the diff between responses (for 2-model comparisons)
   - If `--score` was used, show the judge's structured scores and winner declaration
   - Note any models that failed to respond

4. If `--score` was used, scores are automatically:
   - Recorded in the model-comparisons SQLite DB
   - Fed into the pattern tracker for model routing (`/route`, `/patterns`)

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--models` | `sonnet,opus` | Comma-separated model tiers to compare |
| `--score` | off | Auto-score outputs via judge model |
| `--judge` | `opus` | Judge model tier (used with `--score`) |
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
| adherence | Following the original prompt instructions precisely |

## Examples

```bash
# Compare sonnet vs opus on a code review task
/cross-review "Review this function for bugs and suggest improvements: $(cat src/auth.ts)"

# Three-way comparison with auto-scoring
/cross-review "Design a rate limiting strategy for a REST API" \
  --models sonnet,opus,pro --score

# Quick diff with custom timeout
/cross-review "Summarize the key changes in this diff" --models haiku,sonnet --timeout 120

# View scoring results after a cross-review
/score-responses --leaderboard
```

## Related

- `/compare-models` — Compare model capabilities and pricing (no live dispatch)
- `/score-responses` — View and manage response scoring history
- `/route` — Get model routing recommendations based on pattern data
- `/patterns` — View model performance patterns
