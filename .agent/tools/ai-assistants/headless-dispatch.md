---
description: Headless dispatch patterns for parallel AI agent execution via OpenCode
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Headless Dispatch

<!-- AI-CONTEXT-START -->

## Quick Reference

- **One-shot dispatch**: `opencode run "prompt"`
- **Warm server dispatch**: `opencode run --attach http://localhost:4096 "prompt"`
- **Server mode**: `opencode serve [--port 4096]`
- **SDK**: `npm install @opencode-ai/sdk`
- **Runner management**: `runner-helper.sh [create|run|status|list|stop|destroy]`
- **Runner directory**: `~/.aidevops/.agent-workspace/runners/`

**When to use headless dispatch**:

- Parallel tasks (code review + test gen + docs simultaneously)
- Scheduled/cron-triggered AI work
- CI/CD integration (PR review, code analysis)
- Chat-triggered dispatch (Matrix, Discord, Slack via OpenClaw)
- Background tasks that don't need interactive TUI

**When NOT to use**:

- Interactive development (use TUI directly)
- Tasks requiring human-in-the-loop decisions mid-execution
- Single quick questions (just use `opencode run` without server overhead)

<!-- AI-CONTEXT-END -->

## Architecture

```text
                    ┌─────────────────────────────────┐
                    │       OpenCode Server            │
                    │     (opencode serve :4096)       │
                    ├─────────────────────────────────┤
                    │  Sessions (isolated contexts)    │
                    │  ├── runner/code-reviewer        │
                    │  ├── runner/seo-analyst          │
                    │  └── runner/test-generator       │
                    └──────────┬──────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     opencode run        SDK client       cron-dispatch
     --attach :4096      (TypeScript)     (scheduled)
```

## Dispatch Methods

### Method 1: Direct CLI (`opencode run`)

Simplest approach. Each invocation starts a fresh session (or resumes one).

```bash
# One-shot task
opencode run "Review src/auth.ts for security issues"

# With specific model
opencode run -m anthropic/claude-sonnet-4-20250514 "Generate unit tests for src/utils/"

# With specific agent
opencode run --agent plan "Analyze the database schema"

# JSON output (for parsing)
opencode run --format json "List all exported functions in src/"

# Attach files for context
opencode run -f ./schema.sql -f ./migration.ts "Generate types from this schema"

# Set a session title
opencode run --title "Auth review" "Review the auth middleware"
```

### Method 2: Warm Server (`opencode serve` + `--attach`)

Avoids MCP server cold boot on every dispatch. Recommended for repeated tasks.

```bash
# Terminal 1: Start persistent server
opencode serve --port 4096

# Terminal 2+: Dispatch tasks against it
opencode run --attach http://localhost:4096 "Task 1"
opencode run --attach http://localhost:4096 --agent plan "Review task"
```

### Method 3: SDK (TypeScript)

Full programmatic control. Best for parallel orchestration.

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"

// Start server + client together
const { client, server } = await createOpencode({
  port: 4096,
  config: { model: "anthropic/claude-sonnet-4-20250514" },
})

// Or connect to existing server
const client = createOpencodeClient({
  baseUrl: "http://localhost:4096",
})
```

### Method 4: HTTP API (curl)

Direct API calls for shell scripts and non-JS integrations.

```bash
SERVER="http://localhost:4096"

# Create session
SESSION_ID=$(curl -sf -X POST "$SERVER/session" \
  -H "Content-Type: application/json" \
  -d '{"title": "API task"}' | jq -r '.id')

# Send prompt (sync - waits for response)
curl -sf -X POST "$SERVER/session/$SESSION_ID/message" \
  -H "Content-Type: application/json" \
  -d '{
    "model": {"providerID": "anthropic", "modelID": "claude-sonnet-4-20250514"},
    "parts": [{"type": "text", "text": "Explain this codebase"}]
  }'

# Send prompt (async - returns 204 immediately)
curl -sf -X POST "$SERVER/session/$SESSION_ID/prompt_async" \
  -H "Content-Type: application/json" \
  -d '{"parts": [{"type": "text", "text": "Run tests in background"}]}'

