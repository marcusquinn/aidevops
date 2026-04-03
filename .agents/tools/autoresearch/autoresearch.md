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
- **Sub-docs**: `autoresearch/loop.md` · `autoresearch/logging.md` · `autoresearch/completion.md` · `autoresearch/agent-optimization.md`

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
    ITERATION_COUNT = 0; BEST_METRIC = null; BASELINE = null
    FAILED_HYPOTHESES = []; TOTAL_TOKENS = 0
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

If CAMPAIGN_ID is set:

```bash
AGENT_ID="autoresearch-${PROGRAM_NAME}-${DIMENSION:-solo}"
mail-helper.sh register --agent "$AGENT_ID"
```

### 1.6 Measure baseline (first run only)

```text
if BASELINE == null:
    Run all constraints. If any fail: exit with error (baseline environment is broken).
    Run METRIC_CMD. Parse numeric output → BASELINE = BEST_METRIC = result
    Update program file: set `baseline: {value}`
    Append to results.tsv:
      0\t(baseline)\t{METRIC_NAME}\t{BASELINE}\t{BASELINE}\t0.0\tbaseline\t(initial measurement)\t{timestamp}\t0
```

---

## Step 2: Experiment Loop

See `autoresearch/loop.md` for full loop pseudocode, hypothesis generation rules,
constraint checking, metric measurement, improvement check, and token estimation.

Loop exits when any budget condition is met (timeout / max_iterations / goal_reached).

---

## Step 3: Completion

See `autoresearch/completion.md` for deregister, final memory, completion summary,
cross-dimension summary, PR creation, crash recovery, and budget enforcement table.

---

## Logging, Memory & Mailbox

See `autoresearch/logging.md` for results TSV schema, memory storage commands,
and mailbox discovery integration (multi-dimension campaigns).

---

## Agent Optimization Domain

When `PROGRAM_NAME == "agent-optimization"` or `METRIC_CMD` contains `agent-test-helper.sh`,
load `autoresearch/agent-optimization.md` for composite metric parsing, security exemptions,
simplification state integration, and hypothesis type ordering.

---

## Related

`.agents/templates/research-program-template.md` · `.agents/scripts/commands/autoresearch.md` · `todo/research/` · `todo/research/agent-optimization.md`
