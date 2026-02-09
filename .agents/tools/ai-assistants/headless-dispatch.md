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
- Tasks requiring frequent human-in-the-loop decisions (see [Worker Uncertainty Framework](#worker-uncertainty-framework) for what workers can handle autonomously)
- Single quick questions (just use `opencode run` without server overhead)

**Draft agents for reusable context**: When parallel workers share domain-specific instructions, create a draft agent in `~/.aidevops/agents/draft/` instead of duplicating prompts. Subsequent dispatches can reference the draft. See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers" for details.

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

## Worker Uncertainty Framework

Headless workers have no human to ask when they encounter ambiguity. This framework defines when workers should make autonomous decisions vs flag uncertainty and exit.

### Decision Tree

```text
Encounter ambiguity
├── Can I infer intent from context + codebase conventions?
│   ├── YES → Proceed, document decision in commit message
│   └── NO ↓
├── Would getting this wrong cause irreversible damage?
│   ├── YES → Exit cleanly with specific explanation
│   └── NO ↓
├── Does this affect only my task scope?
│   ├── YES → Proceed with simplest valid approach
│   └── NO → Exit (cross-task architectural decisions need human input)
```

### Proceed Autonomously

Workers should make their own call and keep going when:

| Situation | Action |
|-----------|--------|
| Multiple valid approaches, all achieve the goal | Pick the simplest |
| Style/naming ambiguity | Follow existing codebase conventions |
| Slightly vague task description, clear intent | Interpret reasonably, document in commit |
| Choosing between equivalent patterns/libraries | Match project precedent |
| Minor adjacent issue discovered | Stay focused on assigned task, note in PR body |
| Unclear test coverage expectations | Match coverage level of neighboring files |

**Always document**: Include the decision rationale in the commit message so the supervisor and reviewers understand why.

```text
feat: add retry logic (chose exponential backoff over linear — matches existing patterns in src/utils/retry.ts)
```

### Flag Uncertainty and Exit

Workers should exit cleanly (allowing supervisor evaluation and retry) when:

| Situation | Why exit |
|-----------|----------|
| Task contradicts codebase state | May be stale or misdirected |
| Requires breaking public API changes | Cross-cutting impact needs human judgment |
| Task appears already done or obsolete | Avoid duplicate/conflicting work |
| Missing dependencies, credentials, or services | Cannot be inferred safely |
| Architectural decisions affecting other tasks | Supervisor coordinates cross-task concerns |
| Create vs modify ambiguity with data loss risk | Irreversible — needs confirmation |
| Multiple interpretations with very different outcomes | Wrong guess wastes compute and creates cleanup work |

**Always explain**: Include a specific, actionable description of the blocker so the supervisor can resolve it.

```text
BLOCKED: Task says 'update the auth endpoint' but there are 3 auth endpoints
(JWT in src/auth/jwt.ts, OAuth in src/auth/oauth.ts, API key in src/auth/apikey.ts).
Need clarification on which one(s) to update.
```

### Integration with Supervisor

The supervisor uses worker exit behavior to drive the self-improvement loop:

- **Worker proceeds + documents** → Supervisor reviews PR normally
- **Worker exits with BLOCKED** → Supervisor reads explanation, either clarifies and retries, or creates a prerequisite task
- **Worker exits with unclear error** → Supervisor dispatches a diagnostic worker (`-diag-N` suffix)

This framework reduces wasted retries by giving workers clear criteria for when to attempt vs when to bail. Over time, task descriptions improve because the supervisor learns which ambiguities cause exits.

## Worker Efficiency Protocol

Workers are injected with an efficiency protocol via the supervisor dispatch prompt. This protocol maximises output per token by requiring structured internal task management.

### Key Practices

1. **TodoWrite decomposition** — Workers must break their task into 3-7 subtasks using the TodoWrite tool at session start. This provides a progress breadcrumb trail that survives context compaction.

2. **Checkpoint after each subtask** — Workers call `session-checkpoint-helper.sh save` after completing each subtask. If the session restarts or compacts, the worker can resume from the last checkpoint instead of restarting from scratch.

3. **Parallel sub-work** — For independent subtasks (e.g., tests + docs), workers can use the Task tool to spawn sub-agents. This is faster than sequential execution when subtasks don't modify the same files.

4. **Fail fast** — Workers verify assumptions before writing code: read target files, check dependencies exist, confirm the task isn't already done. This prevents wasting an entire session on a false premise.

5. **Token minimisation** — Read file ranges (not entire files), write concise commit messages, and exit with BLOCKED after one failed retry instead of burning tokens on repeated attempts.

### Why This Matters

| Without protocol | With protocol |
|-----------------|---------------|
| Context compacts → worker restarts from zero | Checkpoint + TodoWrite → resume from last subtask |
| Complex task done linearly → 1 failure = full restart | Subtask tracking → only redo the failed subtask |
| No internal structure → steps skipped or repeated | Explicit subtask list → nothing missed |
| All work sequential → slower | Independent subtasks parallelised via Task tool |

### Token Cost

The protocol adds ~200-300 tokens per session (TodoWrite calls + checkpoint commands). A single avoided restart saves 10,000-50,000 tokens. The ROI is 30-150x on any task that would otherwise need a retry.

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

## Parallel vs Sequential

Use this decision guide to choose the right dispatch pattern.

### Use Parallel When

- **Tasks are independent** - code review, test generation, and docs don't depend on each other
- **Tasks read but don't write** - multiple reviewers analyzing the same codebase
- **You need speed** - 3 tasks at 2 min each = 2 min parallel vs 6 min sequential
- **Tasks have separate outputs** - each produces its own report/artifact

```bash
# Example: parallel review + tests + docs
opencode serve --port 4096 &
runner-helper.sh run code-reviewer "Review src/auth/" --attach http://localhost:4096 &
runner-helper.sh run test-generator "Generate tests for src/utils/" --attach http://localhost:4096 &
runner-helper.sh run doc-writer "Document the API endpoints" --attach http://localhost:4096 &
wait
```

### Use Sequential When

- **Tasks depend on each other** - "fix the bug" then "write tests for the fix"
- **Tasks modify the same files** - two agents editing the same file = merge conflicts
- **Output of one feeds the next** - analysis results inform implementation
- **You need human review between steps** - review plan before execution

```bash
# Example: sequential analyze → implement → test
runner-helper.sh run planner "Analyze the auth module and propose improvements"
# Review output, then:
runner-helper.sh run developer "Implement the improvements from the plan" --continue
# Then:
runner-helper.sh run tester "Write tests for the changes"
```

### Decision Table

| Scenario | Pattern | Why |
|----------|---------|-----|
| PR review (security + quality + style) | Parallel | Independent read-only analysis |
| Bug fix + tests | Sequential | Tests depend on the fix |
| Multi-page SEO audit | Parallel | Each page is independent |
| Refactor + update docs | Sequential | Docs depend on refactored code |
| Generate tests for 5 modules | Parallel | Each module is independent |
| Plan → implement → verify | Sequential | Each step depends on previous |
| Cron: daily report + weekly digest | Parallel | Independent scheduled tasks |
| Migration: schema → data → verify | Sequential | Each step depends on previous |

### Hybrid Pattern

For complex workflows, combine both:

```bash
# Phase 1: Parallel analysis
runner-helper.sh run security-reviewer "Audit src/" --attach :4096 &
runner-helper.sh run perf-analyzer "Profile src/" --attach :4096 &
wait

# Phase 2: Sequential implementation (based on analysis)
runner-helper.sh run developer "Fix the critical security issues found"
runner-helper.sh run developer "Optimize the performance bottlenecks found" --continue
```

## Example Runner Templates

Ready-to-use AGENTS.md templates for common runner types:

| Template | Description |
|----------|-------------|
| [code-reviewer](runners/code-reviewer.md) | Security and quality code review with structured output |
| [seo-analyst](runners/seo-analyst.md) | SEO analysis with issue/opportunity tables |

See [runners/README.md](runners/README.md) for how to create runners from templates.

## Related

- `tools/ai-assistants/opencode-server.md` - Full server API reference
- `tools/ai-assistants/overview.md` - AI assistant comparison
- `tools/ai-assistants/runners/` - Example runner templates
- `scripts/runner-helper.sh` - Runner management CLI
- `scripts/cron-dispatch.sh` - Cron-triggered dispatch
- `scripts/cron-helper.sh` - Cron job management
- `scripts/matrix-dispatch-helper.sh` - Matrix chat-triggered dispatch
- `services/communications/matrix-bot.md` - Matrix bot setup and configuration
- `scripts/coordinator-helper.sh` - Multi-agent coordination
- `scripts/mail-helper.sh` - Inter-agent mailbox
- `memory/README.md` - Memory system (supports namespaces)
