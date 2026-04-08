---
description: Autonomous framework self-improvement loop — mines signals, generates hypotheses, modifies framework files, measures improvement, keeps only what helps
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent Subagent

Runs signal-mining → hypothesis generation → modification → multi-trial evaluation → keep/discard → log → repeat until budget exhausted or goal reached.

Arguments: `--program <path>` (required)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Program format**: `.agents/templates/autoagent-program-template.md`
- **Results file**: `todo/research/{name}-results.tsv`
- **Worktree**: `experiment/{name}` (created at session start)
- **State**: git HEAD of experiment branch = current best; results.tsv = full history
- **Resume**: re-run with same `--program` — reads results.tsv to reconstruct state; uncommitted changes discarded via `git reset --hard HEAD`
- **Memory**: `aidevops-memory` — cross-session finding persistence
- **Metric command**: `autoagent-metric-helper.sh` — composite score for framework quality
- **Sub-docs**: `autoagent/signal-mining.md` · `autoagent/hypothesis-types.md` · `autoagent/safety.md` · `autoagent/evaluation.md`

<!-- AI-CONTEXT-END -->

## Step 0: Parse Arguments

Extract `--program <path>`; exit with error if missing or file not found. Extract variables:

| Variable | Source |
|----------|--------|
| `PROGRAM_NAME` | frontmatter `name` |
| `MODE` | frontmatter `mode` (`in-repo` \| `cross-repo` \| `standalone`) |
| `TARGET_REPO` | frontmatter `target_repo` (path or `"."`) |
| `FILES` | `## Target` section, `files:` line |
| `BRANCH` | `## Target` section, `branch:` line (default: `experiment/{name}`) |
| `METRIC_CMD` | `## Metric` section, `command:` line |
| `METRIC_NAME` | `## Metric` section, `name:` line |
| `METRIC_DIR` | `## Metric` section, `direction:` line (`lower` \| `higher`) |
| `BASELINE` | `## Metric` section, `baseline:` line (`null` = not yet measured) |
| `GOAL` | `## Metric` section, `goal:` line (`null` = no goal) |
| `CONSTRAINTS` | `## Constraints` section, each bullet as a shell command |
| `HYPOTHESIS_TYPES` | `## Autoagent` section, `hypothesis_types:` line (comma-separated, default: all 6) |
| `SIGNAL_SOURCES` | `## Autoagent` section, `signal_sources:` line (comma-separated, default: all) |
| `SAFETY_LEVEL` | `## Autoagent` section, `safety_level:` line (`standard` \| `elevated`, default: `standard`) |
| `TRIALS_PER_HYPOTHESIS` | `## Autoagent` section, `trials_per_hypothesis:` line (default: `2`) |
| `TIMEOUT` | `## Budget` section, `timeout:` line (seconds) |
| `MAX_ITER` | `## Budget` section, `max_iterations:` line |
| `PER_EXPERIMENT` | `## Budget` section, `per_experiment:` line |
| `HINTS` | `## Hints` section, all bullet lines |

## Step 1: Setup

**1.1 Resolve target repo:** `REPO_ROOT = cwd` if `MODE == "in-repo"` or `TARGET_REPO == "."`, else expand `TARGET_REPO` and verify it's a git repo.

**1.2 Create or resume experiment worktree:**

```bash
WORKTREE_PATH="$REPO_ROOT/../$(basename $REPO_ROOT)-$BRANCH"  # replace / with - in branch name
if worktree exists: cd WORKTREE_PATH && git reset --hard HEAD; RESUMING=true
else: git -C REPO_ROOT worktree add WORKTREE_PATH -b BRANCH; RESUMING=false
```

**1.3 Load prior results (resume mode):**

```text
RESULTS_FILE = "$REPO_ROOT/todo/research/{name}-results.tsv"
if RESUMING and RESULTS_FILE exists:
    ITERATION_COUNT = data rows (excl. header)
    BEST_METRIC     = best metric_value (per direction)
    BASELINE        = metric_value where status == "baseline"
    FAILED_HYPOTHESES = hypothesis list where status == "discard"
    TOTAL_TOKENS    = sum of tokens_used column
    Log: "Resuming from iteration N, best metric: X"
else:
    ITERATION_COUNT=0; BEST_METRIC=null; BASELINE=null; FAILED_HYPOTHESES=[]; TOTAL_TOKENS=0
    mkdir -p $(dirname RESULTS_FILE)
    Write TSV header: iteration\tcommit\tmetric_name\tmetric_value\tbaseline\tdelta\tstatus\thypothesis\ttimestamp\ttokens_used
```

