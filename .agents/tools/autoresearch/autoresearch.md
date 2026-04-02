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
- **Mailbox**: `mail-helper.sh` — inter-agent discovery sharing (concurrent mode)
- **Memory**: `aidevops-memory` — cross-session finding persistence

<!-- AI-CONTEXT-END -->

---

## Step 0: Parse Arguments

Extract `--program <path>` from arguments. If missing or file not found: exit with error.

Read the program file. Extract:

```text
PROGRAM_NAME   ← frontmatter `name`
MODE           ← frontmatter `mode` (in-repo | cross-repo | standalone)
TARGET_REPO    ← frontmatter `target_repo` (path or ".")
DIMENSION      ← frontmatter `dimension` (optional, for multi-dimension campaigns)
CAMPAIGN_ID    ← frontmatter `campaign_id` (optional, for multi-dimension campaigns)
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
    - ITERATION_COUNT = number of data rows (excluding header)
    - BEST_METRIC = best metric_value seen (per direction)
    - BASELINE = metric_value from row where status == "baseline"
    - FAILED_HYPOTHESES = list of hypothesis from rows where status == "discard"
    - TOTAL_TOKENS = sum of tokens_used column
    Log: "Resuming from iteration N, best metric: X"
else:
    ITERATION_COUNT = 0
    BEST_METRIC = null
    BASELINE = null
    FAILED_HYPOTHESES = []
    TOTAL_TOKENS = 0
    mkdir -p $(dirname RESULTS_FILE)
    Write TSV header:
      iteration\tcommit\tmetric_name\tmetric_value\tbaseline\tdelta\tstatus\thypothesis\ttimestamp\ttokens_used
```

### 1.4 Recall cross-session memory

```text
aidevops-memory recall "autoresearch $PROGRAM_NAME" --limit 10
```

Store recalled findings as MEMORY_CONTEXT for hypothesis generation.

### 1.5 Register with mailbox (multi-dimension mode only)

If CAMPAIGN_ID is set (multi-dimension campaign):

```bash
AGENT_ID="autoresearch-${PROGRAM_NAME}-${DIMENSION:-solo}"
mail-helper.sh register --agent "$AGENT_ID"
Log: "Registered as $AGENT_ID in campaign $CAMPAIGN_ID"
```

### 1.6 Measure baseline (first run only)

```text
if BASELINE == null:
    Run all constraints. If any fail: exit with error (baseline environment is broken).
    Run METRIC_CMD. Parse numeric output.
    BASELINE = result
    BEST_METRIC = result
    Update program file: set `baseline: {value}`
    Log: "Baseline: {METRIC_NAME} = {BASELINE}"
    Append to results.tsv:
      0\t(baseline)\t{METRIC_NAME}\t{BASELINE}\t{BASELINE}\t0.0\tbaseline\t(initial measurement)\t{timestamp}\t0
```

---

## Step 2: Experiment Loop

Repeat until any budget condition is met:

```text
SESSION_START = current time
ITER_TOKENS = 0

while true:
    # Budget checks
    elapsed = now - SESSION_START
    if elapsed >= TIMEOUT: break with reason "timeout"
    if ITERATION_COUNT >= MAX_ITER: break with reason "max_iterations"
    if GOAL is set and goal_met(BEST_METRIC, GOAL, METRIC_DIR): break with reason "goal_reached"

    ITERATION_COUNT += 1
    ITER_START_TOKENS = current_token_estimate()
    Log: "--- Iteration {ITERATION_COUNT} ---"

    # Check peer discoveries (multi-dimension mode)
    if CAMPAIGN_ID is set:
        peer_discoveries = check_peer_discoveries()
        # Incorporate peer findings into hypothesis context

    # Generate hypothesis
    hypothesis = generate_hypothesis(...)

    # Modify files
    apply_modification(hypothesis)

    # Constraint check
    constraint_result = run_constraints()
    if constraint_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
        TOTAL_TOKENS += ITER_TOKENS
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS)
        continue

    # Measure metric
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

    # Keep or discard
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

Called at the start of each iteration. Uses the researcher model's reasoning to
generate the next modification to try.

### Input context (provide all of these)

1. **Program hints** — from `## Hints` section
2. **Memory context** — recalled findings from prior sessions
3. **Peer discoveries** — from mailbox (multi-dimension mode only)
4. **Failed hypotheses** — what was tried and discarded this session
5. **Current best** — metric value and which commit achieved it
6. **Current code state** — read the target files (FILES glob)
7. **Iteration number** — to guide progression strategy

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

