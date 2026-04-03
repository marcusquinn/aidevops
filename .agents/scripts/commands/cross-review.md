---
description: Dispatch the same prompt to multiple AI models, diff results, and optionally auto-score via a judge model
agent: Build+
mode: subagent
---

## Instructions

1. Parse `$ARGUMENTS` — extract `--prompt`, `--models`, `--score`, `--judge`, `--timeout`.

2. Run:

   ```bash
   ~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
     --prompt "your prompt here" \
     --models "sonnet,opus" \
     [--score] [--judge sonnet]
   ```

3. Present: each model's response summary, diff (2-model comparisons), judge scores and winner if `--score` used, note failures.

4. If `--score`: scores recorded in model-comparisons SQLite DB, fed into pattern tracker (`/route`, `/patterns`).

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

## Scoring Criteria (judge model, 1-10)

| Criterion | Description |
|-----------|-------------|
| correctness | Factual accuracy |
| completeness | Coverage of requirements and edge cases |
| quality | Code quality, best practices |
| clarity | Formatting, readability |
| adherence | Follows prompt instructions |

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
