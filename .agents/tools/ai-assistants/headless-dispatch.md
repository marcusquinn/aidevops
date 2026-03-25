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

**When to use headless dispatch**: parallel tasks, scheduled/cron work, CI/CD integration, chat-triggered dispatch (Matrix, Discord, Slack via OpenClaw), background tasks.

**When NOT to use**: interactive development (use TUI), tasks requiring frequent human decisions, single quick questions.

**Draft agents for reusable context**: create in `~/.aidevops/agents/draft/` instead of duplicating prompts. See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers".

**Remote dispatch**: see `tools/containers/remote-dispatch.md` for SSH/Tailscale dispatch.

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

```bash
opencode run "Review src/auth.ts for security issues"
opencode run -m anthropic/claude-sonnet-4-6 "Generate unit tests for src/utils/"
opencode run --agent plan "Analyze the database schema"
opencode run --format json "List all exported functions in src/"
opencode run -f ./schema.sql -f ./migration.ts "Generate types from this schema"
opencode run --title "Auth review" "Review the auth middleware"
```

### Method 2: Warm Server (`opencode serve` + `--attach`)

Avoids MCP server cold boot on every dispatch. Recommended for repeated tasks.

```bash
opencode serve --port 4096  # Terminal 1: persistent server
opencode run --attach http://localhost:4096 "Task 1"  # Terminal 2+
```

### Method 3: SDK (TypeScript)

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"

const { client, server } = await createOpencode({
  port: 4096,
  config: { model: "anthropic/claude-sonnet-4-6" },
})

// Or connect to existing server
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })
```

### Method 4: HTTP API (curl)

```bash
SERVER="http://localhost:4096"
SESSION_ID=$(curl -sf -X POST "$SERVER/session" \
  -H "Content-Type: application/json" \
  -d '{"title": "API task"}' | jq -r '.id')

# Sync (waits for response)
curl -sf -X POST "$SERVER/session/$SESSION_ID/message" \
  -H "Content-Type: application/json" \
  -d '{"model": {"providerID": "anthropic", "modelID": "claude-sonnet-4-6"}, "parts": [{"type": "text", "text": "Explain this codebase"}]}'

# Async (returns 204 immediately)
curl -sf -X POST "$SERVER/session/$SESSION_ID/prompt_async" \
  -H "Content-Type: application/json" \
  -d '{"parts": [{"type": "text", "text": "Run tests in background"}]}'

curl -N "$SERVER/event"  # Monitor via SSE
```

## Session Management

```bash
opencode run -c "Continue where we left off"           # Resume last session
opencode run -s ses_abc123 "Add error handling"        # Resume by ID

# Fork via HTTP API
curl -sf -X POST "http://localhost:4096/session/$SESSION_ID/fork" \
  -H "Content-Type: application/json" -d '{"messageID": "msg-123"}'
```

## Parallel Execution

### CLI Parallel

```bash
opencode serve --port 4096 &
opencode run --attach http://localhost:4096 --title "Review" "Review src/auth/" &
opencode run --attach http://localhost:4096 --title "Tests" "Generate unit tests for src/utils/" &
opencode run --attach http://localhost:4096 --title "Docs" "Generate API documentation" &
wait
```

### Stagger Protection for Manual Dispatch (t1419)

When dispatching multiple workers manually, **stagger launches by 30-60 seconds** to avoid thundering herd resource contention (RAM exhaustion, API rate limiting, MCP cold boot storms).

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# RIGHT: Staggered launch
for issue in 42 43 44 45; do
  $HELPER run --role worker --session-key "issue-${issue}" \
    --dir ~/Git/myproject --title "Issue #${issue}" \
    --prompt "/full-loop Implement issue #${issue}" &
  sleep 30
done
```