## Token Estimation

Track approximate token usage per iteration:

```text
current_token_estimate():
    # Estimate from context size: count characters in all tool inputs/outputs
    # since session start, divide by 4 (rough chars-per-token ratio)
    # This is an approximation — exact counting requires API response parsing
    return estimated_tokens
```

If the runtime exposes token counts in API responses, use those directly.
Otherwise, estimate from character count of tool calls and responses.

---

## Results Logging

Append to `todo/research/{name}-results.tsv`:

```text
{iteration}\t{commit_sha_or_dash}\t{metric_name}\t{metric_value_or_dash}\t{baseline}\t{delta_or_dash}\t{status}\t{hypothesis}\t{ISO_timestamp}\t{tokens_used}
```

Column definitions:

| Column | Type | Notes |
|--------|------|-------|
| `iteration` | int | Sequential experiment number (0 = baseline) |
| `commit` | string | Short SHA or `-` for crashes/discards |
| `metric_name` | string | From research program `name:` field |
| `metric_value` | float or `-` | Measured value; `-` for crashes/constraint fails |
| `baseline` | float | Original baseline value (same for all rows) |
| `delta` | float or `-` | `metric_value - baseline` (signed); `-` for crashes |
| `status` | string | `baseline`, `keep`, `discard`, `constraint_fail`, `crash` |
| `hypothesis` | string | What was tried (one line, no tabs) |
| `timestamp` | ISO 8601 | UTC timestamp |
| `tokens_used` | int | Approximate tokens consumed by this iteration |

Example rows:

```tsv
iteration	commit	metric_name	metric_value	baseline	delta	status	hypothesis	timestamp	tokens_used
0	(baseline)	build_time_s	12.4	12.4	0.0	baseline	(initial measurement)	2026-04-01T10:00:00Z	0
1	a1b2c3d	build_time_s	11.1	12.4	-1.3	keep	remove unused lodash import	2026-04-01T10:12:00Z	2340
2	-	build_time_s	12.8	12.4	0.4	discard	switch to esbuild (breaks API)	2026-04-01T10:24:00Z	3100
3	-	build_time_s	-	12.4	-	crash	double worker threads (OOM)	2026-04-01T10:36:00Z	1800
4	b2c3d4e	build_time_s	10.5	12.4	-1.9	keep	tree-shake utils/ barrel exports	2026-04-01T10:48:00Z	2800
```

---

## Memory Storage

After each **keep** or **discard** iteration:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME}: {hypothesis[:80]} → {status} ({METRIC_NAME}: {metric_value}, delta={delta:+.2f})" \
  --confidence medium
```

After **keep** iterations, also store a higher-confidence finding:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} FINDING: {hypothesis}. Improved {METRIC_NAME} by {abs(delta):.2f} ({improvement_pct:.1f}%). Commit: {commit_sha}" \
  --confidence high
```

At session end, store a summary:

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} session complete: {ITERATION_COUNT} iterations, best {METRIC_NAME}={BEST_METRIC} (baseline={BASELINE}, improvement={improvement_pct:.1f}%), total_tokens={TOTAL_TOKENS}" \
  --confidence high
