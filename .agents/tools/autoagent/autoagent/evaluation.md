# Autoagent — Multi-Trial Evaluation

Sub-doc for `autoagent.md`. Loaded during Step 2 (Loop) for metric measurement.

---

## Overview

Single-trial metric measurements are noisy. The autoagent uses multi-trial evaluation to get statistically reliable keep/discard decisions. Trajectory recording captures the full history of what was tried and why.

---

## Multi-Trial Evaluation

### Pseudocode

```text
function multi_trial_evaluate(metric_cmd, n_trials):
    results = []
    for i in 1..n_trials:
        result = run_metric(metric_cmd)
        if result == ERROR:
            return ERROR  # any trial error = overall error
        results.append(result)
    return median(results)
```

### Implementation

```bash
multi_trial_evaluate() {
    local metric_cmd="$1"
    local n_trials="$2"
    local results=()
    local result

    for i in $(seq 1 "$n_trials"); do
        result=$(timeout "$PER_EXPERIMENT" bash -c "$metric_cmd" 2>/dev/null | \
            grep -E '^[0-9]+(\.[0-9]+)?$' | tail -1)
        if [ -z "$result" ]; then
            echo "ERROR"
            return 1
        fi
        results+=("$result")
    done

    # Compute median
    printf '%s\n' "${results[@]}" | sort -n | \
        awk 'BEGIN{c=0} {a[c++]=$1} END{
            if (c%2) print a[int(c/2)];
            else print (a[c/2-1]+a[c/2])/2
        }'
    return 0
}
```

### Statistical Significance Rule

A hypothesis is kept only if the median improvement holds across trials:

- **Minimum trials:** 2 (default `TRIALS_PER_HYPOTHESIS`)
- **Keep threshold:** median of N trials must show improvement vs `BEST_METRIC`
- **Tie-breaking:** if median equals `BEST_METRIC`, discard (no improvement = not worth keeping)
- **Error handling:** any single trial returning ERROR → overall result = ERROR → rollback

**Why median, not mean?** Metric commands can have outlier runs (cold cache, background load). Median is more robust than mean for small N.

---

## Trajectory Recording

Every hypothesis attempt is recorded in a structured JSON log for post-session analysis.

### Trajectory File Location

```text
todo/research/{PROGRAM_NAME}-trajectory.jsonl
```

One JSON object per line (JSONL format). Append-only.

### Record Format

```json
{
  "iteration": 5,
  "hypothesis": "Consolidate file discovery rules in build.txt",
  "hypothesis_type": "instruction_refinement",
  "files_modified": [".agents/prompts/build.txt"],
  "diff_summary": "+3/-7 lines",
  "trials": [
    {"trial": 1, "score": 0.87, "sub_scores": {"pass_rate": 0.90, "token_ratio": 0.82}},
    {"trial": 2, "score": 0.85, "sub_scores": {"pass_rate": 0.88, "token_ratio": 0.80}}
  ],
  "median_score": 0.86,
  "baseline": 0.83,
  "delta": 0.03,
  "decision": "keep",
  "constraint_result": "pass",
  "regression_check": "pass",
  "timestamp": "2026-04-03T15:00:00Z",
  "tokens_used": 2340
}
```

### Recording Commands

```bash
# Append trajectory record after each hypothesis attempt
record_trajectory() {
    local iteration="$1"
    local hypothesis="$2"
    local median_score="$3"
    local decision="$4"
    local hypothesis_type="$5"
    local files_modified="$6"

    local trajectory_file="$REPO_ROOT/todo/research/${PROGRAM_NAME}-trajectory.jsonl"
    mkdir -p "$(dirname "$trajectory_file")"

    jq -n \
      --argjson iter "$iteration" \
      --arg hyp "$hypothesis" \
      --arg hyp_type "$hypothesis_type" \
      --argjson files "$files_modified" \
      --argjson score "$median_score" \
      --argjson baseline "$BASELINE" \
      --arg decision "$decision" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        iteration: $iter,
        hypothesis: $hyp,
        hypothesis_type: $hyp_type,
        files_modified: $files,
        median_score: $score,
        baseline: $baseline,
        delta: ($score - $baseline),
        decision: $decision,
        timestamp: $ts
      }' >> "$trajectory_file"
}
```

---

## Failure Analysis

When a hypothesis is discarded, extract actionable information to guide future hypotheses.

### Failure Categories

| Category | Condition | Action |
|----------|-----------|--------|
| `constraint_fail` | Constraint shell command exits non-zero | Log which constraint failed; avoid similar changes |
| `metric_regression` | Metric worse than `BEST_METRIC` | Log delta; note what made it worse |
| `metric_neutral` | Metric equals `BEST_METRIC` | Log as neutral; try a different approach |
| `crash` | Metric command errors | Log error; check if modification broke the metric command itself |
| `safety_skip` | Elevated-only file under standard safety | Log as skipped; not a failure |

### Failure Pattern Detection

After 3+ consecutive discards of the same type, adjust strategy:

```text
if consecutive_discards >= 3:
    if all_same_type:
        switch to next hypothesis type in progression
    if all_same_file:
        skip that file for next 5 iterations
    if all_constraint_fail:
        review constraint list — may be too strict for current target
```

### Extracting Signal from Failures

Failed hypotheses are not wasted — they narrow the search space:

```bash
# After session: analyze failure patterns
jq -r 'select(.decision == "discard") | .hypothesis_type' \
    "todo/research/${PROGRAM_NAME}-trajectory.jsonl" | \
    sort | uniq -c | sort -rn

# Which files were most often in discarded hypotheses?
jq -r 'select(.decision == "discard") | .files_modified[]' \
    "todo/research/${PROGRAM_NAME}-trajectory.jsonl" | \
    sort | uniq -c | sort -rn
```

---

## Metric Command Integration

The autoagent uses `autoagent-metric-helper.sh` as its primary metric command. The helper returns a composite score:

```bash
# Standard invocation
autoagent-metric-helper.sh run --suite agent-optimization

# Output format (last line of stdout, parseable as float)
# 0.87
```

### Composite Score Formula

`composite_score = pass_rate * (1 - 0.3 * token_ratio)`

- `pass_rate`: fraction of comprehension tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars` (proxy for token usage)
- Higher score = better (direction: `higher`)

### Sub-Score Logging

Log sub-scores alongside the composite score for analysis:

```bash
METRIC_JSON=$(autoagent-metric-helper.sh run --suite agent-optimization --json)
COMPOSITE=$(echo "$METRIC_JSON" | jq '.composite_score')
PASS_RATE=$(echo "$METRIC_JSON" | jq '.pass_rate')
TOKEN_RATIO=$(echo "$METRIC_JSON" | jq '.token_ratio')
```

---

## Budget Enforcement

| Condition | Check | Action |
|-----------|-------|--------|
| Wall-clock timeout | `elapsed >= TIMEOUT` | Break loop, proceed to completion |
| Max iterations | `ITERATION_COUNT >= MAX_ITER` | Break loop, proceed to completion |
| Goal reached | `BEST_METRIC >= GOAL` (for `higher` direction) | Break loop, proceed to completion |
| Per-experiment timeout | `timeout PER_EXPERIMENT cmd` | Treat as crash, revert, continue |
| All hypothesis types exhausted | No new hypotheses possible | Break loop, proceed to completion |
