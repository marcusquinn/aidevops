---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1870: multi-trial evaluation extension for autoresearch loop

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1866
- **Conversation context:** Harbor framework's sweeps pattern runs tasks N times to reduce noise. Our autoresearch does single measurements, which is vulnerable to LLM stochasticity causing false positives. This extension benefits both autoresearch (general) and autoagent (specific).

## What

Extend the autoresearch loop infrastructure to support multi-trial evaluation. Changes to 3 existing files + 1 template update:

1. **`.agents/tools/autoresearch/autoresearch/loop.md`** — Add multi-trial evaluation to the loop pseudocode. When `TRIALS > 1`, run the metric command N times and use the median for keep/discard decisions.

2. **`.agents/tools/autoresearch/autoresearch/logging.md`** — Add `trials` and `trial_variance` columns to the results TSV schema. Log individual trial results in a structured way.

3. **`.agents/templates/research-program-template.md`** — Add optional `trials:` field to `## Budget` section. Default: 1 (backward compatible).

4. **`.agents/tools/autoresearch/autoresearch.md`** — Add `TRIALS` to the Step 0 variable table. Parse from research program `## Budget` section.

## Why

- **LLM stochasticity:** Comprehension tests involve LLM inference. The same agent file can score differently on consecutive runs. Single measurements lead to false positives (keep a change that got lucky once) and false negatives (discard a change that was unlucky once).
- **Harbor's sweeps demonstrate this:** They run multiple trials per task and export success/failure splits for RL. The statistical approach is proven.
- **Backward compatible:** `trials: 1` (default) preserves existing autoresearch behavior. Only autoagent and explicitly configured programs use multi-trial.
- **Shared infrastructure:** This benefits ALL autoresearch programs, not just autoagent. A build-time optimization program could use `trials: 3` to handle measurement noise.

## How (Approach)

### loop.md changes

Add a `multi_trial_evaluate` function to the Helpers section:

```text
## Multi-Trial Evaluation (when TRIALS > 1)

multi_trial_evaluate(metric_cmd, n_trials, per_experiment_timeout):
    results = []
    for i in 1..n_trials:
        result = timeout per_experiment_timeout bash -c "{metric_cmd}" 2>/dev/null
        # Parse last non-empty stdout line as float
        if parse_error or non_zero_exit:
            return ERROR  # Any trial failure = overall failure
        results.append(parsed_float)
    
    # Sort and take median
    sorted_results = sort(results)
    if n_trials is odd:
        median = sorted_results[n_trials / 2]
    else:
        median = (sorted_results[n_trials/2 - 1] + sorted_results[n_trials/2]) / 2
    
    variance = max(results) - min(results)
    return (median, variance, results)
```

Update the main loop pseudocode to use this when `TRIALS > 1`:

```text
    if TRIALS > 1:
        (metric_result, variance, trial_results) = multi_trial_evaluate(METRIC_CMD, TRIALS, PER_EXPERIMENT)
    else:
        metric_result = run_metric()  # existing single-shot
        variance = 0
        trial_results = [metric_result]
```

Add a **consistency check** for keep decisions:

```text
    # For multi-trial: require improvement in majority of trials
    if TRIALS > 1 and is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        improvement_count = count(r for r in trial_results if is_improvement(r, BEST_METRIC, METRIC_DIR))
        if improvement_count <= TRIALS / 2:
            # Median improved but not consistently — treat as noise
            log_result(..., "discard_inconsistent", ...)
            continue
```

### logging.md changes

Add two new columns to the results TSV:

| Column | Type | Notes |
|---|---|---|
| `trials` | int | Number of evaluation trials run (1 if single-shot) |
| `trial_variance` | float or `-` | `max - min` of trial results; `-` for single trial |

Update the TSV header line and example rows.

### research-program-template.md changes

Add to `## Budget` section:

```text
trials: 1              # optional: evaluations per hypothesis (default: 1, use 2-3 for noisy metrics)
```

Add a note under the field: "Multi-trial evaluation reduces noise from stochastic metrics (e.g., LLM-scored tests). Each trial re-runs the full metric command. The median result is used for keep/discard. Set to 2-3 for LLM-based metrics, 1 for deterministic metrics (build time, file size)."

### autoresearch.md changes

Add `TRIALS` to the Step 0 variable table:

```text
| TRIALS | `## Budget` section, `trials:` line (default: 1) |
```

## Acceptance Criteria

- [ ] loop.md contains multi-trial evaluation pseudocode
  ```yaml
  verify:
    method: codebase
    pattern: "multi_trial_evaluate|n_trials|median"
    path: ".agents/tools/autoresearch/autoresearch/loop.md"
  ```
- [ ] loop.md has consistency check (majority of trials must improve)
  ```yaml
  verify:
    method: codebase
    pattern: "improvement_count|discard_inconsistent|TRIALS.*/.*2"
    path: ".agents/tools/autoresearch/autoresearch/loop.md"
  ```
- [ ] logging.md has `trials` and `trial_variance` columns
  ```yaml
  verify:
    method: codebase
    pattern: "trials.*trial_variance|trial_variance.*trials"
    path: ".agents/tools/autoresearch/autoresearch/logging.md"
  ```
- [ ] research-program-template.md has `trials:` field in Budget section
  ```yaml
  verify:
    method: codebase
    pattern: "trials:.*optional.*evaluations per hypothesis"
    path: ".agents/templates/research-program-template.md"
  ```
- [ ] autoresearch.md has TRIALS in Step 0 variable table
  ```yaml
  verify:
    method: codebase
    pattern: "TRIALS.*Budget.*trials"
    path: ".agents/tools/autoresearch/autoresearch.md"
  ```
- [ ] Default is `trials: 1` (backward compatible with existing programs)
  ```yaml
  verify:
    method: codebase
    pattern: "default.*1|trials:.*1"
    path: ".agents/templates/research-program-template.md"
  ```
- [ ] All modified markdown files pass markdownlint

## Context & Decisions

- **Why median not mean?** Median is robust to outliers. If one trial produces an anomalous result (e.g., LLM timeout causing 0 score), median ignores it. Mean would be dragged down.
- **Why fail on any trial error?** If the metric command itself errors (not a low score, but an execution failure), that indicates an infrastructure problem, not a noisy measurement. Fail fast.
- **Why consistency check?** A hypothesis where the median improves but only 1 of 3 trials shows improvement is likely noise. Requiring majority improvement adds confidence.
- **Why not more sophisticated statistics?** Simplicity. We're running 2-3 trials, not 30. Statistical tests need large N. Median + majority vote is appropriate for small N.

## Relevant Files

- `.agents/tools/autoresearch/autoresearch/loop.md` — primary file to extend (add multi-trial section)
- `.agents/tools/autoresearch/autoresearch/logging.md` — add columns to TSV schema
- `.agents/tools/autoresearch/autoresearch.md` — add TRIALS to variable table
- `.agents/templates/research-program-template.md` — add trials: field

## Dependencies

- **Blocked by:** nothing (extends existing files)
- **Blocks:** t1868 (autoagent subagent uses multi-trial evaluation)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Re-read loop.md and logging.md carefully |
| loop.md extension | 45m | Multi-trial function, loop integration, consistency check |
| logging.md extension | 20m | Two new columns, updated examples |
| Template + autoresearch.md | 20m | New field + variable table entry |
| Testing | 20m | Markdownlint on all modified files |
| **Total** | **~2h** | |
