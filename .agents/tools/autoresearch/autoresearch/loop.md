# Autoresearch — Experiment Loop

Sub-doc for `autoresearch.md`. Loaded on demand during Step 2.

---

## Loop Pseudocode

```text
SESSION_START = current time
ITER_TOKENS = 0

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
        ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
        TOTAL_TOKENS += ITER_TOKENS
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS)
        continue

    metric_result = run_metric()
    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
        TOTAL_TOKENS += ITER_TOKENS
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS)
        continue

    delta = metric_result - BASELINE
    ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
    TOTAL_TOKENS += ITER_TOKENS

    if is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        git -C WORKTREE_PATH add -A
        git -C WORKTREE_PATH commit -m "experiment: {hypothesis[:60]} ({METRIC_NAME}: {metric_result})"
        HEAD_SHA = git -C WORKTREE_PATH rev-parse --short HEAD
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis, ITER_TOKENS)
        store_memory(hypothesis, metric_result, "keep")
        send_discovery(hypothesis, metric_result, "keep", HEAD_SHA)
    else:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis, ITER_TOKENS)
        store_memory(hypothesis, metric_result, "discard")
        send_discovery(hypothesis, metric_result, "discard", null)
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

- Never repeat a hypothesis that was already discarded (check FAILED_HYPOTHESES)
- Prefer changes with high expected impact and low risk of constraint failure
- For agent optimization: shorter instructions with higher information density > longer verbose instructions
- For build optimization: structural changes (tree-shaking, module boundaries) > config tweaks
- Simplification is always valid: removing code that doesn't affect the metric is a win

---

## Constraint Checking

```bash
timeout PER_EXPERIMENT bash -c "{constraint_command}"
exit_code=$?
if exit_code != 0:
    return FAIL with constraint_command and exit_code
```

All constraints must pass. First failure short-circuits.

---

## Metric Measurement

```bash
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
```

Parse the last non-empty line of stdout as a float. If parsing fails or command exits non-zero: return ERROR.

---

## Improvement Check

```text
is_improvement(new_value, best_value, direction):
    if best_value == null: return true  # first measurement is always an improvement
    if direction == "lower": return new_value < best_value
    if direction == "higher": return new_value > best_value
```

---

## Token Estimation

```text
current_token_estimate():
    # chars-per-token ratio ~4; use API response token counts if available
    return estimated_tokens
```

If the runtime exposes token counts in API responses, use those directly. Otherwise estimate from character count of tool calls and responses.
