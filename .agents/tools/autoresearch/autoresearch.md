---
description: Autonomous experiment loop runner — reads a research program, generates hypotheses, modifies code, measures results, and keeps only improvements
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

# Autoresearch Subagent

Autonomous experiment loop runner. Reads a research program file, runs the
setup → hypothesis → modify → constrain → measure → keep/discard → log → repeat
loop until the budget is exhausted or the goal is reached.

Arguments: `--program <path>` (required)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Program format**: `.agents/templates/research-program-template.md`
- **Results file**: `todo/research/{name}-results.tsv`
- **Worktree**: `experiment/{name}` (created at session start)
- **State**: git HEAD of experiment branch = current best; results.tsv = full history
- **Resume**: re-run with same `--program` — reads results.tsv to reconstruct state

<!-- AI-CONTEXT-END -->

---

## Step 0: Parse Arguments

Extract `--program <path>` from arguments. If missing or file not found: exit with error.

Read the program file. Extract:

```text
PROGRAM_NAME   ← frontmatter `name`
MODE           ← frontmatter `mode` (in-repo | cross-repo | standalone)
TARGET_REPO    ← frontmatter `target_repo` (path or ".")
FILES          ← ## Target section, `files:` line
BRANCH         ← ## Target section, `branch:` line (default: experiment/{name})
METRIC_CMD     ← ## Metric section, `command:` line
METRIC_NAME    ← ## Metric section, `name:` line
METRIC_DIR     ← ## Metric section, `direction:` line (lower | higher)
BASELINE       ← ## Metric section, `baseline:` line (null = not yet measured)
GOAL           ← ## Metric section, `goal:` line (null = no goal)
CONSTRAINTS    ← ## Constraints section, each `- ` bullet as a shell command
RESEARCHER     ← ## Models section, `researcher:` line
EVALUATOR      ← ## Models section, `evaluator:` line (optional)
TARGET_MODEL   ← ## Models section, `target:` line (optional)
TIMEOUT        ← ## Budget section, `timeout:` line (seconds)
MAX_ITER       ← ## Budget section, `max_iterations:` line
PER_EXPERIMENT ← ## Budget section, `per_experiment:` line
HINTS          ← ## Hints section, all bullet lines
```

---

## Step 1: Setup

### 1.1 Resolve target repo

```bash
if MODE == "in-repo" or TARGET_REPO == ".":
    REPO_ROOT = current working directory
else:
    REPO_ROOT = TARGET_REPO (expand ~)
    verify it exists and is a git repo
```

### 1.2 Create or resume experiment worktree

```bash
WORKTREE_PATH="$REPO_ROOT/../$(basename $REPO_ROOT)-$BRANCH"
# Replace / with - in branch name for path

if worktree already exists at WORKTREE_PATH:
    cd WORKTREE_PATH
    git reset --hard HEAD  # discard any uncommitted changes from prior crash
    RESUMING=true
else:
    git -C REPO_ROOT worktree add WORKTREE_PATH -b BRANCH
    RESUMING=false
```

### 1.3 Load prior results (resume mode)

```text
RESULTS_FILE = "$REPO_ROOT/todo/research/{name}-results.tsv"

if RESUMING and RESULTS_FILE exists:
    Read results.tsv to reconstruct:
    - ITERATION_COUNT = number of rows
    - BEST_METRIC = best metric value seen (per direction)
    - BASELINE = first row's metric value
    - FAILED_HYPOTHESES = list of hypothesis descriptions that were discarded
    Log: "Resuming from iteration N, best metric: X"
else:
    ITERATION_COUNT = 0
    BEST_METRIC = null
    BASELINE = null
    FAILED_HYPOTHESES = []
    mkdir -p $(dirname RESULTS_FILE)
    Write TSV header: iteration\tcommit\tmetric\tstatus\thypothesis\ttimestamp\ttokens
```

### 1.4 Recall cross-session memory

```text
aidevops-memory recall "autoresearch $PROGRAM_NAME" --limit 10
```

Store recalled findings as MEMORY_CONTEXT for hypothesis generation.

### 1.5 Measure baseline (first run only)

```text
if BASELINE == null:
    Run all constraints. If any fail: exit with error (baseline environment is broken).
    Run METRIC_CMD. Parse numeric output.
    BASELINE = result
    BEST_METRIC = result
    Update program file: set `baseline: {value}`
    Log: "Baseline: {METRIC_NAME} = {BASELINE}"
    Append to results.tsv: 0\t(baseline)\t{BASELINE}\tbaseline\t(initial measurement)\t{timestamp}\t0
```

---

## Step 2: Experiment Loop