> **Never use bare `opencode run` for dispatch** — it skips lifecycle reinforcement, causing workers to stop after PR creation (GH#5096). Always use `headless-runtime-helper.sh run`.

The pulse supervisor handles staggering automatically. **Worker monitoring**: `worker-watchdog.sh --status` or install the launchd service (`worker-watchdog.sh --install`).

### SDK Parallel

```typescript
const [review, tests, docs] = await Promise.all([
  client.session.create({ body: { title: "Code Review" } }),
  client.session.create({ body: { title: "Test Generation" } }),
  client.session.create({ body: { title: "Documentation" } }),
])
await Promise.all([
  client.session.promptAsync({ path: { id: review.data.id }, body: { parts: [{ type: "text", text: "Review src/auth.ts" }] } }),
  client.session.promptAsync({ path: { id: tests.data.id }, body: { parts: [{ type: "text", text: "Generate tests for src/utils/" }] } }),
  client.session.promptAsync({ path: { id: docs.data.id }, body: { parts: [{ type: "text", text: "Generate API docs" }] } }),
])
```

## Runners

Named, persistent agent instances with their own identity and instructions. Managed by `runner-helper.sh`.

```bash
runner-helper.sh create code-reviewer --description "Reviews code for security and quality" --model anthropic/claude-sonnet-4-6
runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"
runner-helper.sh run code-reviewer "Review src/auth/" --attach http://localhost:4096
runner-helper.sh status code-reviewer
runner-helper.sh list
runner-helper.sh destroy code-reviewer
```

### Runner Directory Structure

```text
~/.aidevops/.agent-workspace/runners/
├── code-reviewer/
│   ├── AGENTS.md      # Runner personality/instructions
│   ├── config.json    # Runner configuration
│   └── memory.db      # Runner-specific memories (optional)
```

### Runner Memory and Mailbox

```bash
# Memory (namespaced)
memory-helper.sh store --content "WORKING_SOLUTION: Use parameterized queries" --tags "security,sql" --namespace "code-reviewer"
memory-helper.sh recall --query "SQL injection" --namespace "code-reviewer"

# Mailbox
mail-helper.sh send --to "code-reviewer" --type "task_dispatch" --payload "Review PR #123"
mail-helper.sh send --to "coordinator" --type "status_report" --from "code-reviewer" --payload "Review complete."
```

## Custom Agents for Dispatch

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
    "*": deny
---

You are a security expert. Identify vulnerabilities, check for OWASP Top 10 issues.
```

```bash
opencode run --agent security-reviewer "Audit the auth module"
```

## Model Provider Flexibility

```bash
opencode auth login  # Interactive provider selection
opencode run -m openrouter/anthropic/claude-sonnet-4-6 "Task"
opencode run -m groq/llama-4-scout-17b-16e-instruct "Quick task"
```

### OAuth-Aware Dispatch Routing (t1163)

When `SUPERVISOR_PREFER_OAUTH=true` (default), routes Anthropic model requests through Claude CLI (subscription billing) when OAuth is available.

- Anthropic models + Claude OAuth → `claude` CLI (subscription)
- Anthropic models + no OAuth → `opencode` CLI (token billing)
- Non-Anthropic models → `opencode` CLI

```bash
export SUPERVISOR_PREFER_OAUTH=true   # default
export SUPERVISOR_CLI=opencode        # force specific CLI
```

## Security

1. **Network**: Use `--hostname 127.0.0.1` (default) for local-only access
2. **Auth**: Set `OPENCODE_SERVER_PASSWORD` when exposing to network
3. **Permissions**: Use `OPENCODE_PERMISSION` env var for headless autonomy
4. **Credentials**: Never pass secrets in prompts — use environment variables
5. **Cleanup**: Delete sessions after use to prevent data leakage
6. **Scoped tokens** (t1412.2): Workers get minimal-permission GitHub tokens scoped to the target repo
7. **Worker sandbox** (t1412.1): Headless workers run with an isolated HOME directory
8. **Network tiering** (t1412.3): Tier 5 domains (exfiltration indicators) denied; Tier 4 (unknown) flagged. Use `sandbox-exec-helper.sh run --network-tiering`. Config: `configs/network-tiers.conf`.

### Scoped Worker Tokens (t1412.2)

Workers receive scoped, short-lived GitHub tokens. Minimal permissions: `contents:write`, `pull_requests:write`, `issues:write`.

| Strategy | Scoping | TTL | Setup |
|----------|---------|-----|-------|
| GitHub App installation token | Enforced by GitHub | 1h | One-time App install |
| Delegated token | Advisory (tracked locally) | Configurable (default 1h) | None |

```bash
worker-token-helper.sh status
TOKEN_FILE=$(worker-token-helper.sh create --repo owner/repo --ttl 3600)
worker-token-helper.sh cleanup
```

**Disable** (not recommended): `export WORKER_SCOPED_TOKENS=false`

### Worker Sandbox (t1412.1)

Workers get a fake HOME with minimal config. They cannot access `~/.ssh/`, gopass stores, `credentials.sh`, cloud tokens, or browser profiles.

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKER_SANDBOX_ENABLED` | `true` | Set to `false` to disable |
| `WORKER_SANDBOX_BASE` | `/tmp/aidevops-worker` | Base path for sandboxes |

Lifecycle: created by `worker-sandbox-helper.sh create <task_id>`, cleaned up after worker exits, stale (>24h) cleaned by `worker-sandbox-helper.sh cleanup-stale`.

## Worker Uncertainty Framework

Workers have no human to ask. Decision tree:

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
│   └── NO → Exit (cross-task decisions need human input)
```

**Proceed autonomously** when: multiple valid approaches exist (pick simplest), style/naming ambiguity (follow conventions), vague but clear intent (interpret reasonably), minor adjacent issues (note in PR, stay focused).

**Exit with BLOCKED** when: task contradicts codebase state, requires breaking public API, appears already done, missing dependencies/credentials, architectural decisions affecting other tasks, data loss risk.

Always document decisions in commit messages; always explain blockers specifically.

**Supervisor integration**: proceed + document → normal PR review; BLOCKED → supervisor clarifies or creates prerequisite; unclear error → diagnostic worker dispatched.

## Lineage Context for Subtask Workers

Include lineage context when dispatching subtasks (dot-notation IDs like `t1408.3`) with siblings.

### Lineage Block Format

```text
TASK LINEAGE:
  0. [parent] Build a CRM with contacts, deals, and email (t1408)
    1. Implement contact management module (t1408.1)
    2. Implement deal pipeline module (t1408.2)  <-- THIS TASK
    3. Implement email integration module (t1408.3)

LINEAGE RULES:
- Focus ONLY on your specific task (marked with "<-- THIS TASK").
- Do NOT duplicate work that sibling tasks would handle.
- Define stubs for cross-sibling dependencies and document in PR body.
- If blocked by a sibling task, exit with BLOCKED and specify which one.
```

### Dispatch Prompt Template

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

# Standard dispatch (top-level task)
$HELPER run --role worker --session-key "issue-<number>" --dir <path> \
  --title "Issue #<number>: <title>" \
  --prompt "/full-loop Implement issue #<number> (<url>) -- <brief description>" &
sleep 2

# Subtask dispatch (with lineage)
$HELPER run --role worker --session-key "issue-<number>" --dir <path> \
  --title "Issue #<number>: <title>" \
  --prompt "/full-loop Implement issue #<number> (<url>) -- <brief description>

${LINEAGE_BLOCK}" &
sleep 2
```

Workers with lineage context should: read the block at session start, check sibling descriptions before implementing, create stub interfaces for cross-sibling dependencies, reference lineage in PR body, exit with BLOCKED if hard-blocked by a sibling.

## Pre-Dispatch Task Decomposition (t1408.2)

Before dispatching, classify tasks as **atomic** (execute directly) or **composite** (split into subtasks).

```text
Task → classify() → atomic → dispatch directly
                 → composite → decompose() → [2-5 subtasks]
                                           → Interactive: show tree, confirm
                                           → Pulse: auto-proceed (depth limit: 3)
```

```bash
task-decompose-helper.sh classify "Build auth with login and OAuth" --depth 0
task-decompose-helper.sh decompose "Build auth with login and OAuth" --max-subtasks 5
task-decompose-helper.sh format-lineage --parent "Build auth" \
  --children '[{"description": "login"}, {"description": "OAuth"}]' --current 1
task-decompose-helper.sh has-subtasks t1408 --todo-file ./TODO.md
```

| Variable | Default | Description |
|----------|---------|-------------|
| `DECOMPOSE_MAX_DEPTH` | `3` | Maximum decomposition depth |
| `DECOMPOSE_MODEL` | `haiku` | LLM model tier |
| `DECOMPOSE_ENABLED` | `true` | Enable/disable globally |

**Principles**: "When in doubt, atomic." Decompose into 2-5 subtasks only. Reuse existing infrastructure. Skip already-decomposed tasks.

## Worker Efficiency Protocol

Workers are injected with this protocol via supervisor dispatch:

1. **TodoWrite decomposition** — Break task into 3-7 subtasks at session start. Last subtask: "Push and create PR".
2. **Commit early, commit often** — After each implementation subtask, `git add -A && git commit`. After first commit, `git push -u origin HEAD && gh pr create --draft`.
3. **ShellCheck gate before push** (t234) — Run `shellcheck -x -S warning` on changed `.sh` files before every push.
4. **Research offloading** — Spawn Task sub-agents for heavy codebase exploration (500+ line files, cross-file patterns).
5. **Parallel sub-work (MANDATORY)** — Use Task tool for independent operations concurrently. Parallelise: reading independent files, independent quality checks, generating tests for separate modules. Stay sequential: writes to same files, steps where output feeds next, git operations.
6. **Checkpoint after each subtask** — `session-checkpoint-helper.sh save` after each subtask.
7. **Fail fast** — Verify assumptions before writing code.
8. **Token minimisation** — Read file ranges, write concise commits, exit with BLOCKED after one failed retry.

| Without protocol | With protocol |
|-----------------|---------------|
| Context exhaustion → uncommitted work lost | Incremental commits → work survives |
| No PR until end → undetectable | Draft PR after first commit → always detectable |
| Large file reads burn context | Research offloaded to sub-agents |
| Compaction → restart from zero | Checkpoint + TodoWrite → resume from last subtask |
| All work sequential | Independent subtasks parallelised (mandatory) |

Protocol overhead: ~300-500 tokens/session. Avoided retry saves 10,000-50,000 tokens. ROI: 20-100x.

## CI/CD Integration

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
        run: opencode run --format json "Review the changes in this PR for security and quality." > review.md
```

## Parallel vs Sequential

**Use parallel when**: tasks are independent, tasks read but don't write, you need speed, tasks have separate outputs.

**Use sequential when**: tasks depend on each other, tasks modify the same files, output of one feeds the next, human review needed between steps.

| Scenario | Pattern |
|----------|---------|
| PR review (security + quality + style) | Parallel |
| Bug fix + tests | Sequential |
| Multi-page SEO audit | Parallel |
| Refactor + update docs | Sequential |
| Generate tests for 5 modules | Parallel |
| Plan → implement → verify | Sequential |
| Decomposed subtasks (same parent) | Batch strategy (`batch-strategy-helper.sh`) |
| Migration: schema → data → verify | Sequential |

### Batch Strategies for Decomposed Tasks (t1408.4)

- **depth-first** (default): Finish one branch before starting the next.
- **breadth-first**: One subtask from each branch per batch.

```bash
NEXT=$(batch-strategy-helper.sh next-batch --strategy depth-first --tasks "$SUBTASKS_JSON" --concurrency "$AVAILABLE_SLOTS")
echo "$NEXT" | jq -r '.[]' | while read -r task_id; do
  $HELPER run --role worker --session-key "task-${task_id}" \
    --dir <path> --title "$task_id" \
    --prompt "/full-loop Implement $task_id -- <description>" &
  sleep 2
done
```

## Example Runner Templates

| Template | Description |
|----------|-------------|
| [code-reviewer](runners/code-reviewer.md) | Security and quality code review |
| [seo-analyst](runners/seo-analyst.md) | SEO analysis with issue/opportunity tables |

See [runners/README.md](runners/README.md) for how to create runners from templates.

## Related

- `tools/ai-assistants/opencode-server.md` - Full server API reference
- `tools/ai-assistants/overview.md` - AI assistant comparison
- `scripts/runner-helper.sh` - Runner management CLI
- `scripts/cron-dispatch.sh` - Cron-triggered dispatch
- `scripts/worker-token-helper.sh` - Scoped GitHub token lifecycle (t1412.2)
- `scripts/network-tier-helper.sh` - Network domain tiering (t1412.3)
- `scripts/sandbox-exec-helper.sh` - Execution sandbox
- `scripts/commands/pulse.md` - Multi-agent coordination
- `scripts/mail-helper.sh` - Inter-agent mailbox
- `tools/security/prompt-injection-defender.md` - Prompt injection defense
