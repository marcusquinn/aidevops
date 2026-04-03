# Autoagent — Signal Mining

Sub-doc for `autoagent.md`. Loaded during Step 1 setup.

---

## Overview

Signal mining extracts actionable findings from framework observability data. Each signal source produces a structured list of `(file, issue, severity)` tuples that feed hypothesis generation.

A **finding** is: a specific file + a specific problem + evidence that the problem is real.

---

## Signal Sources

### 1. Session Miner Data

Extracts recurring error patterns from session transcripts.

```bash
# Run session miner and extract error patterns
session-miner-pulse.sh --output json 2>/dev/null | jq -r '
  .error_patterns[]? |
  "\(.file // "unknown")\t\(.pattern)\t\(.count)"
' | sort -t$'\t' -k3 -rn | head -20
```

**Finding format:** `{file: ".agents/prompts/build.txt", issue: "read:file_not_found pattern (47x)", severity: "high"}`

**What to look for:**
- Patterns occurring 5+ times → high severity
- Patterns in agent instruction files → instruction refinement candidates
- Patterns in scripts → tool optimization or self-healing candidates

### 2. Pulse Dispatch Outcomes

Extracts worker success/failure rates from recent pulse runs.

```bash
# Worker failure rate by task type
gh run list --repo marcusquinn/aidevops --limit 50 --json conclusion,name \
  | jq -r '.[] | "\(.conclusion)\t\(.name)"' \
  | sort | uniq -c | sort -rn
```

```bash
# PRs closed without merge (worker failures)
gh pr list --repo marcusquinn/aidevops --state closed --limit 50 \
  --json title,mergedAt,closedAt,labels \
  | jq -r '.[] | select(.mergedAt == null) | .title'
```

**Finding format:** `{file: "workflows/full-loop.md", issue: "15% of worker PRs closed without merge", severity: "medium"}`

**What to look for:**
- Failure rate >10% for a task type → workflow optimization candidate
- Repeated PR close-without-merge → instruction clarity issue
- Auth failures → credential handling gap

### 3. Error-Feedback Patterns

Extracts recurring errors from the error-feedback agent's history.

```bash
# Recent error-feedback findings
git log --since="30 days ago" --oneline --all -- .agents/ \
  | grep -i "fix\|error\|bug\|fail" | head -20
```

```bash
# Files most often in bugfix commits
git log --since="30 days ago" --name-only --format="" -- .agents/ \
  | sort | uniq -c | sort -rn | head -20
```

**Finding format:** `{file: ".agents/scripts/full-loop-helper.sh", issue: "unbound variable errors in 3 recent bugfixes", severity: "high"}`

**What to look for:**
- Same file appearing in 3+ bugfix commits → self-healing candidate
- Script errors → tool optimization candidate
- Workflow doc in bugfix commits → instruction refinement candidate

### 4. Comprehension Test Results

Extracts which agent files cause model confusion.

```bash
# Run comprehension tests and extract failures
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null \
  | jq -r '.failures[]? | "\(.file)\t\(.test_name)\t\(.score)"'
```

```bash
# Linter violations in agent files
markdownlint-cli2 ".agents/**/*.md" --json 2>/dev/null \
  | jq -r '.[] | "\(.fileName)\t\(.ruleNames[0])\t\(.errorCount)"' \
  | sort -t$'\t' -k3 -rn | head -20
```

**Finding format:** `{file: ".agents/tools/autoresearch/autoresearch.md", issue: "comprehension score 0.62 on step-ordering test", severity: "high"}`

**What to look for:**
- Comprehension score <0.75 → instruction refinement candidate
- Linter violations in frequently-read files → quality debt
- Tests failing on the same concept across multiple files → consolidation opportunity

### 5. Git Log Patterns

Extracts files that change most frequently (pain points) and files that get reverted.

```bash
# Files with highest churn in .agents/ (last 30 days)
git log --since="30 days ago" --name-only --format="" -- .agents/ \
  | sort | uniq -c | sort -rn | head -20
```

```bash
# Reverted commits (indicator of bad changes)
git log --since="30 days ago" --oneline --all \
  | grep -i "revert\|rollback" | head -10
```

```bash
# Files changed in revert commits
git log --since="30 days ago" --all --format="%H %s" \
  | grep -i "revert" \
  | awk '{print $1}' \
  | xargs -I{} git diff-tree --no-commit-id -r --name-only {} 2>/dev/null \
  | sort | uniq -c | sort -rn
```

**Finding format:** `{file: ".agents/prompts/build.txt", issue: "highest churn file (23 changes in 30 days)", severity: "medium"}`

**What to look for:**
- High-churn files → likely pain points, simplification candidates
- Files in revert commits → stability issues, regression risk
- Files changed together frequently → coupling, possible merge candidate

---

## Finding Aggregation

After mining all enabled sources, aggregate findings:

```text
SIGNAL_FINDINGS = []
for each source in SIGNAL_SOURCES:
    findings = mine_source(source)
    SIGNAL_FINDINGS.extend(findings)

# Deduplicate by (file, issue) pair
# Sort by severity (high > medium > low), then by evidence count
SIGNAL_FINDINGS = deduplicate_and_sort(SIGNAL_FINDINGS)

# Cap at 20 findings to keep hypothesis generation focused
SIGNAL_FINDINGS = SIGNAL_FINDINGS[:20]
```

**Output format per finding:**

```json
{
  "file": ".agents/prompts/build.txt",
  "issue": "read:file_not_found pattern (47x in session miner)",
  "severity": "high",
  "source": "session_miner",
  "evidence_count": 47,
  "hypothesis_types": ["self_healing", "instruction_refinement"]
}
```

---

## Signal-to-Hypothesis Mapping

| Signal source | Primary hypothesis types |
|---------------|--------------------------|
| Session miner errors | Self-healing, Instruction refinement |
| Pulse failures | Workflow optimization, Instruction refinement |
| Error-feedback patterns | Self-healing, Tool optimization |
| Comprehension test failures | Instruction refinement, Agent composition |
| Git churn | Simplification, Instruction refinement |
| Git reverts | Self-healing, Safety review |