# Monitor via SSE
curl -N "$SERVER/event"
```

## Session Management

### Resuming Sessions

```bash
# Continue last session
opencode run -c "Continue where we left off"

# Resume specific session by ID
opencode run -s ses_abc123 "Add error handling to the auth module"
```

### Forking Sessions

Create a branch from an existing conversation:

```bash
# Via HTTP API
curl -sf -X POST "http://localhost:4096/session/$SESSION_ID/fork" \
  -H "Content-Type: application/json" \
  -d '{"messageID": "msg-123"}'
```

```typescript
// Via SDK - create child session
const child = await client.session.create({
  body: { parentID: parentSession.id, title: "Subtask" },
})
```

### Context Injection (No Reply)

Inject context without triggering an AI response:

```typescript
await client.session.prompt({
  path: { id: sessionId },
  body: {
    noReply: true,
    parts: [{
      type: "text",
      text: "Context: This project uses Express.js with TypeScript.",
    }],
  },
})
```

## Parallel Execution

### CLI Parallel (Background Jobs)

```bash
# Start server once
opencode serve --port 4096 &

# Dispatch parallel tasks
opencode run --attach http://localhost:4096 --title "Review" \
  "Review src/auth/ for security issues" &
opencode run --attach http://localhost:4096 --title "Tests" \
  "Generate unit tests for src/utils/" &
opencode run --attach http://localhost:4096 --title "Docs" \
  "Generate API documentation for src/api/" &

wait  # Wait for all to complete
```

### SDK Parallel (Promise.all)

```typescript
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

// Create parallel sessions
const [review, tests, docs] = await Promise.all([
  client.session.create({ body: { title: "Code Review" } }),
  client.session.create({ body: { title: "Test Generation" } }),
  client.session.create({ body: { title: "Documentation" } }),
])

// Dispatch tasks concurrently
await Promise.all([
  client.session.promptAsync({
    path: { id: review.data.id },
    body: { parts: [{ type: "text", text: "Review src/auth.ts" }] },
  }),
  client.session.promptAsync({
    path: { id: tests.data.id },
    body: { parts: [{ type: "text", text: "Generate tests for src/utils/" }] },
  }),
  client.session.promptAsync({
    path: { id: docs.data.id },
    body: { parts: [{ type: "text", text: "Generate API docs for src/api/" }] },
  }),
])

// Monitor via SSE
const events = await client.event.subscribe()
for await (const event of events.stream) {
  if (event.type === "session.status") {
    console.log(`Session ${event.properties.id}: ${event.properties.status}`)
  }
}
```

## Runners

Runners are named, persistent agent instances with their own identity, instructions, and optionally isolated memory. Managed by `runner-helper.sh`.

### Directory Structure

```text
~/.aidevops/.agent-workspace/runners/
├── code-reviewer/
│   ├── AGENTS.md      # Runner personality/instructions
│   ├── config.json    # Runner configuration
│   └── memory.db      # Runner-specific memories (optional)
└── seo-analyst/
    ├── AGENTS.md
    ├── config.json
    └── memory.db
```

### Runner Lifecycle

```bash
# Create a runner
runner-helper.sh create code-reviewer \
  --description "Reviews code for security and quality" \
  --model anthropic/claude-sonnet-4-20250514

# Run a task
runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"

# Run against warm server (faster)
runner-helper.sh run code-reviewer "Review src/auth/" --attach http://localhost:4096

# Check status
runner-helper.sh status code-reviewer

# List all runners
runner-helper.sh list

# Destroy a runner
runner-helper.sh destroy code-reviewer
```

### Custom Runner Instructions

Each runner gets its own `AGENTS.md` that defines its personality:

```markdown
# Code Reviewer

You are a senior code reviewer focused on security and maintainability.

## Rules

- Flag any use of eval(), innerHTML, or raw SQL
- Check for proper input validation
- Verify error handling covers edge cases
- Note missing tests for critical paths

## Output Format

For each file reviewed, output:
1. Severity (critical/warning/info)
2. Line reference (file:line)
3. Issue description
4. Suggested fix
```

### Integration with Memory

Runners can use isolated or shared memory:

```bash
# Store a memory for a specific runner
memory-helper.sh store \
  --content "WORKING_SOLUTION: Use parameterized queries for SQL" \
  --tags "security,sql" \
  --namespace "code-reviewer"

