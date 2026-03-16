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

**Remote dispatch**: For dispatching to containers on remote hosts via SSH/Tailscale, see `tools/containers/remote-dispatch.md`. Set `dispatch_target` on a task to route it to a remote host with credential forwarding and log collection.

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
opencode run -m anthropic/claude-sonnet-4-6 "Generate unit tests for src/utils/"

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
  config: { model: "anthropic/claude-sonnet-4-6" },
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
    "model": {"providerID": "anthropic", "modelID": "claude-sonnet-4-6"},
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

### Stagger Protection for Manual Dispatch (t1419)

When dispatching multiple workers manually (outside the pulse supervisor), **stagger launches by 30-60 seconds** to avoid thundering herd resource contention. Simultaneous cold boots cause:

- **RAM exhaustion**: Each worker spawns Node.js + language servers + MCP servers. 6 simultaneous startups can consume 6+ GB in the first 60 seconds.
- **API rate limiting**: Multiple workers hitting the same API provider simultaneously trigger rate limits, causing buffering and eventual stalls.
- **MCP cold boot storms**: MCP servers (especially Node-based ones) have expensive startup. Concurrent initialization competes for CPU and I/O.

```bash
HELPER="$(aidevops config get paths.agents_dir)/scripts/headless-runtime-helper.sh"

# WRONG: Thundering herd — all 4 workers cold-boot simultaneously
for issue in 42 43 44 45; do
  $HELPER run --role worker --session-key "issue-${issue}" \
    --dir ~/Git/myproject --title "Issue #${issue}" \
    --prompt "/full-loop Implement issue #${issue}" &
done

# RIGHT: Staggered launch — 30s between each worker
for issue in 42 43 44 45; do
  $HELPER run --role worker --session-key "issue-${issue}" \
    --dir ~/Git/myproject --title "Issue #${issue}" \
    --prompt "/full-loop Implement issue #${issue}" &
  sleep 30
done
```

