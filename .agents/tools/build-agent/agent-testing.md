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
- **Shipped suites**: `.agents/tests/*.json` (repo-shipped, version-controlled)
- **User suites**: `~/.aidevops/.agent-workspace/agent-tests/suites/`
- **Results**: `~/.aidevops/.agent-workspace/agent-tests/results/`
- **Baselines**: `~/.aidevops/.agent-workspace/agent-tests/baselines/`
- **CLI**: Auto-detects `opencode` (override with `AGENT_TEST_CLI`)

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
               ┌───────────────┼───────────────┐
               │                               │
        OpenCode CLI                    OpenCode Server
        (opencode run --format json)    (HTTP API)
               │                               │
               └───────────────┼───────────────┘
                               │
                    ┌──────────┴───────────────┐
                    │  Validation Engine        │
                    │  ├── expect_contains      │
                    │  ├── expect_not_contains  │
                    │  ├── expect_regex         │
                    │  ├── expect_not_regex     │
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
  "agent": "Plan+",
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

# By name (searches suites/ dir and repo-shipped .agents/tests/)
agent-test-helper.sh run smoke-test

# Run shipped suite directly
agent-test-helper.sh run agents-md-knowledge
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
agent-test-helper.sh baseline smoke-test

# 2. Make agent changes (edit AGENTS.md, subagents, etc.)

# 3. Compare against baseline
agent-test-helper.sh compare smoke-test
```

The comparison reports:

- Per-test status changes (pass -> fail = regression, fail -> pass = fix)
- Overall pass/fail count changes
- Non-zero exit code if regressions detected

### Manage Test Suites

```bash
# Create a template in user suites directory
agent-test-helper.sh create my-new-tests

# List all available suites (user + shipped)
agent-test-helper.sh list

# View recent results
agent-test-helper.sh results
agent-test-helper.sh results smoke-test  # Filter by name
```

## CLI and Output Parsing

The framework uses `opencode run --format json` for reliable response extraction. The JSON event stream format outputs one JSON object per line:

```json
{"type":"text","timestamp":...,"part":{"type":"text","text":"response content"}}
```

Text is extracted from events where `type == "text"` via `jq`. This avoids parsing ANSI escape codes from the default formatted output.

### Server Mode

When an OpenCode server is running (`opencode serve`), the framework uses the HTTP API instead:

1. Creates an isolated session via `POST /session`
2. Sends the prompt via `POST /session/:id/message` (sync)
3. Extracts text from response parts
4. Deletes the session for cleanup

Override server location with `OPENCODE_HOST` and `OPENCODE_PORT`.

## Shipped Test Suites

The repo includes ready-to-use test suites in `.agents/tests/`:

| Suite | Tests | Purpose |
|-------|-------|---------|
| `smoke-test` | 3 | Quick agent responsiveness and identity check |
| `agents-md-knowledge` | 5 | Core AGENTS.md instruction absorption |
| `git-workflow` | 4 | Git workflow knowledge validation |

Run them directly:

```bash
agent-test-helper.sh run smoke-test
agent-test-helper.sh run agents-md-knowledge
agent-test-helper.sh run git-workflow
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

Requires `opencode` CLI available in the CI environment with appropriate API credentials.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_TEST_CLI` | auto-detect | Force `opencode` |
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
