# Autoagent — Signal Mining

Sub-doc for `autoagent.md`. Loaded during Step 1 (Setup) to extract actionable signals.

Signal mining converts raw operational data into structured findings: `{file, issue, source}` objects that feed hypothesis generation.

## Signal Sources

Run all sources unless `SIGNAL_SOURCES` is set (see [Filtering](#filtering-by-signal_sources)).

### 1. Session Miner Data

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

### 2. Pulse Dispatch Outcomes

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

### 3. Error-Feedback Patterns

```bash
# Load error-feedback patterns
cat ~/.aidevops/agents/workflows/error-feedback.md 2>/dev/null | \
  grep -E "^- |^\* " | head -30

# Scan for patterns in build.txt that address recurring errors
rg "observed|recurring|failure rate|%" ~/.aidevops/agents/prompts/build.txt 2>/dev/null | \
  head -20
```

### 4. Comprehension Test Results

```bash
# Run comprehension tests and capture failures
# --json emits composite metric only (pass_rate, failed, passed, total)
agent-test-helper.sh run --suite agent-optimization --json 2>/dev/null | \
  jq '{failed: .failed, pass_rate: .pass_rate, source: "comprehension-tests"}'

# List individual failed tests from the latest result file
latest=$(ls -t ~/.aidevops/.agent-workspace/agent-tests/results/agent-optimization-*.json 2>/dev/null | head -1)
[[ -n "$latest" ]] && jq -r '.results[] | select(.status == "fail") | {id: .id, status: .status}' "$latest"

# Check which test suites exist
ls ~/.aidevops/agents/tests/*.test.json 2>/dev/null | head -10
```

### 5. Git Churn Analysis

```bash
# Files in .agents/ that changed most in last 30 days
git -C "$REPO_ROOT" log --since="30 days ago" --name-only --format="" -- .agents/ 2>/dev/null | \
  grep -v "^$" | sort | uniq -c | sort -rn | head -20

# Files that appear in reverted commits
git -C "$REPO_ROOT" log --oneline --since="30 days ago" 2>/dev/null | \
  grep -i "revert\|fix\|hotfix" | head -10
```

### 6. Linter Violations

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

### 7. Instruction Candidates (instruction-to-save)

Detects user utterances from session history that appear to be persistent rules or
conventions that should be captured in instruction files (AGENTS.md, build.txt, etc.).

Sourced from the session miner pipeline — available in `compressed_signals.json` after
a pulse run, and surfaced in the pulse summary under "Instruction Candidates".

```bash
# Read instruction candidates from latest compressed signals
COMPRESSED=$(ls -t ~/.aidevops/.agent-workspace/work/session-miner/pulse_*/compressed_signals.json 2>/dev/null | head -1)
[[ -n "$COMPRESSED" ]] && python3 -c "
import json, sys
from pathlib import Path
data = json.loads(Path('$COMPRESSED').read_text())
candidates = data.get('instruction_candidates', {})
for target, items in candidates.items():
    for c in items[:5]:
        print(f'{target} [{c[\"confidence\"]:.0%}] {c[\"text\"][:120]}')
" 2>/dev/null

# Or read from the feedback report
cat ~/.aidevops/.agent-workspace/work/session-miner/feedback_actions.md 2>/dev/null | \
  awk '/## Instruction Candidates/,0'
```

**Detection criteria (conservative — high precision over recall):**

- Explicit save requests: "add this to AGENTS.md", "update build.txt"
- Persistent directive language: "from now on", "going forward", "always use X", "never do Y"
- Convention declarations: "the rule is", "we always", "prefer X over Y"
- Filtered out: task-specific directions referencing particular files, PRs, commits, or one-off commands

**Finding format for instruction candidates:**

```json
{
  "file": ".agents/prompts/build.txt",
  "issue": "instruction-to-save: 'always use local var=\"$1\" in shell functions' (confidence: 90%)",
  "source": "instruction-to-save",
  "priority": "medium",
  "frequency": 1
}
```

Candidates are surfaced as suggestions only — never auto-applied. A human or the
autoagent hypothesis loop decides whether to act on them.

## Finding Format

Each source produces findings in this shape:

| Source | `file` | `issue` | `source` key |
|--------|--------|---------|--------------|
| Session Miner | `.agents/path/to/file.md` | recurring error description | `session-miner` |
| Pulse Outcomes | `null` | task pattern that fails repeatedly | `pulse-outcomes` |
| Error-Feedback | `.agents/prompts/build.txt` | pattern description | `error-feedback` |
| Comprehension Tests | `.agents/path/to/agent.md` | test failure description | `comprehension-tests` |
| Git Churn | `.agents/path/to/file.md` | high churn — N changes in 30 days | `git-churn` |
| Linter | `.agents/scripts/helper.sh` | shellcheck SC2086: double-quote variable | `linter` |
| Instruction Candidates | `.agents/prompts/build.txt` | instruction-to-save: user guidance text (confidence: N%) | `instruction-to-save` |

## Finding Aggregation

After all sources run, deduplicate by `(file, issue)` pair, rank by frequency, limit to top 20:

```bash
SIGNAL_FINDINGS = deduplicate_and_rank([
    session_miner_findings,
    pulse_outcome_findings,
    error_feedback_findings,
    comprehension_test_findings,
    git_churn_findings,
    linter_findings,
    instruction_to_save_findings
])
```

**Priority ranking:**

| Priority | Condition |
|----------|-----------|
| High | File appears in 3+ signal sources |
| Medium | File appears in 2 signal sources |
| Low | File appears in 1 signal source |

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
| `instruction-to-save` | Instruction candidates from session history |
| `all` | All sources (default) |

Example: `signal_sources: session-miner,git-churn` runs only those two sources.

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
