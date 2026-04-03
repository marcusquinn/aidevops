# Autoagent — Signal Mining

Sub-doc for `autoagent.md`. Loaded during Step 1 (Setup) to extract actionable signals.

---

## Overview

Signal mining converts raw operational data into structured findings: `{file, issue, source}` objects that feed hypothesis generation. Each source produces a list of specific file + issue pairs.

---

## Signal Sources

### 1. Session Miner Data

Extracts error patterns and recurring failures from session history.

```bash
# Get error patterns from session miner
session-miner-pulse.sh --output json 2>/dev/null | jq -r '
  .error_patterns[]? |
  {file: .file, issue: .pattern, source: "session-miner"}
' 2>/dev/null

# Fallback: scan recent session transcripts for recurring errors
rg --json "error|failed|FAIL|not found" ~/.claude/projects/ 2>/dev/null | \
  jq -r 'select(.type=="match") | .data.path.text + ": " + .data.lines.text' | \
  sort | uniq -c | sort -rn | head -20
```

**Finding format:** `{file: ".agents/path/to/file.md", issue: "recurring error description", source: "session-miner"}`

### 2. Pulse Dispatch Outcomes

Identifies which tasks fail repeatedly or take disproportionate time.

```bash
# Worker success/failure rates from recent pulse runs
gh run list --repo marcusquinn/aidevops --limit 50 --json conclusion,name,createdAt 2>/dev/null | \
  jq -r '.[] | select(.conclusion == "failure") | .name' | \
  sort | uniq -c | sort -rn | head -10

# PRs closed without merge (worker failures)
gh pr list --repo marcusquinn/aidevops --state closed --limit 50 \
  --json title,mergedAt,closedAt 2>/dev/null | \
  jq -r '.[] | select(.mergedAt == null) | .title' | head -10
```

**Finding format:** `{file: null, issue: "task pattern that fails repeatedly", source: "pulse-outcomes"}`

### 3. Error-Feedback Patterns

Mines recurring errors from the error-feedback agent's documented patterns.

```bash
# Load error-feedback patterns
cat ~/.aidevops/agents/workflows/error-feedback.md 2>/dev/null | \
  grep -E "^- |^\* " | head -30

# Scan for patterns in build.txt that address recurring errors
rg "observed|recurring|failure rate|%" ~/.aidevops/agents/prompts/build.txt 2>/dev/null | \
  head -20
```

**Finding format:** `{file: ".agents/prompts/build.txt", issue: "pattern description from error-feedback", source: "error-feedback"}`

### 4. Comprehension Test Results

Identifies which agent files cause model confusion or test failures.

```bash
# Run comprehension tests and capture failures
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null | \
  jq -r '.failures[]? | {file: .agent_file, issue: .failure_reason, source: "comprehension-tests"}'

# Check which test suites exist
ls ~/.aidevops/agents/tests/*.test.json 2>/dev/null | head -10
```

**Finding format:** `{file: ".agents/path/to/agent.md", issue: "test failure description", source: "comprehension-tests"}`

### 5. Git Churn Analysis

Files that change most frequently are likely pain points or poorly-designed abstractions.

```bash
# Files in .agents/ that changed most in last 30 days
git -C "$REPO_ROOT" log --since="30 days ago" --name-only --format="" -- .agents/ 2>/dev/null | \
  grep -v "^$" | sort | uniq -c | sort -rn | head -20

# Files that appear in reverted commits
git -C "$REPO_ROOT" log --oneline --since="30 days ago" 2>/dev/null | \
  grep -i "revert\|fix\|hotfix" | head -10
```

**Finding format:** `{file: ".agents/path/to/file.md", issue: "high churn — N changes in 30 days", source: "git-churn"}`

### 6. Linter Violations

Current lint violations indicate quality debt in specific files.

```bash
# Run linters and capture violations
~/.aidevops/agents/scripts/linters-local.sh 2>&1 | \
  grep -E "error|warning|violation" | head -30

# ShellCheck violations in scripts
find ~/.aidevops/agents/scripts/ -name "*.sh" -exec shellcheck --format=json {} \; 2>/dev/null | \
  jq -r 'select(.level == "error") | .file + ": " + .message' | head -20

# Markdownlint violations in agent docs
markdownlint-cli2 ~/.aidevops/agents/**/*.md 2>&1 | \
  grep -v "^$" | head -30
```

**Finding format:** `{file: ".agents/scripts/helper.sh", issue: "shellcheck SC2086: double-quote variable", source: "linter"}`

---

## Finding Aggregation

After running all enabled signal sources, aggregate findings:

```bash
# Deduplicate by (file, issue) pair
# Sort by frequency (files appearing in multiple sources = higher priority)
# Limit to top 20 findings for hypothesis generation

SIGNAL_FINDINGS = deduplicate_and_rank([
    session_miner_findings,
    pulse_outcome_findings,
    error_feedback_findings,
    comprehension_test_findings,
    git_churn_findings,
    linter_findings
])
```

**Priority ranking:**

| Priority | Condition |
|----------|-----------|
| High | File appears in 3+ signal sources |
| Medium | File appears in 2 signal sources |
| Low | File appears in 1 signal source |

---

## Filtering by SIGNAL_SOURCES

When `SIGNAL_SOURCES` is set in the research program, only run the listed sources:

| Source key | Description |
|------------|-------------|
| `session-miner` | Session miner data |
| `pulse-outcomes` | Pulse dispatch outcomes |
| `error-feedback` | Error-feedback patterns |
| `comprehension-tests` | Comprehension test results |
| `git-churn` | Git churn analysis |
| `linter` | Linter violations |
| `all` | All sources (default) |

Example: `signal_sources: session-miner,git-churn` runs only those two sources.

---

## Output Contract

Signal mining produces `SIGNAL_FINDINGS` — a ranked list passed to hypothesis generation:

```json
[
  {
    "file": ".agents/prompts/build.txt",
    "issue": "webfetch failure rate 46.8% — URL guessing pattern",
    "source": "error-feedback",
    "priority": "high",
    "frequency": 3
  },
  {
    "file": ".agents/scripts/dispatch-helper.sh",
    "issue": "high churn — 12 changes in 30 days",
    "source": "git-churn",
    "priority": "medium",
    "frequency": 1
  }
]
```
