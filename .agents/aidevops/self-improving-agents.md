---
description: Self-improving agent system for continuous enhancement
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Self-Improving Agent System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `~/.aidevops/agents/scripts/self-improve-helper.sh`
- **Phases**: analyze → refine → test → pr
- **Requires**: OpenCode server, memory-helper.sh, privacy-filter-helper.sh
- **Workspace**: `~/.aidevops/.agent-workspace/self-improve/`
- **Server**: `opencode serve --port 4096`

<!-- AI-CONTEXT-END -->

The self-improving agent system enables aidevops to learn from failures, generate improvements, test them in isolation, and contribute back to the framework with privacy-safe PRs.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                 Self-Improvement Cycle                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌────────┐ │
│  │ ANALYZE  │───▶│  REFINE  │───▶│   TEST   │───▶│   PR   │ │
│  └──────────┘    └──────────┘    └──────────┘    └────────┘ │
│       │               │               │               │      │
│       ▼               ▼               ▼               ▼      │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌────────┐ │
│  │ Memory   │    │ OpenCode │    │ OpenCode │    │ GitHub │ │
│  │ Patterns │    │ Session  │    │ Session  │    │   PR   │ │
│  └──────────┘    └──────────┘    └──────────┘    └────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Phases

### 1. Analyze Phase

Query memory for failure patterns and identify improvement opportunities.

```bash
self-improve-helper.sh analyze
```

**What it does:**
- Queries memory for FAILED_APPROACH entries
- Queries memory for ERROR_FIX entries
- Identifies gaps (failures without corresponding solutions)
- Saves analysis to `analysis.json`

**Output:**

```text
Memory Summary:
  - Failed approaches: 15
  - Error fixes: 8
  - Working solutions: 42
  - Codebase patterns: 12

Gaps identified: 7 (failures without solutions)
```

### 2. Refine Phase

Generate specific improvement proposals using OpenCode.

```bash
self-improve-helper.sh refine [--dry-run]
```

**What it does:**
- Creates OpenCode session for improvement generation
- Sends analysis data with structured prompt
- Receives proposals as JSON array
- Saves proposals to `proposals.json`

**Proposal format:**

```json
{
  "file": ".agent/workflows/git-workflow.md",
  "change_type": "edit",
  "description": "Add guidance for handling merge conflicts",
  "diff": "...",
  "impact": "Reduces merge conflict failures by 30%",
  "test_prompt": "Simulate a merge conflict scenario..."
}
```

### 3. Test Phase

Validate improvements in isolated OpenCode sessions.

```bash
self-improve-helper.sh test [session-id]
```

**What it does:**
- Loads proposals from previous phase
- Runs each proposal's test_prompt in OpenCode
- Checks responses for error indicators
- Saves results to `test-results.json`

**Test criteria:**
- Response doesn't contain error keywords
- Task completes without exceptions
- Output matches expected patterns

### 4. PR Phase

Create privacy-filtered PR with evidence.

```bash
self-improve-helper.sh pr [--dry-run]
```

**What it does:**
- Runs mandatory privacy filter scan
- Builds PR body with evidence:
  - Memory analysis summary
  - Test results attestation
  - Privacy filter confirmation
- Creates PR via gh CLI

**PR includes:**
- Summary of improvements
- Evidence from memory analysis
- Test results for each change
- Privacy attestation

## Prerequisites

### OpenCode Server

Start the server before running improvement cycles:

```bash
opencode serve --port 4096
```

Or with authentication:

```bash
OPENCODE_SERVER_PASSWORD=secret opencode serve --port 4096
```

### Memory System

The analyze phase requires populated memory:

```bash
# Check memory stats
memory-helper.sh stats

# Ensure there are failure entries
memory-helper.sh recall --type FAILED_APPROACH --limit 5
```

### Privacy Filter

The PR phase requires the privacy filter:

```bash
# Verify installation
privacy-filter-helper.sh status

# Test scan
privacy-filter-helper.sh scan .
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_HOST` | `localhost` | OpenCode server hostname |
| `OPENCODE_PORT` | `4096` | OpenCode server port |

### Workspace Files

