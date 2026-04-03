# Autoresearch — Experiment Loop

Sub-doc for `autoresearch.md`. Loaded on demand during Step 2.

---

## Loop Pseudocode

```text
SESSION_START = current time

while true:
    elapsed = now - SESSION_START
    if elapsed >= TIMEOUT: break with reason "timeout"
    if ITERATION_COUNT >= MAX_ITER: break with reason "max_iterations"
    if GOAL is set and goal_met(BEST_METRIC, GOAL, METRIC_DIR): break with reason "goal_reached"

    ITERATION_COUNT += 1
    ITER_START_TOKENS = current_token_estimate()
    Log: "--- Iteration {ITERATION_COUNT} ---"

    if CAMPAIGN_ID is set:
        peer_discoveries = check_peer_discoveries()

    hypothesis = generate_hypothesis(...)
    apply_modification(hypothesis)

    constraint_result = run_constraints()
    if constraint_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS, 0, "-")
        continue

    if TRIALS > 1:
        (metric_result, variance, trial_results) = multi_trial_evaluate(METRIC_CMD, TRIALS, PER_EXPERIMENT)
    else:
        metric_result = run_metric()
        variance = 0
        trial_results = [metric_result]

    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS, 0, "-")
        continue

    track_tokens(ITER_START_TOKENS)

    if is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        # Multi-trial consistency check: median improved but require majority of trials to improve
        if TRIALS > 1:
            improvement_count = count(r for r in trial_results if is_improvement(r, BEST_METRIC, METRIC_DIR))
            if improvement_count <= TRIALS / 2:
                # Median improved but not consistently — treat as noise
                git -C WORKTREE_PATH reset --hard HEAD
                FAILED_HYPOTHESES.append(hypothesis)
                log_result(ITERATION_COUNT, null, metric_result, "discard_inconsistent", hypothesis, ITER_TOKENS, TRIALS, variance)
                store_memory(hypothesis, metric_result, "discard_inconsistent")
                send_discovery(hypothesis, metric_result, "discard_inconsistent", null)
                continue

        git -C WORKTREE_PATH add -A
        git -C WORKTREE_PATH commit -m "experiment: {hypothesis[:60]} ({METRIC_NAME}: {metric_result})"
        HEAD_SHA = git -C WORKTREE_PATH rev-parse --short HEAD
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis, ITER_TOKENS, TRIALS, variance)
        store_memory(hypothesis, metric_result, "keep")
        send_discovery(hypothesis, metric_result, "keep", HEAD_SHA)
    else:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis, ITER_TOKENS, TRIALS, variance)
        store_memory(hypothesis, metric_result, "discard")
        send_discovery(hypothesis, metric_result, "discard", null)

# track_tokens helper (called above):
#   ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
#   TOTAL_TOKENS += ITER_TOKENS
```

---

## Hypothesis Generation

### Input context (provide all of these)

1. **Program hints** — from `## Hints` section
2. **Memory context** — recalled findings from prior sessions
3. **Peer discoveries** — from mailbox (multi-dimension mode only)
4. **Failed hypotheses** — what was tried and discarded this session
5. **Current best** — metric value and which commit achieved it
6. **Current code state** — read the target files (FILES glob)
7. **Iteration number** — to guide progression strategy

### Progression strategy

| Phase | Iterations | Strategy |
|-------|-----------|---------|
| **Low-hanging fruit** | 1–5 | Apply hints directly; obvious improvements from code reading |
| **Systematic** | 6–20 | Vary one parameter at a time; measure effect of each change |
| **Combination** | 21–35 | Combine two individually-successful changes |
| **Radical** | 36–45 | Try fundamentally different approaches if incremental gains stall |
| **Simplification** | 46+ | Remove things; equal-or-better with less code is a win |

### Rules

- Never repeat a discarded hypothesis (check FAILED_HYPOTHESES)
- Prefer high-impact changes with low constraint-failure risk
- Agent optimization: higher information density > longer verbose instructions
- Build optimization: structural changes (tree-shaking, module boundaries) > config tweaks
- Simplification is always valid: less code with equal-or-better metric is a win

---

## Helpers

**Constraint check:**

```bash
timeout PER_EXPERIMENT bash -c "{constraint_command}"
# exit_code != 0 → return FAIL; all constraints must pass (first failure short-circuits)
```

**Metric measurement (single trial):**

```bash
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
# Parse last non-empty stdout line as float. Parsing failure or non-zero exit → ERROR.
```

