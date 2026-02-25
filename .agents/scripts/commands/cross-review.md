---
description: Dispatch a prompt to multiple AI models, diff results, and optionally score via a judge model
agent: Build+
mode: subagent
---

Run a multi-model adversarial review: dispatch the same prompt to N models in parallel, collect outputs, diff results, and optionally score via a judge model (Ouroboros-style pipeline).

Target: $ARGUMENTS

## Instructions

Parse the arguments to extract:
- `--prompt`: the review prompt (required)
- `--models`: comma-separated model tiers (default: `sonnet,opus`)
- `--score`: enable judge scoring pipeline (optional flag)
- `--judge`: judge model tier (default: `opus`)
- `--task-type`: scoring category — `code`, `review`, `analysis`, `text`, `general` (default: `general`)
- `--timeout`: per-model timeout in seconds (default: 600)
- `--output`: output directory (default: auto-generated tmp dir)

### Basic cross-review (diff only)

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "$PROMPT" \
  --models "$MODELS"
```

### Cross-review with judge scoring (full pipeline)

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "$PROMPT" \
  --models "$MODELS" \
  --score \
  --judge "${JUDGE:-opus}" \
  --task-type "${TASK_TYPE:-general}"
```

When `--score` is set, the pipeline:
1. Dispatches the prompt to all specified models in parallel
2. Collects outputs and shows a diff summary
3. Sends all outputs to the judge model (default: opus) for structured scoring
4. Records scores in the model-comparisons SQLite DB (`~/.aidevops/.agent-workspace/memory/model-comparisons.db`)
5. Syncs results to the pattern tracker for data-driven model routing

### View past cross-review results

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh results
~/.aidevops/agents/scripts/compare-models-helper.sh results --model sonnet --limit 10
```

## Scoring Criteria (judge model)

| Criterion | Scale | Description |
|-----------|-------|-------------|
| Correctness | 1-10 | Factual accuracy and technical correctness |
| Completeness | 1-10 | Coverage of all requirements and edge cases |
| Quality | 1-10 | Code quality / writing quality |
| Clarity | 1-10 | Clear explanation, good formatting, readability |
| Adherence | 1-10 | Following instructions precisely, staying on-task |
| Overall | 1-10 | Judge's holistic assessment |

## Examples

```bash
# Basic: compare sonnet vs opus on a code review
/cross-review --prompt "Review this function for bugs: def foo(x): return x/0" --models "sonnet,opus"

# Full pipeline: score via judge, record in DB, update pattern tracker
/cross-review --prompt "Review this PR diff for security issues" --models "sonnet,opus,pro" --score

# Custom judge model and task type
/cross-review --prompt "Audit this architecture" --models "sonnet,opus" --score --judge opus --task-type analysis

# With timeout for long reviews
/cross-review --prompt "Full code audit of this module" --models "opus,pro" --score --timeout 900
```

## Output

- Per-model responses displayed inline
- Diff summary (word counts, unified diff for 2-model comparisons)
- Judge scores table (when `--score` is set)
- Winner declaration with reasoning
- Results saved to `~/.aidevops/.agent-workspace/tmp/cross-review-<timestamp>/`
- Judge JSON saved to `<output_dir>/judge-scores.json`

## Related Commands

- `/score-responses` — manual scoring workflow
- `/compare-models` — model capability and pricing comparison
- `/patterns` — view pattern tracker data and model success rates
- `/route` — data-driven model routing recommendations
