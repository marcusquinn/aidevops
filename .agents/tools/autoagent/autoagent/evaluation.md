# Autoagent — Multi-Trial Evaluation

Sub-doc for `autoagent.md`. Loaded during Step 2 loop for metric measurement.

---

## Multi-Trial Evaluation

Single-trial metric measurements have high variance. Autoagent uses multi-trial evaluation to reduce noise.

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

**Rules:**

- Any single trial returning ERROR → entire evaluation returns ERROR (do not average over errors).
- Use median, not mean — median is robust to outlier trials.
- Default `n_trials = 2` (from `TRIALS_PER_HYPOTHESIS`). Increase to 3–5 for high-variance metrics.
- Each trial runs the full `METRIC_CMD` independently.

### Statistical Significance

Require improvement in >50% of trials before keeping:

```text
function is_significant_improvement(trials, baseline, direction):
    improved_count = count(t for t in trials if is_improvement(t, baseline, direction))
    return improved_count > len(trials) / 2
```

For `n_trials = 2`: both trials must show improvement (>50% of 2 = 1.0, rounded up to 2).
For `n_trials = 3`: at least 2 of 3 trials must show improvement.

---

## Metric Measurement

```bash
# Run metric command with per-experiment timeout
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
# Parse last non-empty stdout line as float
# Non-zero exit or parse failure → ERROR
```

**Improvement check:**

```text
is_improvement(new, best, dir):
    if best == null: return true   # first measurement always keeps
    return new < best if dir=="lower" else new > best
```

---

## Trajectory Recording

Record every iteration in a structured JSON log for post-session analysis.

**Log file:** `todo/research/{name}-trajectory.jsonl` (one JSON object per line)

**Format per iteration:**

```json
{
  "iteration": 5,
  "hypothesis": "Consolidate file discovery rules in build.txt",
  "hypothesis_type": "instruction_refinement",
  "signal_source": "comprehension_test",
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
  "regression_check": "pass",
  "timestamp": "2026-04-03T15:00:00Z",
  "tokens_used": 4200
}
```

**Append to trajectory log after each iteration:**

```bash
echo '{"iteration": N, ...}' >> "todo/research/{name}-trajectory.jsonl"
```

---

## Failure Analysis

After a session ends, extract actionable information from failed hypotheses.

### Failure Categories

| Category | Detection | Action |
|----------|-----------|--------|
| Constraint fail | `status == "constraint_fail"` | Review constraint — is it too strict? |
| Metric regression | `status == "discard"` with `delta < -0.05` | Note what made it worse |
| Regression fail | `status == "regression_fail"` | Note which test broke |
| Crash | `status == "crash"` | Check metric command reliability |
| Near-miss | `status == "discard"` with `delta > -0.01` | May be worth retrying with variation |

### Post-Session Analysis

```bash
# Count failures by category
jq -r '.decision' todo/research/{name}-trajectory.jsonl | sort | uniq -c

# Find near-misses (discarded but close to improvement)
jq -r 'select(.decision == "discard" and .delta > -0.01) | .hypothesis' \
  todo/research/{name}-trajectory.jsonl

# Find which hypothesis types succeeded vs failed
jq -r '"\(.hypothesis_type)\t\(.decision)"' \
  todo/research/{name}-trajectory.jsonl | sort | uniq -c
```

### Memory Storage for Failures

After each discard, store medium-confidence memory:

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME}: {hypothesis[:80]} → discard ({METRIC_NAME}: {metric_value}, delta={delta:+.2f})" \
  --confidence medium
```

After each keep, store high-confidence finding:

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME} FINDING: {hypothesis}. Improved {METRIC_NAME} by {abs(delta):.2f} ({improvement_pct:.1f}%). Commit: {commit_sha}" \
  --confidence high
```

---

## Token Estimation

**Per iteration:** `ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS`

**Estimation method:** Use API response token counts if available; otherwise estimate from character count (~4 chars/token).

**Budget tracking:**

```text
TOTAL_TOKENS += ITER_TOKENS
if TOTAL_TOKENS > 0.8 * TOKEN_BUDGET:
    Log: "Warning: 80% of token budget consumed"
if TOTAL_TOKENS > TOKEN_BUDGET:
    break with reason "token_budget"
```

---

## Autoagent Metric Helper

The primary metric command is `autoagent-metric-helper.sh` (t1867). Subcommands:

| Subcommand | Output | Use |
|------------|--------|-----|
| `composite` | JSON with `composite_score`, `pass_rate`, `token_ratio` | Primary metric |
| `comprehension` | Float 0–1 | Comprehension test pass rate only |
| `lint` | Float 0–1 | Linter violation rate (1 = no violations) |
| `tokens` | Float | Token ratio vs baseline |
| `baseline` | Sets baseline for token_ratio | Run once before first iteration |

**Composite formula:** `composite_score = pass_rate * (1 - 0.3 * token_ratio)` (higher = better)