```

---

## Mailbox Discovery Integration

Used in multi-dimension campaigns (CAMPAIGN_ID is set). No-ops when CAMPAIGN_ID is absent.

### Check peer discoveries (before each hypothesis generation)

```bash
mail-helper.sh check --agent "$AGENT_ID" --unread-only
# For each unread discovery message:
#   mail-helper.sh read <message-id> --agent "$AGENT_ID"
#   Parse payload JSON → add to hypothesis context as PEER_DISCOVERIES
```

Incorporate peer discoveries into hypothesis generation:
- If a peer found a `keep` result, consider whether the same change applies to this dimension
- If a peer found a `discard` result, deprioritize similar approaches

### Send discovery (after each keep or discard)

```bash
DISCOVERY_PAYLOAD=$(cat <<EOF
{
  "campaign": "{CAMPAIGN_ID}",
  "dimension": "{DIMENSION}",
  "hypothesis": "{hypothesis}",
  "status": "{keep|discard}",
  "metric_name": "{METRIC_NAME}",
  "metric_before": {BASELINE},
  "metric_after": {metric_value},
  "metric_delta": {delta},
  "files_changed": [{list of files modified}],
  "iteration": {ITERATION_COUNT},
  "commit": "{commit_sha_or_null}"
}
EOF
)

mail-helper.sh send \
  --from "$AGENT_ID" \
  --to "broadcast" \
  --type discovery \
  --payload "$DISCOVERY_PAYLOAD" \
  --convoy "{CAMPAIGN_ID}"
```

### Deregister on completion

```bash
mail-helper.sh deregister --agent "$AGENT_ID"
```

---

## Step 3: Completion

### 3.1 Deregister from mailbox (multi-dimension mode)

```bash
if CAMPAIGN_ID is set:
    mail-helper.sh deregister --agent "$AGENT_ID"
```

### 3.2 Store final memory

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} complete: {kept_count} kept, {discarded_count} discarded, {improvement_pct:.1f}% improvement in {METRIC_NAME}. Top finding: {top_hypothesis}" \
  --confidence high
```

### 3.3 Generate completion summary

Build the results summary for the PR body:

```markdown
## Autoresearch Results: {PROGRAM_NAME}

**Research:** {PROGRAM_NAME}
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
- Cost estimate: ~${cost_estimate:.2f} (sonnet pricing)

{If CAMPAIGN_ID is set, add cross-dimension summary section — see below}
```

ASCII sparkline (if ≥5 kept iterations):

```text
{METRIC_NAME} progression ({direction}):
{sparkline of metric_value for kept rows, 40 chars wide}
  iter: {first_kept}  →  {last_kept}
```

### 3.4 Cross-dimension summary (multi-dimension campaigns only)

If CAMPAIGN_ID is set, query the mailbox convoy for all dimension results:

```bash
sqlite3 ~/.aidevops/.agent-workspace/mail/mailbox.db \
  "SELECT from_agent, payload FROM messages
   WHERE convoy='{CAMPAIGN_ID}' AND type='discovery' AND json_extract(payload,'$.status')='keep'
   ORDER BY created_at"
```

Build cross-dimension summary:

```markdown
### Cross-Dimension Summary

| Dimension | Baseline | Best | Delta | Improvement | Iterations |
|-----------|----------|------|-------|-------------|------------|
{For each dimension found in convoy messages:}
| {dimension} | {baseline} | {best} | {delta:+.2f} | {improvement_pct:.1f}% | {iteration_count} |

### Cross-Pollination

{For each discovery where a peer's finding was adopted:}
- {source_dimension} found "{hypothesis}" → {target_dimension} adopted (iteration {N})

{If no cross-pollination occurred:}
- Dimensions ran independently (no cross-pollination detected)
```

### 3.5 Create PR from experiment branch

```bash
git -C WORKTREE_PATH push -u origin BRANCH

RESULTS_SUMMARY="$(generate_completion_summary)"

gh pr create \
  --repo {REPO_SLUG} \
  --head BRANCH \
  --base main \
  --title "experiment({PROGRAM_NAME}): {improvement_pct:+.1f}% improvement in {METRIC_NAME}" \
  --body "${RESULTS_SUMMARY}

Closes #{issue_number_if_any}"
```

### 3.6 Store PR memory

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} PR created: {pr_url}. Best: {METRIC_NAME}={BEST_METRIC}. Key finding: {top_hypothesis}" \
  --confidence high
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

## Related

`.agents/templates/research-program-template.md` · `.agents/scripts/commands/autoresearch.md` · `todo/research/`