**1.4 Recall cross-session memory:** `aidevops-memory recall "autoagent $PROGRAM_NAME" --limit 10` → store as MEMORY_CONTEXT.

**1.5 Mine signals:** Load `autoagent/signal-mining.md`. Run signal extraction for each source in `SIGNAL_SOURCES`. Store as `SIGNAL_FINDINGS` — list of `{file, issue, source}` objects.

**1.6 Load safety constraints:** Load `autoagent/safety.md`. Apply `SAFETY_LEVEL` to determine modifiable files and elevated-approval requirements.

**1.7 Measure baseline (first run only):** If `BASELINE == null`: run all constraints (fail → exit); run METRIC_CMD → `BASELINE = BEST_METRIC`; update program file `baseline: {value}`; append baseline row to results.tsv.

## Step 2: Experiment Loop

See `autoagent/hypothesis-types.md` (6 hypothesis types, progression, overfitting test) and `autoagent/evaluation.md` (multi-trial pseudocode, trajectory recording, failure analysis).

Loop exits when any budget condition is met (timeout / max_iterations / goal_reached).

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

    hypothesis = generate_hypothesis(SIGNAL_FINDINGS, MEMORY_CONTEXT, FAILED_HYPOTHESES,
                                     BEST_METRIC, ITERATION_COUNT, HYPOTHESIS_TYPES)
    apply_modification(hypothesis)

    constraint_result = run_constraints()
    if constraint_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS)
        continue

    metric_result = multi_trial_evaluate(METRIC_CMD, TRIALS_PER_HYPOTHESIS)
    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS)
        continue

    track_tokens(ITER_START_TOKENS)

    if is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        git -C WORKTREE_PATH add -A
        git -C WORKTREE_PATH commit -m "autoagent: {hypothesis[:60]} ({METRIC_NAME}: {metric_result})"
        HEAD_SHA = git -C WORKTREE_PATH rev-parse --short HEAD
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, metric_result, "keep")
        aidevops-memory store "autoagent {PROGRAM_NAME}: {hypothesis[:80]} → keep ({METRIC_NAME}: {metric_result})" --confidence medium
    else:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, metric_result, "discard")
        aidevops-memory store "autoagent {PROGRAM_NAME}: {hypothesis[:80]} → discard ({METRIC_NAME}: {metric_result})" --confidence medium
```

## Step 3: Completion

**3.1 Store final memory:**

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME} complete: {kept_count} kept, {discarded_count} discarded, {improvement_pct:.1f}% improvement in {METRIC_NAME}. Top finding: {top_hypothesis}" \
  --confidence high
```

**3.2 Generate completion summary** (use as PR body):

```markdown
## Autoagent Results: {PROGRAM_NAME}

**Program:** {PROGRAM_NAME}
**Duration:** {elapsed_human} ({ITERATION_COUNT} iterations)
**Baseline → Best:** {BASELINE} → {BEST_METRIC} ({improvement_pct:+.1f}%)
**Exit reason:** {timeout | max_iterations | goal_reached}

### Experiment Outcomes

| Status | Count |
|--------|-------|
| Kept | {kept_count} |
| Discarded | {discarded_count} |
| Constraint failures | {constraint_fail_count} |
| Crashes | {crash_count} |

### Key Findings

{For each kept hypothesis, sorted by delta (best first):}
{N}. **{hypothesis}**: {METRIC_NAME} {metric_before} → {metric_after} ({delta:+.2f}, {improvement_pct:.1f}%)

### Failed Approaches

{For top 3-5 discarded hypotheses:}
- {hypothesis}: {METRIC_NAME} = {metric_value} (delta={delta:+.2f})

### Token Usage

- Total: ~{TOTAL_TOKENS:,} tokens across {ITERATION_COUNT} iterations
- Average per iteration: ~{avg_tokens:,} tokens
```

**3.3 Create PR:**

```bash
git -C WORKTREE_PATH push -u origin BRANCH

gh pr create \
  --repo {REPO_SLUG} \
  --head BRANCH \
  --base main \
  --title "autoagent({PROGRAM_NAME}): {improvement_pct:+.1f}% improvement in {METRIC_NAME}" \
  --body "$(generate_completion_summary)

Resolves #{issue_number_if_any}"
```

**3.4 Store PR memory:**

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME} PR created: {pr_url}. Best: {METRIC_NAME}={BEST_METRIC}. Key finding: {top_hypothesis}" \
  --confidence high
```

## Related

`.agents/templates/autoagent-program-template.md` · `.agents/scripts/autoagent-metric-helper.sh` · `todo/research/` · `.agents/tools/autoresearch/autoresearch.md`
