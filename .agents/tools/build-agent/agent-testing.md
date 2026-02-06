---
name: agent-testing
description: Agent testing framework - validate agent behavior with isolated AI sessions
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Agent Testing Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `agent-test-helper.sh [run|run-one|compare|baseline|list|create|results|help]`
- **Test suites**: JSON files in `~/.aidevops/.agent-workspace/agent-tests/suites/`
- **Results**: `~/.aidevops/.agent-workspace/agent-tests/results/`
- **Baselines**: `~/.aidevops/.agent-workspace/agent-tests/baselines/`
- **CLI support**: Auto-detects `claude` or `opencode` (override with `AGENT_TEST_CLI`)

**When to use**:

- Validating agent changes before merging
- Regression testing after modifying AGENTS.md or subagents
- Comparing agent behavior across models
- Smoke testing after framework updates

<!-- AI-CONTEXT-END -->

## Architecture

```text
                    ┌──────────────────────────────┐
                    │     agent-test-helper.sh      │
                    ├──────────────────────────────┤
                    │  Test Suite (JSON)            │
                    │  ├── Prompt definitions       │
                    │  ├── Expected patterns        │
                    │  └── Pass/fail criteria       │
                    └──────────┬───────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     Claude Code CLI    OpenCode CLI     OpenCode Server
     (claude -p)        (opencode run)   (HTTP API)
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────┴───────────────┐
                    │  Validation Engine        │
                    │  ├── expect_contains      │
                    │  ├── expect_not_contains  │
                    │  ├── expect_regex         │
                    │  ├── min/max_length       │
                    │  └── Pass/Fail verdict    │
                    └──────────────────────────┘
```

## Test Suite Format

Test suites are JSON files defining prompts and expected response patterns:

```json
{
  "name": "build-agent-tests",
  "description": "Validates build-agent subagent knowledge",
  "agent": "Build+",
  "model": "anthropic/claude-sonnet-4-20250514",
  "timeout": 120,
  "tests": [
    {
      "id": "instruction-budget",
      "prompt": "What is the recommended instruction budget for agents?",
      "expect_contains": ["50", "100"],
      "expect_not_contains": ["unlimited"],
      "min_length": 50
    },
    {
      "id": "progressive-disclosure",
      "prompt": "Explain the progressive disclosure pattern for agents",
      "expect_contains": ["subagent", "on-demand"],
      "expect_regex": "read.*when.*needed",
      "min_length": 100
    }
  ]
}
```

### Validation Options

| Field | Type | Description |
|-------|------|-------------|
| `expect_contains` | `string[]` | Response must contain each string (case-insensitive) |
| `expect_not_contains` | `string[]` | Response must NOT contain any of these |
| `expect_regex` | `string` | Response must match this regex (case-insensitive) |
| `expect_not_regex` | `string` | Response must NOT match this regex |
| `min_length` | `number` | Minimum response length in characters |
| `max_length` | `number` | Maximum response length in characters |
| `skip` | `boolean` | Skip this test (useful for temporarily disabling) |

### Per-Test Overrides

Each test can override suite-level defaults:

```json
{
  "id": "slow-test",
  "prompt": "Generate a comprehensive analysis...",
  "agent": "plan",
  "model": "anthropic/claude-opus-4-20250514",
  "timeout": 300,
  "expect_contains": ["analysis"]
}
```

## Commands

### Run a Test Suite

```bash
# By file path
agent-test-helper.sh run path/to/suite.json

# By name (looks in suites/ directory)
agent-test-helper.sh run build-agent-tests
```

### Quick Single-Prompt Test

```bash
# Basic test
agent-test-helper.sh run-one "What is your primary purpose?"

# With expected pattern
agent-test-helper.sh run-one "List your tools" --expect "bash"

# With specific agent and model
agent-test-helper.sh run-one "Explain git workflow" \
  --agent "Build+" \
  --model "anthropic/claude-sonnet-4-20250514" \
  --timeout 60
```

### Before/After Comparison

The comparison workflow validates that agent changes don't cause regressions:

```bash
# 1. Save current behavior as baseline
agent-test-helper.sh baseline my-tests

# 2. Make agent changes (edit AGENTS.md, subagents, etc.)

# 3. Compare against baseline
agent-test-helper.sh compare my-tests
```

The comparison reports:

- Per-test status changes (pass -> fail = regression, fail -> pass = fix)
- Overall pass/fail count changes
- Non-zero exit code if regressions detected

### Manage Test Suites

```bash
# Create a template
agent-test-helper.sh create my-new-tests

# List available suites
agent-test-helper.sh list

# View recent results
agent-test-helper.sh results
agent-test-helper.sh results my-tests  # Filter by name
```

## CLI Detection

The framework auto-detects the available AI CLI:

1. **Claude Code** (`claude -p`): Preferred when available
2. **OpenCode server** (`curl` to HTTP API): Used when OpenCode server is running
3. **OpenCode CLI** (`opencode run`): Fallback for OpenCode without server

Override with `AGENT_TEST_CLI=claude` or `AGENT_TEST_CLI=opencode`.

## Example Test Suites

### AGENTS.md Knowledge Test

Tests that the agent has absorbed key instructions from AGENTS.md:

```json
{
  "name": "agents-md-knowledge",
  "description": "Validates core AGENTS.md instruction absorption",
  "timeout": 90,
  "tests": [
    {
      "id": "pre-edit-check",
      "prompt": "What must you run before editing any file?",
      "expect_contains": ["pre-edit-check"],
      "expect_regex": "pre-edit-check\\.sh"
    },
    {
      "id": "file-discovery",
      "prompt": "How should you find git-tracked files?",
      "expect_contains": ["git ls-files"],
      "expect_not_contains": ["mcp_glob", "Glob"]
    },
    {
      "id": "security-credentials",
      "prompt": "Where should credentials be stored?",
      "expect_contains": ["mcp-env.sh"],
      "expect_regex": "600"
    }
  ]
}
```

### Subagent Behavior Test

Tests that a specific subagent provides correct guidance:

```json
{
  "name": "git-workflow-tests",
  "description": "Validates git workflow subagent behavior",
  "agent": "Build+",
  "tests": [
    {
      "id": "branch-naming",
      "prompt": "What branch naming conventions should I use?",
      "expect_contains": ["feature/", "bugfix/"],
      "min_length": 100
    },
    {
      "id": "worktree-usage",
      "prompt": "When should I use git worktrees?",
      "expect_contains": ["worktree", "parallel"],
      "min_length": 50
    }
  ]
}
```

## Integration with CI/CD

Run agent tests in CI pipelines:

```bash
# In GitHub Actions or similar
agent-test-helper.sh run agents-md-knowledge || {
  echo "Agent tests failed - check for regressions"
  exit 1
}
```

Requires an AI CLI available in the CI environment (e.g., `claude` with API key or `opencode` with server).

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_TEST_CLI` | auto-detect | Force `claude` or `opencode` |
| `AGENT_TEST_MODEL` | (suite default) | Override model for all tests |
| `AGENT_TEST_TIMEOUT` | `120` | Default timeout in seconds |
| `OPENCODE_HOST` | `localhost` | OpenCode server host |
| `OPENCODE_PORT` | `4096` | OpenCode server port |

## Related

- `build-agent.md` - Agent design and composition
- `agent-review.md` - Reviewing and improving agents
- `tools/ai-assistants/headless-dispatch.md` - Headless AI dispatch patterns
- `tools/ai-assistants/opencode-server.md` - OpenCode server API
- `scripts/self-improve-helper.sh` - Self-improving agent system (uses similar session patterns)