# Recall from runner namespace
memory-helper.sh recall \
  --query "SQL injection" \
  --namespace "code-reviewer"
```

### Integration with Mailbox

Runners communicate via the existing mailbox system:

```bash
# Coordinator dispatches to runner
mail-helper.sh send \
  --to "code-reviewer" \
  --type "task_dispatch" \
  --payload "Review PR #123 for security issues"

# Runner reports back
mail-helper.sh send \
  --to "coordinator" \
  --type "status_report" \
  --from "code-reviewer" \
  --payload "Review complete. 2 critical, 5 warnings found."
```

## Custom Agents for Dispatch

OpenCode supports custom agents via markdown files or JSON config. These complement runners by defining tool access and permissions.

### Markdown Agent (Project-Level)

Place in `.opencode/agents/security-reviewer.md`:

```markdown
---
description: Security-focused code reviewer
mode: subagent
model: anthropic/claude-sonnet-4-20250514
temperature: 0.1
tools:
  write: false
  edit: false
  bash: false
permission:
  bash:
    "git diff*": allow
    "git log*": allow
    "grep *": allow
    "*": deny
---

You are a security expert. Identify vulnerabilities, check for OWASP Top 10
issues, and verify proper input validation and output encoding.
```

### JSON Agent (Global Config)

In `opencode.json`:

```json
{
  "agent": {
    "security-reviewer": {
      "description": "Security-focused code reviewer",
      "mode": "subagent",
      "model": "anthropic/claude-sonnet-4-20250514",
      "tools": { "write": false, "edit": false }
    }
  }
}
```

### Using Custom Agents

```bash
# CLI
opencode run --agent security-reviewer "Audit the auth module"

# SDK
const result = await client.session.prompt({
  path: { id: session.id },
  body: {
    agent: "security-reviewer",
    parts: [{ type: "text", text: "Audit the auth module" }],
  },
})
```

## Model Provider Flexibility

OpenCode supports any provider via `opencode auth login`. Runners inherit the configured provider or override per-runner.

```bash
# Configure providers
opencode auth login  # Interactive provider selection

# Override model per dispatch
opencode run -m openrouter/anthropic/claude-sonnet-4-20250514 "Task"
opencode run -m groq/llama-4-scout-17b-16e-instruct "Quick task"
```

Environment variables for non-interactive setup:

```bash
# Provider credentials (stored in ~/.local/share/opencode/auth.json)
opencode auth login

# Or set via environment
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
```

## Security

1. **Network**: Use `--hostname 127.0.0.1` (default) for local-only access
2. **Auth**: Set `OPENCODE_SERVER_PASSWORD` when exposing to network
3. **Permissions**: Use `OPENCODE_PERMISSION` env var for headless autonomy
4. **Credentials**: Never pass secrets in prompts - use environment variables
5. **Cleanup**: Delete sessions after use to prevent data leakage

### Autonomous Mode (CI/CD)

```bash
# Grant all permissions (only in trusted environments)
OPENCODE_PERMISSION='{"*":"allow"}' opencode run "Fix the failing tests"
```

## CI/CD Integration

### GitHub Actions

```yaml
name: AI Code Review
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install OpenCode
        run: curl -fsSL https://opencode.ai/install | bash

      - name: Run AI Review
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          OPENCODE_PERMISSION: '{"*":"allow"}'
        run: |
          opencode run --format json \
            "Review the changes in this PR for security and quality. Output as markdown." \
            > review.md
```

## Related

- `tools/ai-assistants/opencode-server.md` - Full server API reference
- `tools/ai-assistants/overview.md` - AI assistant comparison
- `scripts/runner-helper.sh` - Runner management CLI
- `scripts/cron-dispatch.sh` - Cron-triggered dispatch
- `scripts/cron-helper.sh` - Cron job management
- `scripts/coordinator-helper.sh` - Multi-agent coordination
- `scripts/mail-helper.sh` - Inter-agent mailbox
- `memory/README.md` - Memory system (supports namespaces)