> **Never use bare `opencode run` for dispatch** — it skips lifecycle reinforcement, causing workers to stop after PR creation (GH#5096). Always use `headless-runtime-helper.sh run`.

The pulse supervisor handles this automatically via its capacity calculation (`RAM_PER_WORKER_MB`, `RAM_RESERVE_MB`, `MAX_WORKERS_CAP`). Manual dispatch bypasses these checks.

**Worker monitoring**: Use `worker-watchdog.sh --status` to check active workers, or install the launchd service (`worker-watchdog.sh --install`) for automatic detection and cleanup of hung/idle workers. Stall checks now inspect the recent OpenCode transcript tail before killing a suspect worker, log that diagnostic summary, and give provider-wait evidence one extra grace window before re-queueing the issue. See `scripts/worker-watchdog.sh` for details.

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
  --model anthropic/claude-sonnet-4-6

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
model: anthropic/claude-sonnet-4-6
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
      "model": "anthropic/claude-sonnet-4-6",
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
opencode run -m openrouter/anthropic/claude-sonnet-4-6 "Task"
opencode run -m groq/llama-4-scout-17b-16e-instruct "Quick task"
```

### OAuth-Aware Dispatch Routing (t1163)

When `SUPERVISOR_PREFER_OAUTH=true` (default), the supervisor automatically detects if the Claude CLI has OAuth authentication (subscription/Max plan) and routes Anthropic model requests through it. This is zero marginal cost for Anthropic models.

**Routing logic:**

- Anthropic models + Claude OAuth available → `claude` CLI (subscription billing)
- Anthropic models + no OAuth → `opencode` CLI (token billing)
- Non-Anthropic models → `opencode` CLI (multi-provider support)

**Configuration:**

```bash
# Enable/disable OAuth preference (default: true)
export SUPERVISOR_PREFER_OAUTH=true

# Force a specific CLI (overrides OAuth routing)
export SUPERVISOR_CLI=opencode

# Configure claude-oauth as subscription provider in budget tracker
budget-tracker-helper.sh configure claude-oauth --billing-type subscription
budget-tracker-helper.sh configure-period claude-oauth \
  --start 2026-02-01 --end 2026-03-01 --allowance 500 --unit usd
```

**Detection:** The supervisor checks for OAuth by looking for Claude CLI credentials in `~/.claude/`. Results are cached for 5 minutes.

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
6. **Scoped tokens** (t1412.2): Workers get minimal-permission GitHub tokens scoped to the target repo
7. **Worker sandbox** (t1412.1): Headless workers run with an isolated HOME directory
8. **Network tiering** (t1412.3): Worker network access is classified into 5 tiers. Tier 5 domains (exfiltration indicators like `requestbin.com`, `ngrok.io`, raw IPs) are denied. Tier 4 (unknown) domains are allowed but flagged for post-session review. Use `sandbox-exec-helper.sh run --network-tiering --worker-id <id>` to enable. Config: `configs/network-tiers.conf`, user overrides: `~/.config/aidevops/network-tiers-custom.conf`. See `scripts/network-tier-helper.sh` for the full API.

### Scoped Worker Tokens (t1412.2)

Headless workers receive scoped, short-lived GitHub tokens instead of the user's full-permission token. This limits blast radius if a worker is compromised via prompt injection.

**How it works:**

```text
Dispatch starts
  │
  ├── Resolve repo slug from workdir git remote
  │
  ├── worker-token-helper.sh create --repo owner/repo --ttl 3600
  │   ├── Strategy 1: GitHub App installation token (enforced by GitHub)
  │   └── Strategy 2: Delegated token (advisory scoping)
  │
  ├── Pass token to worker via GH_TOKEN env var
  │
  ├── Worker executes (can only access target repo)
  │
  └── worker-token-helper.sh revoke --token-file <path>
```

**Token permissions** (minimal set for PR workflow):

- `contents:write` — push branches, read/write files
- `pull_requests:write` — create/update PRs
- `issues:write` — comment on issues, update labels

**Token strategies** (tried in priority order):

| Strategy | Scoping | TTL | Setup required |
|----------|---------|-----|----------------|
| GitHub App installation token | Enforced by GitHub (repo-scoped) | 1h (GitHub enforced) | One-time App install |
| Delegated token | Advisory (tracked locally) | Configurable (default 1h) | None (zero-config) |

**Setup for GitHub App** (recommended for enforced scoping):

1. Create a GitHub App at `https://github.com/settings/apps/new`
   - Permissions: Contents (R&W), Pull requests (R&W), Issues (R&W)
   - No webhook URL needed
2. Install the App on your account/org
3. Generate and download a private key
4. Configure:

```bash
cat > ~/.config/aidevops/github-app.json << 'EOF'
{
  "app_id": "YOUR_APP_ID",
  "private_key_path": "~/.config/aidevops/github-app-key.pem",
  "installation_id": "YOUR_INSTALLATION_ID"
}
EOF
chmod 600 ~/.config/aidevops/github-app.json
chmod 600 ~/.config/aidevops/github-app-key.pem
```

**Disable scoped tokens** (not recommended):

```bash
export WORKER_SCOPED_TOKENS=false
```

**CLI usage:**

```bash
# Check token configuration
worker-token-helper.sh status

# Manually create a scoped token
TOKEN_FILE=$(worker-token-helper.sh create --repo owner/repo --ttl 3600)

# Validate a token
worker-token-helper.sh validate --token-file "$TOKEN_FILE"

# Clean up expired tokens
worker-token-helper.sh cleanup
```

### Worker Sandbox (t1412.1)

Headless workers dispatched by the supervisor run with a **fake HOME directory** that contains only the minimal configuration needed for their task. This limits blast radius if a worker is compromised via prompt injection.

**What workers get:**

- `.gitconfig` — user name/email for commits (no credential helpers)
- `GH_TOKEN` — GitHub API access via environment variable (not filesystem)
- `.aidevops/` — symlink to agent prompts (read-only)
- OpenCode/Claude config — MCP server definitions only (no auth tokens)
- Writable XDG dirs — for tool state (npm cache, etc.)

**What workers cannot access:**

- `~/.ssh/` — no SSH key access
- gopass / pass stores — no password manager access
- `~/.config/aidevops/credentials.sh` — no plaintext credentials
- Cloud provider tokens (AWS, GCP, Azure)
- npm/pypi publish tokens
- Browser profiles or cookies

**Configuration:**

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKER_SANDBOX_ENABLED` | `true` | Set to `false` to disable sandboxing |
| `WORKER_SANDBOX_BASE` | `/tmp/aidevops-worker` | Base path for sandbox directories |

**Interactive sessions are never sandboxed** — the human in the loop is the enforcement layer.

**Sandbox lifecycle:**

1. Created by `worker-sandbox-helper.sh create <task_id>` before dispatch
2. Environment variables injected into the worker's dispatch script
3. Automatically cleaned up by the wrapper script after the worker exits
4. Stale sandboxes (>24h) cleaned by `worker-sandbox-helper.sh cleanup-stale`

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

## Lineage Context for Subtask Workers

When dispatching a worker for a task that has parent or sibling tasks (e.g., `t1408.3` under `t1408`), include a **lineage context block** in the dispatch prompt. This prevents scope drift and duplicate work across parallel workers.

### When to Include Lineage Context

Include lineage context when ALL of these are true:

- The task ID contains a dot (e.g., `t1408.3`) — indicating it's a subtask
- The parent task and/or sibling tasks exist in TODO.md or the issue body
- Multiple sibling tasks may be dispatched in parallel

Skip lineage context for top-level tasks (e.g., `t1408`) or tasks with no siblings.

### Lineage Block Format

Insert the lineage block between the task description and any other dispatch context (mission context, etc.):

```text
TASK LINEAGE:
  0. [parent] Build a CRM with contacts, deals, and email (t1408)
    1. Implement contact management module (t1408.1)
    2. Implement deal pipeline module (t1408.2)  <-- THIS TASK
    3. Implement email integration module (t1408.3)

LINEAGE RULES:
- You are one of several agents working in parallel on sibling tasks under the same parent.
- Focus ONLY on your specific task (marked with "<-- THIS TASK").
- Do NOT duplicate work that sibling tasks would handle.
- If your task depends on interfaces, types, or APIs from sibling tasks, define reasonable stubs
  and document them in the PR body so the sibling worker can replace them.
- If you discover your task is blocked by a sibling task that hasn't been completed yet,
  exit with BLOCKED and specify which sibling task you need.
```

### Assembling Lineage Context

The dispatcher (pulse or interactive session) assembles lineage from TODO.md:

```bash
# Given a subtask ID like t1408.3, extract lineage from TODO.md
TASK_ID="t1408.3"
PARENT_ID="${TASK_ID%.*}"  # t1408

# Get parent task description
PARENT_DESC=$(grep -E "^- \[.\] ${PARENT_ID} " TODO.md | head -1 \
  | sed -E 's/^- \[.\] [^ ]+ //' | sed -E 's/ #[^ ]+//g' | cut -c1-120)

# Get all sibling tasks (indented under parent)
SIBLINGS=$(grep -E "^  - \[.\] ${PARENT_ID}\.[0-9]+" TODO.md \
  | sed -E 's/^  - \[.\] ([^ ]+) (.*)/\1: \2/' | sed -E 's/ #[^ ]+//g' | cut -c1-120)

# Format lineage block
LINEAGE_BLOCK="TASK LINEAGE:
  0. [parent] ${PARENT_DESC} (${PARENT_ID})"

INDEX=1
while IFS= read -r sibling; do
  SIB_ID=$(echo "$sibling" | cut -d: -f1)
  SIB_DESC=$(echo "$sibling" | cut -d: -f2- | sed 's/^ //')
  if [[ "$SIB_ID" == "$TASK_ID" ]]; then
    LINEAGE_BLOCK+="
    ${INDEX}. ${SIB_DESC} (${SIB_ID})  <-- THIS TASK"
  else
    LINEAGE_BLOCK+="
    ${INDEX}. ${SIB_DESC} (${SIB_ID})"
  fi
  INDEX=$((INDEX + 1))
done <<< "$SIBLINGS"

LINEAGE_BLOCK+="

LINEAGE RULES:
- You are one of several agents working in parallel on sibling tasks under the same parent.
- Focus ONLY on your specific task (marked with \"<-- THIS TASK\").
- Do NOT duplicate work that sibling tasks would handle.
- If your task depends on interfaces, types, or APIs from sibling tasks, define reasonable stubs.
- If blocked by a sibling task, exit with BLOCKED and specify which sibling."
```

### Dispatch Prompt Template with Lineage

> **IMPORTANT:** Always use `headless-runtime-helper.sh run` for dispatch — never bare `opencode run`. Bare dispatch skips lifecycle reinforcement, causing workers to stop after PR creation (GH#5096).

```bash
HELPER="$(aidevops config get paths.agents_dir)/scripts/headless-runtime-helper.sh"

# Standard dispatch (no lineage — top-level task)
$HELPER run \
  --role worker \
  --session-key "issue-<number>" \
  --dir <path> \
  --title "Issue #<number>: <title>" \
  --prompt "/full-loop Implement issue #<number> (<url>) -- <brief description>" &
sleep 2

# Subtask dispatch (with lineage context)
$HELPER run \
  --role worker \
  --session-key "issue-<number>" \
  --dir <path> \
  --title "Issue #<number>: <title>" \
  --prompt "/full-loop Implement issue #<number> (<url>) -- <brief description>

${LINEAGE_BLOCK}" &
sleep 2
```

### Worker Behavior with Lineage Context

Workers that receive lineage context should:

1. **Read the lineage block** at session start to understand their scope boundaries
2. **Check sibling task descriptions** before implementing — if a function or module is described in a sibling task, don't implement it
3. **Create stub interfaces** for cross-sibling dependencies (e.g., if task 2 needs a type defined by task 1, create a minimal stub type and note it in the PR)
4. **Reference lineage in PR body** — include a "Lineage" section listing parent and sibling tasks so reviewers understand the decomposition
5. **Exit with BLOCKED** if a hard dependency on a sibling task prevents progress (don't work around it with hacks)

### Integration with task-decompose-helper.sh

Use the manual TODO.md assembly shown above to build lineage blocks. The
`task-decompose-helper.sh` helper (t1408.1) does not yet accept a task-id
argument or emit the `TASK LINEAGE:` block format required by workers. Once
the helper supports task-id lookup and produces the same block shape, it will
be documented here as the preferred path.

## Pre-Dispatch Task Decomposition (t1408.2)

Before dispatching a worker, the pipeline classifies tasks as **atomic** (execute directly) or **composite** (split into subtasks). This catches "task too big for one worker" failures that previously required human judgment.

### How It Works

```text
Task description
  │
  ▼
classify(task, lineage)
  ├── atomic → dispatch worker directly (unchanged)
  │
  └── composite → decompose(task, lineage)
                    │
                    ▼
                  [2-5 subtasks with dependency edges]
                    │
                    ├── Interactive: show tree, ask confirmation
                    │   └── create child TODOs + briefs → dispatch leaves
                    │
                    └── Pulse: auto-proceed (depth limit: 3)
                        └── create child TODOs + briefs → dispatch leaves
```

### Integration Points

| Entry point | Mode | Behaviour |
|-------------|------|-----------|
| `/full-loop` (Step 0.45) | Interactive | Show decomposition tree, ask Y/n/edit |
| `/full-loop` (headless) | Headless | Auto-decompose, exit with DECOMPOSED message |
| `/pulse` (Step 3) | Headless | Auto-classify before dispatch, create children |
| `/new-task` (Step 5.5) | Interactive | Classify at creation, offer decomposition |
| `/mission` (orchestrator) | Headless | Classify features before dispatch |

### Helper Script

`task-decompose-helper.sh` provides these subcommands (`format-lineage`, not `lineage`):

```bash
# Classify: atomic or composite? (~$0.001, haiku tier)
task-decompose-helper.sh classify "Build auth with login and OAuth" --depth 0
# → {"kind": "composite", "confidence": 0.9, "reasoning": "..."}

# Decompose: split into subtasks with dependency edges
task-decompose-helper.sh decompose "Build auth with login and OAuth" --max-subtasks 5
# → {"subtasks": [{"description": "...", "blocked_by": []}], "strategy": "..."}

# Format lineage: show ancestor/sibling context for a subtask
task-decompose-helper.sh format-lineage --parent "Build auth" \
  --children '[{"description": "login"}, {"description": "OAuth"}]' --current 1
# → formatted hierarchy with sibling tasks

# Check if task already has child subtasks in TODO.md
task-decompose-helper.sh has-subtasks t1408 --todo-file ./TODO.md
# → true|false
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DECOMPOSE_MAX_DEPTH` | `3` | Maximum decomposition depth (parent → child → grandchild) |
| `DECOMPOSE_MODEL` | `haiku` | LLM model tier for classify/decompose calls |
| `DECOMPOSE_ENABLED` | `true` | Enable/disable decomposition globally |

### Design Principles

- **"When in doubt, atomic."** Over-decomposition creates more overhead (more tasks, more PRs, more merge conflicts) than under-decomposition. A slightly-too-large task that one worker handles is better than 5 tiny tasks that need coordination.
- **Minimum subtasks.** Decompose into 2-5 subtasks, never pad. Each subtask must represent real, distinct work.
- **Reuse existing infrastructure.** Child tasks use `claim-task-id.sh` for IDs, `blocked-by:` for dependencies, standard briefs. No new state management — TODO.md is the database.
- **Skip already-decomposed tasks.** If a task already has subtasks in TODO.md, don't re-decompose.

## Worker Efficiency Protocol

Workers are injected with an efficiency protocol via the supervisor dispatch prompt. This protocol maximises output per token by requiring structured internal task management.

### Key Practices

1. **TodoWrite decomposition** — Workers must break their task into 3-7 subtasks using the TodoWrite tool at session start. The LAST subtask must always be "Push and create PR". This provides a progress breadcrumb trail that survives context compaction.

2. **Commit early, commit often** — After EACH implementation subtask, `git add -A && git commit` immediately. After the FIRST commit, `git push -u origin HEAD && gh pr create --draft`. This ensures work survives context exhaustion. The supervisor auto-promotes draft PRs to ready-for-review when the worker dies.

3. **ShellCheck gate before push** (t234) — Before every `git push`, if any committed `.sh` files changed, run `shellcheck -x -S warning` on them and fix violations before pushing. This catches CI failures 5-10 minutes earlier than waiting for the remote pipeline. If `shellcheck` is not installed, skip and note it in the PR body.

4. **Research offloading** — Spawn Task sub-agents for heavy codebase exploration (reading 500+ line files, understanding patterns across multiple files). Sub-agents get fresh context windows and return concise summaries, saving the parent worker's context for implementation.

5. **Parallel sub-work (MANDATORY for independent subtasks)** — Workers MUST use the Task tool to run independent operations concurrently, not serially. This is not optional — serial execution of independent work wastes time proportional to the number of subtasks.

   **When to parallelise** (use Task tool with multiple concurrent calls):
   - Reading/analyzing multiple independent files or directories
   - Running independent read-only quality checks (e.g., lint, typecheck, tests) — note: auto-fixing linters (e.g., `lint --fix`) are write operations and must be sequential if they modify the same files
   - Generating tests for separate modules that don't share state
   - Researching multiple parts of the codebase simultaneously
   - Creating independent documentation sections
   - Any two+ operations where neither depends on the other's output

   **When to stay sequential** (do NOT parallelise):
   - Operations that write to the same files, or where one task reads a file modified by another (avoids write-write, read-write, and write-read race conditions)
   - Steps where output of one feeds input of the next
   - Git operations (add → commit → push must be sequential)
   - Operations that depend on a shared resource (same DB table, same API endpoint)

   **How**: Call the Task tool multiple times in a single message. Each Task call spawns a sub-agent with a fresh context window. Sub-agents return concise results that the parent worker uses to continue.

   ```text
   # WRONG — serial execution of independent research
   Task("Read src/auth/ and summarise patterns")
   # wait for result
   Task("Read src/api/ and summarise patterns")
   # wait for result
   Task("Read src/utils/ and summarise patterns")

   # RIGHT — parallel execution of independent research
   Task("Read src/auth/ and summarise patterns")  ─┐
   Task("Read src/api/ and summarise patterns")   ─┤ all in one message
   Task("Read src/utils/ and summarise patterns") ─┘
   ```

   **Throughput impact**: 3 independent 2-minute tasks take 6 minutes serial vs 2 minutes parallel. Over a typical worker session with 4-6 parallelisable operations, this saves 30-60% of wall-clock time.

6. **Checkpoint after each subtask** — Workers call `session-checkpoint-helper.sh save` after completing each subtask. If the session restarts or compacts, the worker can resume from the last checkpoint instead of restarting from scratch.

7. **Fail fast** — Workers verify assumptions before writing code: read target files, check dependencies exist, confirm the task isn't already done. This prevents wasting an entire session on a false premise.

8. **Token minimisation** — Read file ranges (not entire files), write concise commit messages, and exit with BLOCKED after one failed retry instead of burning tokens on repeated attempts.

### Why This Matters

| Without protocol | With protocol |
|-----------------|---------------|
| Context exhaustion → uncommitted work lost | Incremental commits → work survives on branch |
| No PR until end → supervisor can't detect work | Draft PR after first commit → always detectable |
| Reading large files burns context → no room for implementation | Research offloaded to sub-agents → context preserved |
| Context compacts → worker restarts from zero | Checkpoint + TodoWrite → resume from last subtask |
| Complex task done linearly → 1 failure = full restart | Subtask tracking → only redo the failed subtask |
| No internal structure → steps skipped or repeated | Explicit subtask list → nothing missed |
| All work sequential → 3x slower for 3 independent tasks | Independent subtasks parallelised via Task tool (mandatory) |
| ShellCheck failures found in CI 5-10 min later | Pre-push gate catches violations instantly |

### Token Cost

The protocol adds ~300-500 tokens per session (TodoWrite + commit + push + draft PR). A single avoided context-exhaustion failure saves 10,000-50,000 tokens. The ROI is 20-100x on any task that would otherwise need a retry.

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
| Decomposed subtasks (same parent) | Batch strategy | Use `batch-strategy-helper.sh` |
| Cron: daily report + weekly digest | Parallel | Independent scheduled tasks |
| Migration: schema → data → verify | Sequential | Each step depends on previous |

### Batch Strategies for Decomposed Tasks (t1408.4)

When the task decomposition pipeline (t1408) splits a composite task into subtasks, use batch strategies to control dispatch order. This is a layer above parallel/sequential — it determines which groups of subtasks to dispatch together.

- **depth-first** (default): Finish one branch before starting the next. Use when subtask branches have implicit dependencies (e.g., "API module" should complete before "frontend module" starts).
- **breadth-first**: One subtask from each branch per batch. Use when all branches are truly independent and you want even progress.

```bash
# Get the next batch of subtasks to dispatch
NEXT=$(batch-strategy-helper.sh next-batch \
  --strategy depth-first \
  --tasks "$SUBTASKS_JSON" \
  --concurrency "$AVAILABLE_SLOTS")

# Dispatch each task in the batch
HELPER="$(aidevops config get paths.agents_dir)/scripts/headless-runtime-helper.sh"
echo "$NEXT" | jq -r '.[]' | while read -r task_id; do
  $HELPER run --role worker --session-key "task-${task_id}" \
    --dir <path> --title "$task_id" \
    --prompt "/full-loop Implement $task_id -- <description>" &
  sleep 2
done
```

The helper respects `blocked_by:` dependencies and never includes blocked tasks in a batch. See `scripts/batch-strategy-helper.sh help` for full usage.

### Hybrid Pattern

For complex workflows, combine both:

```bash
# Phase 1: Parallel analysis
runner-helper.sh run security-reviewer "Audit src/" --attach http://localhost:4096 &
runner-helper.sh run perf-analyzer "Profile src/" --attach http://localhost:4096 &
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
- Pulse supervisor (`scripts/commands/pulse.md`) - Multi-agent coordination (replaces archived `coordinator-helper.sh`)
- `scripts/mail-helper.sh` - Inter-agent mailbox
- `scripts/worker-token-helper.sh` - Scoped GitHub token lifecycle for workers (t1412.2)
- `scripts/network-tier-helper.sh` - Network domain tiering for worker sandboxing (t1412.3)
- `scripts/sandbox-exec-helper.sh` - Execution sandbox with network tiering integration
- `configs/network-tiers.conf` - Domain classification database
- `tools/security/prompt-injection-defender.md` - Prompt injection defense (includes network tiering section)
- `memory/README.md` - Memory system (supports namespaces)
