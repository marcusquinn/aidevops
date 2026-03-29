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

**When to use**: Validating agent changes before merging, regression testing after AGENTS.md/subagent edits, comparing behavior across models, smoke testing after framework updates.

<!-- AI-CONTEXT-END -->

## Architecture

`agent-test-helper.sh` loads test suites (JSON), sends prompts via OpenCode CLI (`opencode run --format json`) or OpenCode Server HTTP API (`opencode serve`), then validates responses through the validation engine (`expect_contains`, `expect_not_contains`, `expect_regex`, `expect_not_regex`, `min/max_length`).

Server mode: creates isolated session via `POST /session`, sends prompt via `POST /session/:id/message`, extracts text, deletes session. Override with `OPENCODE_HOST`/`OPENCODE_PORT`.

## Test Suite Format

```json
{
  "name": "build-agent-tests",
  "description": "Validates build-agent subagent knowledge",
  "agent": "Build+",
  "model": "anthropic/claude-sonnet-4-6",
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
      "id": "slow-deep-analysis",
      "prompt": "Generate a comprehensive analysis...",
      "agent": "Plan+",
      "model": "anthropic/claude-opus-4-20250514",
      "timeout": 300,
      "expect_contains": ["analysis"],
      "expect_regex": "read.*when.*needed",
      "min_length": 100
    }
  ]
}
```

Per-test fields (`agent`, `model`, `timeout`) override suite-level defaults.

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

## Commands

### Run a Test Suite

```bash
agent-test-helper.sh run path/to/suite.json    # By file path
agent-test-helper.sh run smoke-test             # By name (searches suites/ and .agents/tests/)
agent-test-helper.sh run agents-md-knowledge    # Shipped suite
```

### Quick Single-Prompt Test

```bash
agent-test-helper.sh run-one "What is your primary purpose?"
agent-test-helper.sh run-one "List your tools" --expect "bash"
agent-test-helper.sh run-one "Explain git workflow" --agent "Build+" --model "anthropic/claude-sonnet-4-6" --timeout 60
```

### Before/After Comparison

```bash
agent-test-helper.sh baseline smoke-test   # 1. Save current behavior
# 2. Make agent changes (edit AGENTS.md, subagents, etc.)
agent-test-helper.sh compare smoke-test    # 3. Compare — reports regressions (non-zero exit on failure)
```

### Manage Test Suites

```bash
agent-test-helper.sh create my-new-tests   # Create template in user suites dir
agent-test-helper.sh list                   # List all available suites (user + shipped)
agent-test-helper.sh results                # View recent results
agent-test-helper.sh results smoke-test     # Filter by name
```

## Shipped Test Suites

| Suite | Tests | Purpose |
|-------|-------|---------|
| `smoke-test` | 3 | Quick agent responsiveness and identity check |
| `agents-md-knowledge` | 5 | Core AGENTS.md instruction absorption |
| `git-workflow` | 4 | Git workflow knowledge validation |

## CI/CD Integration

```bash
agent-test-helper.sh run agents-md-knowledge || { echo "Agent tests failed"; exit 1; }
```

Requires `opencode` CLI in CI with appropriate API credentials.

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
- AGENTS.md "Self-Improvement" section - Universal self-improvement principle (replaces archived `self-improve-helper.sh`)