Repeat until any budget condition is met:

```text
SESSION_START = current time
while true:
    # Budget checks
    elapsed = now - SESSION_START
    if elapsed >= TIMEOUT: break with reason "timeout"
    if ITERATION_COUNT >= MAX_ITER: break with reason "max_iterations"
    if GOAL is set and goal_met(BEST_METRIC, GOAL, METRIC_DIR): break with reason "goal_reached"

    ITERATION_COUNT += 1
    Log: "--- Iteration {ITERATION_COUNT} ---"

    # Generate hypothesis
    hypothesis = generate_hypothesis(...)

    # Modify files
    apply_modification(hypothesis)

    # Constraint check
    constraint_result = run_constraints()
    if constraint_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        log_result(ITERATION_COUNT, null, "constraint_fail", hypothesis)
        continue

    # Measure metric
    metric_result = run_metric()
    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        log_result(ITERATION_COUNT, null, "crash", hypothesis)
        continue

    # Keep or discard
    if is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        git -C WORKTREE_PATH add -A
        git -C WORKTREE_PATH commit -m "experiment: {hypothesis[:60]} ({METRIC_NAME}: {metric_result})"
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis)
        store_memory(hypothesis, metric_result, "keep")
    else:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis)
        store_memory(hypothesis, metric_result, "discard")
```

---

## Hypothesis Generation

Called at the start of each iteration. Uses the researcher model's reasoning to
generate the next modification to try.

### Input context (provide all of these)

1. **Program hints** — from `## Hints` section
2. **Memory context** — recalled findings from prior sessions
3. **Failed hypotheses** — what was tried and discarded this session
4. **Current best** — metric value and which commit achieved it
5. **Current code state** — read the target files (FILES glob)
6. **Iteration number** — to guide progression strategy

### Progression strategy

Follow this order across iterations:

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

For each constraint in CONSTRAINTS:

```bash
timeout PER_EXPERIMENT bash -c "{constraint_command}"
exit_code=$?
if exit_code != 0:
    return FAIL with constraint_command and exit_code
```

