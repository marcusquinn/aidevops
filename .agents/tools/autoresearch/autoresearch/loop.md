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
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS)
        continue

    metric_result = run_metric()
    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS)
        continue

    track_tokens(ITER_START_TOKENS)

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

**Metric measurement:**

```bash
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
# Parse last non-empty stdout line as float. Parsing failure or non-zero exit → ERROR.
```

**Improvement check:**

```text
is_improvement(new, best, dir):
    if best == null: return true   # first measurement always keeps
    return new < best if dir=="lower" else new > best
```

**Token estimation:** Use API response token counts if available; otherwise estimate from character count (~4 chars/token).