**Multi-trial evaluation (when TRIALS > 1):**

```text
multi_trial_evaluate(metric_cmd, n_trials, per_experiment_timeout):
    results = []
    for i in 1..n_trials:
        result = timeout per_experiment_timeout bash -c "{metric_cmd}" 2>/dev/null
        # Parse last non-empty stdout line as float
        if parse_error or non_zero_exit:
            return ERROR  # Any trial failure = overall failure (infrastructure problem, not noise)
        results.append(parsed_float)

    # Sort and take median (robust to outliers)
    sorted_results = sort(results)
    if n_trials is odd:
        median = sorted_results[n_trials / 2]
    else:
        median = (sorted_results[n_trials/2 - 1] + sorted_results[n_trials/2]) / 2

    variance = max(results) - min(results)  # range as variance proxy
    return (median, variance, results)
```

**Improvement check:**

```text
is_improvement(new, best, dir):
    if best == null: return true   # first measurement always keeps
    return new < best if dir=="lower" else new > best
```

**Token estimation:** Use API response token counts if available; otherwise estimate from character count (~4 chars/token).

---

## Multi-Trial Evaluation (t1870)

Addresses LLM stochasticity: a hypothesis that improves the metric by luck on one run
is not a real improvement. Run the metric N times and take the median (Harbor sweeps pattern).

Activated when the research program has `trials: N` (N > 1) in the `## Metric` section.
Default `trials: 1` preserves backward compatibility with all existing programs.

### multi_trial_evaluate pseudocode

```text
function multi_trial_evaluate(trial_results, AGGREGATION, CONSISTENCY_THRESHOLD):
    valid_results = [r for r in trial_results if r is not null]
    if len(valid_results) == 0:
        return ERROR

    if AGGREGATION == "median":
        aggregated = median(valid_results)
    elif AGGREGATION == "mean":
        aggregated = mean(valid_results)
    elif AGGREGATION == "min":
        aggregated = min(valid_results)
    elif AGGREGATION == "max":
        aggregated = max(valid_results)
    else:
        aggregated = median(valid_results)

    if VARIANCE_TRACKING and len(valid_results) > 1:
        variance = stdev(valid_results)
        log "Trial variance: {variance:.4f} (stdev over {len(valid_results)} trials)"

    return aggregated
```

### Consistency check

When `trials > 1`, apply a consistency check before keeping a hypothesis:

```text
function is_consistent_improvement(trial_results, BEST_METRIC, METRIC_DIR, CONSISTENCY_THRESHOLD):
    improving_trials = count(r for r in trial_results if is_improvement(r, BEST_METRIC, METRIC_DIR))
    fraction = improving_trials / len(trial_results)
    if fraction < CONSISTENCY_THRESHOLD:
        log "Consistency check failed: only {fraction:.0%} of trials improved (threshold: {CONSISTENCY_THRESHOLD:.0%})"
        return false
    return true
```

A hypothesis is kept only when BOTH conditions hold:

1. The aggregated metric is an improvement over `BEST_METRIC`
2. The consistency fraction meets `CONSISTENCY_THRESHOLD` (default: 0.6 = majority)

### Integration with main loop

Replace the single `metric_result = run_metric()` call with:

```text
if TRIALS > 1:
    trial_results = []
    for i in 1..TRIALS:
        r = run_metric()
        # Convert ERROR to null so failed trials count as non-improving in consistency check
        trial_results.append(null if r == ERROR else r)
    metric_result = multi_trial_evaluate(trial_results, AGGREGATION, CONSISTENCY_THRESHOLD)
    consistent = is_consistent_improvement(trial_results, BEST_METRIC, METRIC_DIR, CONSISTENCY_THRESHOLD)
else:
    metric_result = run_metric()
    consistent = true

if metric_result == ERROR:
    # ... existing crash handling ...
elif is_improvement(metric_result, BEST_METRIC, METRIC_DIR) and consistent:
    # ... existing keep path ...
else:
    # ... existing discard path ...
```

### TSV columns for multi-trial

Append two columns to the results TSV when `trials > 1`:

| Column | Type | Notes |
|--------|------|-------|
| `trials` | int | Number of trials run (1 for single-trial programs) |
| `trial_variance` | float\|`-` | Standard deviation across trials; `-` for single-trial |

These columns are appended after `token_ratio` and are optional — existing TSV readers
that don't know about them will ignore the extra columns.