All constraints must pass. First failure short-circuits (don't run remaining constraints).

---

## Metric Measurement

```bash
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
output=$?
```

Parse the last non-empty line of stdout as a float. If parsing fails or command
exits non-zero: return ERROR.

---

## Improvement Check

```text
is_improvement(new_value, best_value, direction):
    if best_value == null: return true  # first measurement is always an improvement
    if direction == "lower": return new_value < best_value
    if direction == "higher": return new_value > best_value
```

---

## Results Logging

Append to `todo/research/{name}-results.tsv`:

```text
{iteration}\t{commit_sha_or_null}\t{metric_value_or_null}\t{status}\t{hypothesis}\t{ISO_timestamp}\t{tokens_used}
```

Status values: `baseline`, `keep`, `discard`, `constraint_fail`, `crash`

---

## Memory Storage

After each iteration:

```text
aidevops-memory store "autoresearch {PROGRAM_NAME}: iteration {N} — {hypothesis[:80]} → {status} ({metric})"
```

At session end, store a summary:

```text
aidevops-memory store "autoresearch {PROGRAM_NAME} session complete: {ITERATION_COUNT} iterations, best {METRIC_NAME}={BEST_METRIC} (baseline={BASELINE}, improvement={improvement_pct}%)"
```

---

## Step 3: Completion

### 3.1 Write results summary

```markdown
## Autoresearch Results: {PROGRAM_NAME}

- **Iterations**: {ITERATION_COUNT}
- **Baseline**: {METRIC_NAME} = {BASELINE}
- **Best**: {METRIC_NAME} = {BEST_METRIC} ({improvement_pct}% improvement)
- **Exit reason**: {timeout | max_iterations | goal_reached}
- **Kept**: {kept_count} experiments
- **Discarded**: {discarded_count} experiments
- **Constraint failures**: {constraint_fail_count}
- **Crashes**: {crash_count}

### Key findings

{List top 3-5 kept hypotheses with their metric improvements}

### Failed approaches

{List top 3-5 discarded hypotheses — useful for future sessions to avoid}
```

### 3.2 Create PR from experiment branch

```bash
git -C WORKTREE_PATH push -u origin BRANCH

gh pr create \
  --repo {REPO_SLUG} \
  --head BRANCH \
  --base main \
  --title "experiment({PROGRAM_NAME}): {improvement_pct}% improvement in {METRIC_NAME}" \
  --body "{results_summary}\n\nCloses #{issue_number_if_any}"
```

### 3.3 Store final memory

```text
aidevops-memory store "autoresearch {PROGRAM_NAME} PR created: {pr_url}. Best: {METRIC_NAME}={BEST_METRIC}. Key finding: {top_hypothesis}"
```

---

## Crash Recovery

If the subagent session crashes mid-loop:

1. The experiment worktree persists at `WORKTREE_PATH`
2. The results.tsv persists at `RESULTS_FILE`
3. The experiment branch HEAD is always the last known-good state
4. Any uncommitted changes are discarded on resume via `git reset --hard HEAD`

To resume: re-run `/autoresearch --program {program_path}`. The subagent detects
the existing worktree and results.tsv and continues from where it left off.

---

## Budget Enforcement

| Condition | Check | Action |
|-----------|-------|--------|
| Wall-clock timeout | `elapsed >= TIMEOUT` | Break loop, proceed to completion |
| Max iterations | `ITERATION_COUNT >= MAX_ITER` | Break loop, proceed to completion |
| Goal reached | `goal_met(BEST_METRIC, GOAL)` | Break loop, proceed to completion |
| Per-experiment timeout | `timeout PER_EXPERIMENT cmd` | Treat as crash, revert, continue |

---

---

## Agent Optimization Domain

When the program name is `agent-optimization` or the metric command contains
`agent-test-helper.sh`, apply these domain-specific rules in addition to the
general loop.

### Composite Metric Parsing

The metric command outputs a JSON object. Parse it as follows:

```bash
METRIC_JSON=$(eval "$METRIC_CMD")
COMPOSITE_SCORE=$(echo "$METRIC_JSON" | jq '.composite_score')
PASS_RATE=$(echo "$METRIC_JSON" | jq '.pass_rate')
TOKEN_RATIO=$(echo "$METRIC_JSON" | jq '.token_ratio')
```

Use `COMPOSITE_SCORE` as the primary metric value for keep/discard decisions.
Log `PASS_RATE` and `TOKEN_RATIO` as supplementary columns in results.tsv.

**Formula**: `composite_score = pass_rate * (1 - 0.3 * token_ratio)`

- `pass_rate`: fraction of tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars` — proxy for token usage
- Higher composite score = better (direction: higher)

### Baseline Setup

On first run (BASELINE == null), save the current test results as the baseline
before measuring the baseline metric:

```bash
agent-test-helper.sh baseline {suite_name}
```

This sets `baseline_chars` in the baseline file, enabling `token_ratio` computation
on subsequent runs. Without this step, `token_ratio` defaults to 1.0 (no change).

### Security Instruction Exemptions

Before generating any hypothesis, check whether it would remove or weaken any of
the following instruction categories. If yes, discard the hypothesis without testing:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

These exemptions are enforced by the constraint list in the research program AND
by the researcher model's hypothesis generation. Both layers must hold.

### Simplification State Integration

Before generating hypotheses for a target file, check `.agents/configs/simplification-state.json`:

```bash
TARGET_FILE=".agents/build-plus.md"  # or whichever file is being optimized
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
STORED_HASH=$(jq -r --arg f "$TARGET_FILE" '.files[$f].hash // empty' \
    .agents/configs/simplification-state.json 2>/dev/null)

if [[ "$CURRENT_HASH" == "$STORED_HASH" ]]; then
    log "File unchanged since last optimization. Skipping."
    # If this is the only target, exit with "no work needed"
    # If there are multiple targets, move to the next one
fi
```

After a successful session (composite_score improved vs baseline), update the hash:

```bash
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
jq --arg file "$TARGET_FILE" \
   --arg hash "$CURRENT_HASH" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.files[$file] = {"hash": $hash, "at": $ts, "pr": null}' \
   .agents/configs/simplification-state.json > /tmp/ss.json && \
   mv /tmp/ss.json .agents/configs/simplification-state.json
```

### Agent Optimization Hypothesis Types

Use this ordered list when generating hypotheses for agent instruction files:

| Phase | Hypothesis type | Example |
|-------|----------------|---------|
| 1–5 | Consolidate redundant rules | Merge two similar "Read before Edit" rules into one |
| 6–15 | Remove low-value instructions | Delete rules that don't affect any test outcome |
| 16–25 | Shorten verbose phrasing | Replace 3-sentence rule with 1-sentence equivalent |
| 26–35 | Replace inline code with references | `file:line` instead of code blocks |
| 36–45 | Merge thin sections | Combine two small sections covering the same topic |
| 46+ | Simplification | Remove anything that doesn't affect the metric |

Always check security exemptions before testing any hypothesis.

---

## Related

`.agents/templates/research-program-template.md` · `.agents/scripts/commands/autoresearch.md` · `todo/research/` · `todo/research/agent-optimization.md`