```text
~/.aidevops/.agent-workspace/self-improve/
├── analysis.json      # Memory analysis results
├── proposals.json     # Generated improvement proposals
└── test-results.json  # Test validation results
```

## Usage Examples

### Full Improvement Cycle

```bash
# 1. Start OpenCode server
opencode serve --port 4096 &

# 2. Run improvement cycle
self-improve-helper.sh analyze
self-improve-helper.sh refine
self-improve-helper.sh test
self-improve-helper.sh pr

# 3. Review and merge PR
gh pr view
```

### Dry Run Preview

```bash
# Preview what would be generated
self-improve-helper.sh refine --dry-run

# Preview PR without creating
self-improve-helper.sh pr --dry-run
```

### Check Status

```bash
self-improve-helper.sh status
```

Output:

```text
Self-Improvement Status

✅ Analysis: 2026-02-04T12:00:00Z (7 gaps)
✅ Proposals: 2026-02-04T12:15:00Z (5 proposals)
✅ Tests: 2026-02-04T12:30:00Z (5 passed, 0 failed)
✅ OpenCode server: Running at http://localhost:4096
```

## Safety Guardrails

### Privacy Filter (Mandatory)

The PR phase will not proceed without passing the privacy filter:

- Secretlint scan for credentials
- Pattern-based detection for PII
- Project-specific patterns from `.aidevops/privacy-patterns.txt`

### Worktree Isolation

All changes must be made in a worktree, not on main:

```bash
# Create worktree for improvements
wt switch -c feature/self-improve-$(date +%Y%m%d)

# Run improvement cycle
self-improve-helper.sh analyze
# ...
```

### Human Approval

The PR phase requires:
1. All tests to pass
2. Privacy filter to pass
3. Human review before merge

### Dry Run Mode

Always preview with `--dry-run` first:

```bash
self-improve-helper.sh refine --dry-run
self-improve-helper.sh pr --dry-run
```

## Integration with Memory

### Storing Learnings

After successful improvements, store the pattern:

```bash
memory-helper.sh store \
  --content "Self-improvement: Added merge conflict guidance to git-workflow.md" \
  --type WORKING_SOLUTION \
  --tags "self-improve,git,merge-conflict"
```

### Querying Patterns

The analyze phase queries these memory types:

| Type | Purpose |
|------|---------|
| `FAILED_APPROACH` | What didn't work |
| `ERROR_FIX` | Errors and their fixes |
| `WORKING_SOLUTION` | Successful approaches |
| `CODEBASE_PATTERN` | Code conventions |

## Scheduling

### Manual Trigger

Run the improvement cycle manually when needed:

```bash
self-improve-helper.sh analyze && \
self-improve-helper.sh refine && \
self-improve-helper.sh test && \
self-improve-helper.sh pr --dry-run
```

### Cron Integration (Future)

The cron agent (t110) will enable scheduled improvement cycles:

```bash
# Weekly improvement analysis (future)
cron-agent add "self-improve-weekly" \
  --schedule "0 2 * * 0" \
  --command "self-improve-helper.sh analyze"
```

## Troubleshooting

### OpenCode Server Not Running

```bash
# Check if running
curl http://localhost:4096/global/health

# Start server
opencode serve --port 4096
```

### No Memory Entries

```bash
# Check memory stats
memory-helper.sh stats

# Store some test entries
memory-helper.sh store \
  --content "Test failure: X didn't work because Y" \
  --type FAILED_APPROACH
```

### Privacy Filter Fails

```bash
# See what's detected
privacy-filter-helper.sh scan .

# Add exceptions if needed
privacy-filter-helper.sh patterns add-project 'test\.example\.com'
```

### Tests Fail

Review the test results:

```bash
cat ~/.aidevops/.agent-workspace/self-improve/test-results.json | jq '.'
```

Refine proposals and re-test:

```bash
self-improve-helper.sh refine
self-improve-helper.sh test
```

## Related Documentation

- `tools/ai-assistants/opencode-server.md` - OpenCode server API
- `tools/security/privacy-filter.md` - Privacy filter usage
- `memory/README.md` - Memory system documentation
- `workflows/pr.md` - PR creation workflow
