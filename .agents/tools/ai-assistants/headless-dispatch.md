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

- **One-shot**: `opencode run "prompt"` | **Warm server**: `opencode run --attach http://localhost:4096 "prompt"`
- **Server**: `opencode serve [--port 4096]` | **SDK**: `npm install @opencode-ai/sdk`
- **Runners**: `runner-helper.sh [create|run|status|list|stop|destroy]` → `~/.aidevops/.agent-workspace/runners/`

**Use for**: parallel tasks, scheduled/cron AI work, CI/CD, chat-triggered dispatch (Matrix/Discord/Slack via OpenClaw), background tasks.
**Don't use for**: interactive dev (use TUI), frequent human-in-the-loop (see [Worker Uncertainty](#worker-uncertainty-framework)), single quick questions.

**Draft agents**: Share domain instructions across workers via `~/.aidevops/agents/draft/`. See `tools/build-agent/build-agent.md`.
**Remote dispatch**: `tools/containers/remote-dispatch.md` (SSH/Tailscale with credential forwarding).

> **Never use bare `opencode run` for dispatch** — skips lifecycle reinforcement, workers stop after PR creation (GH#5096). Always use `headless-runtime-helper.sh run`.

<!-- AI-CONTEXT-END -->

## Dispatch Methods

### CLI (`opencode run`)

```bash
opencode run "Review src/auth.ts for security issues"
opencode run -m anthropic/claude-sonnet-4-6 "Generate unit tests for src/utils/"
opencode run --agent plan "Analyze the database schema"
opencode run --format json "List all exported functions in src/"
opencode run -f ./schema.sql -f ./migration.ts "Generate types from this schema"
opencode run -c "Continue where we left off"          # resume last session
opencode run -s ses_abc123 "Add error handling"        # resume by ID
```

### Warm Server (`opencode serve` + `--attach`)

Avoids MCP cold boot per dispatch. Start once, dispatch many:

```bash
opencode serve --port 4096                                          # Terminal 1
opencode run --attach http://localhost:4096 "Task 1"                # Terminal 2+
```

### SDK (TypeScript)

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"
const { client, server } = await createOpencode({
  port: 4096, config: { model: "anthropic/claude-sonnet-4-6" },
})
// Or connect to existing: createOpencodeClient({ baseUrl: "http://localhost:4096" })
```

### HTTP API

See `tools/ai-assistants/opencode-server.md` for full API reference. Key endpoints:

```bash
SERVER="http://localhost:4096"
SESSION_ID=$(curl -sf -X POST "$SERVER/session" \
  -H "Content-Type: application/json" -d '{"title": "task"}' | jq -r '.id')
curl -sf -X POST "$SERVER/session/$SESSION_ID/message" \
  -H "Content-Type: application/json" \
  -d '{"model":{"providerID":"anthropic","modelID":"claude-sonnet-4-6"},"parts":[{"type":"text","text":"prompt"}]}'
# Async: POST .../prompt_async (returns 204) | SSE: GET /event
# Fork: POST /session/$SESSION_ID/fork -d '{"messageID":"msg-123"}'
# No-reply context injection: set noReply:true in prompt body
```

## Parallel Execution

### Stagger Protection (t1419)

**Stagger manual launches by 30-60s** to avoid thundering herd (RAM exhaustion, API rate limiting, MCP cold boot storms).

```bash
AGENTS_DIR="$(aidevops config get paths.agents_dir)"
HELPER="${AGENTS_DIR/#\~/$HOME}/scripts/headless-runtime-helper.sh"

for issue in 42 43 44 45; do
  $HELPER run --role worker --session-key "issue-${issue}" \
    --dir ~/Git/myproject --title "Issue #${issue}" \
    --prompt "/full-loop Implement issue #${issue}" &
  sleep 30  # stagger — without this, all 4 cold-boot simultaneously
done
```

Pulse supervisor handles staggering automatically (`RAM_PER_WORKER_MB`, `RAM_RESERVE_MB`, `MAX_WORKERS_CAP`).

**Worker monitoring**: `worker-watchdog.sh --status` (active workers) | `--install` (launchd auto-detection of hung/idle workers with transcript-tail inspection before kill).

### SDK Parallel

Use `Promise.all` to create sessions and dispatch concurrently. Monitor via SSE (`client.event.subscribe()`). See SDK docs for full API.

## Runners

Named, persistent agent instances with own identity, instructions, and optionally isolated memory.

```text
~/.aidevops/.agent-workspace/runners/<name>/
├── AGENTS.md      # Runner personality/instructions
├── config.json    # Configuration
└── memory.db      # Runner-specific memories (optional)
```

```bash
runner-helper.sh create code-reviewer \
  --description "Reviews code for security and quality" --model anthropic/claude-sonnet-4-6
runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"
runner-helper.sh run code-reviewer "Review src/auth/" --attach http://localhost:4096
runner-helper.sh status code-reviewer | runner-helper.sh list | runner-helper.sh destroy code-reviewer
```

Each runner gets its own `AGENTS.md` defining personality, rules, and output format. Memory is namespaced (`memory-helper.sh store/recall --namespace "runner-name"`). Inter-runner communication via mailbox (`mail-helper.sh send --to/--from`).

## Custom Agents

OpenCode supports custom agents via markdown (`.opencode/agents/<name>.md`) or JSON (`opencode.json`). Agents define tool access, permissions, and model overrides:

```markdown
---
description: Security-focused code reviewer
mode: subagent
model: anthropic/claude-sonnet-4-6
temperature: 0.1
tools: { write: false, edit: false, bash: false }
permission:
  bash: { "git diff*": allow, "git log*": allow, "grep *": allow, "*": deny }
---
You are a security expert. Identify OWASP Top 10 issues, verify input validation and output encoding.
```

Usage: `opencode run --agent security-reviewer "Audit the auth module"`

## Model Provider Flexibility

```bash
opencode auth login                                           # interactive setup
opencode run -m openrouter/anthropic/claude-sonnet-4-6 "Task" # override per dispatch
```

### OAuth-Aware Dispatch Routing (t1163)

When `SUPERVISOR_PREFER_OAUTH=true` (default), Anthropic model requests route through Claude CLI if OAuth available (zero marginal cost). Non-Anthropic models always use `opencode` CLI. Override: `export SUPERVISOR_CLI=opencode`. Detection: checks `~/.claude/` credentials, cached 5 min.

Budget tracking: `budget-tracker-helper.sh configure claude-oauth --billing-type subscription`

## Security

1. **Network**: `--hostname 127.0.0.1` (default) | Set `OPENCODE_SERVER_PASSWORD` for network exposure
2. **Permissions**: `OPENCODE_PERMISSION` env var for headless autonomy (`'{"*":"allow"}'` for CI/CD)
3. **Credentials**: Never pass secrets in prompts — use environment variables. Delete sessions after use.
4. **Scoped tokens** (t1412.2): Workers get minimal-permission GitHub tokens scoped to target repo
5. **Worker sandbox** (t1412.1): Headless workers run with isolated HOME directory
6. **Network tiering** (t1412.3): 5-tier domain classification. Tier 5 (exfiltration) denied, Tier 4 (unknown) flagged. Config: `configs/network-tiers.conf`. See `scripts/network-tier-helper.sh`.

### Scoped Worker Tokens (t1412.2)

Workers receive scoped, short-lived GitHub tokens limiting blast radius from prompt injection.

**Flow**: Dispatch → `worker-token-helper.sh create --repo owner/repo --ttl 3600` → `GH_TOKEN` env var → worker executes → `worker-token-helper.sh revoke --token-file <path>`

**Permissions**: `contents:write`, `pull_requests:write`, `issues:write` (minimal PR workflow set).

| Strategy | Scoping | TTL | Setup |
|----------|---------|-----|-------|
| GitHub App installation token | Enforced by GitHub (repo-scoped) | 1h | One-time App install |
| Delegated token | Advisory (tracked locally) | Configurable (1h default) | None (zero-config) |

**GitHub App setup** (recommended): Create at `https://github.com/settings/apps/new` with Contents/PRs/Issues R&W permissions. Install on account/org, download private key, configure `~/.config/aidevops/github-app.json` (app_id, private_key_path, installation_id) with 600 permissions.

**CLI**: `worker-token-helper.sh status|create|validate|cleanup`. Disable: `export WORKER_SCOPED_TOKENS=false`.

### Worker Sandbox (t1412.1)

Headless workers run with a **fake HOME** containing only: `.gitconfig` (name/email), `GH_TOKEN` (env var), `.aidevops/` symlink (read-only), MCP config (defs only), writable XDG dirs. No access to `~/.ssh/`, gopass, `credentials.sh`, cloud tokens, publish tokens, or browser profiles.

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKER_SANDBOX_ENABLED` | `true` | Set `false` to disable |
| `WORKER_SANDBOX_BASE` | `/tmp/aidevops-worker` | Base path for sandbox dirs |

Interactive sessions are never sandboxed. Lifecycle: `worker-sandbox-helper.sh create <task_id>` → auto-clean on exit → stale (>24h) via `cleanup-stale`.

## Worker Uncertainty Framework

Defines when workers proceed autonomously vs exit with BLOCKED.

```text
Encounter ambiguity
├── Can infer from context + conventions? → proceed, document in commit
├── Wrong answer = irreversible damage? → exit with explanation
├── Affects only my task scope? → proceed with simplest approach
└── Cross-task architectural decision → exit (needs human input)
```

**Proceed autonomously**: multiple valid approaches (pick simplest), style ambiguity (follow conventions), vague but clear intent (document in commit), equivalent patterns (match precedent), minor adjacent issues (note in PR body), unclear coverage (match neighbors).

**Exit with BLOCKED**: task contradicts codebase, requires breaking public API, task appears done/obsolete, missing deps/credentials, architectural decisions affecting other tasks, create-vs-modify with data loss risk, multiple interpretations with very different outcomes.

Example: `BLOCKED: Task says 'update the auth endpoint' but there are 3 auth endpoints (JWT, OAuth, API key). Need clarification.`

**Supervisor integration**: Worker proceeds → normal PR review. Worker BLOCKED → supervisor clarifies/retries or creates prerequisite. Unclear error → diagnostic worker (`-diag-N`).

## Lineage Context for Subtask Workers (t1408)

When dispatching subtasks (dot-notation IDs like `t1408.3`), include a lineage block to prevent scope drift and duplicate work. Include when task ID has a dot AND siblings may run in parallel.

```text
TASK LINEAGE:
  0. [parent] Build a CRM with contacts, deals, and email (t1408)
    1. Implement contact management module (t1408.1)
    2. Implement deal pipeline module (t1408.2)  <-- THIS TASK
    3. Implement email integration module (t1408.3)

LINEAGE RULES:
- Focus ONLY on your task ("<-- THIS TASK"). Do NOT duplicate sibling work.
- For cross-sibling deps, define stubs and document in PR body.
- If blocked by sibling, exit BLOCKED specifying which.
```

**Assembling**: Extract parent/siblings from TODO.md using `PARENT_ID="${TASK_ID%.*}"`. `task-decompose-helper.sh format-lineage` does not yet support task-id lookup (t1408.1); use manual grep assembly until then.

**Dispatch**: Use `headless-runtime-helper.sh run` with `${LINEAGE_BLOCK}` appended to the `--prompt`. Workers read lineage at start, check sibling descriptions before implementing, create stub interfaces for cross-deps, reference lineage in PR body, exit BLOCKED on hard sibling dependencies.

## Pre-Dispatch Task Decomposition (t1408.2)

Tasks are classified as **atomic** (dispatch directly) or **composite** (split into 2-5 subtasks with dependency edges).

- **Interactive**: show decomposition tree, ask Y/n/edit → create child TODOs + briefs → dispatch leaves
- **Pulse**: auto-proceed (depth limit: 3) → create children → dispatch leaves
- **Integration points**: `/full-loop` (Step 0.45), `/pulse` (Step 3), `/new-task` (Step 5.5), `/mission`

```bash
task-decompose-helper.sh classify "Build auth with login and OAuth" --depth 0  # ~$0.001 haiku
task-decompose-helper.sh decompose "Build auth with login and OAuth" --max-subtasks 5
task-decompose-helper.sh format-lineage --parent "Build auth" \
  --children '[{"description": "login"}, {"description": "OAuth"}]' --current 1
task-decompose-helper.sh has-subtasks t1408 --todo-file ./TODO.md
```

Config: `DECOMPOSE_MAX_DEPTH=3`, `DECOMPOSE_MODEL=haiku`, `DECOMPOSE_ENABLED=true`.

**Principle**: "When in doubt, atomic" — over-decomposition creates more overhead than under-decomposition. Reuse `claim-task-id.sh`, `blocked-by:`, standard briefs. Skip already-decomposed tasks.

## Worker Efficiency Protocol

Injected via supervisor dispatch to maximise output per token (~300-500 token overhead, 20-100x ROI on avoided retries).

1. **TodoWrite decomposition** — 3-7 subtasks at session start. Last: "Push and create PR". Survives compaction.
2. **Commit early** — `git add -A && git commit` per subtask. After first: `git push -u origin HEAD && gh pr create --draft`. Supervisor auto-promotes draft PRs.
3. **ShellCheck gate** (t234) — Before push, if `.sh` changed: `shellcheck -x -S warning` and fix.
4. **Research offloading** — Task sub-agents for 500+ line files. Fresh context, concise summaries.
5. **Parallel sub-work (MANDATORY)** — Task tool for independent ops concurrently. Sequential for: same-file writes, dependent steps, git ops, shared resources.
6. **Checkpoint** — `session-checkpoint-helper.sh save` per subtask for resume on restart.
7. **Fail fast** — Verify assumptions before coding. Exit BLOCKED after one failed retry.
8. **Token minimisation** — Read file ranges, concise commits.

## Parallel vs Sequential

| Scenario | Pattern | Why |
|----------|---------|-----|
| PR review (security + quality + style) | Parallel | Independent read-only |
| Bug fix + tests | Sequential | Tests depend on fix |
| Multi-page SEO audit | Parallel | Each page independent |
| Refactor + update docs | Sequential | Docs depend on refactored code |
| Tests for 5 modules | Parallel | Each module independent |
| Plan → implement → verify | Sequential | Each step depends on previous |
| Decomposed subtasks | Batch | `batch-strategy-helper.sh` |

### Batch Strategies (t1408.4)

- **depth-first** (default): Finish one branch before next. Use when branches have implicit deps.
- **breadth-first**: One subtask per branch per batch. Use when truly independent.

`batch-strategy-helper.sh next-batch --strategy depth-first --tasks "$JSON" --concurrency "$SLOTS"` — respects `blocked_by:` dependencies.

**Hybrid pattern**: Parallel analysis phase → sequential implementation phase based on results.

## CI/CD Integration

```yaml
name: AI Code Review
on: { pull_request: { types: [opened, synchronize] } }
jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: curl -fsSL https://opencode.ai/install | bash
      - run: opencode run --format json "Review PR changes for security and quality" > review.md
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          OPENCODE_PERMISSION: '{"*":"allow"}'
```

## Runner Templates

| Template | Description |
|----------|-------------|
| [code-reviewer](runners/code-reviewer.md) | Security and quality review with structured output |
| [seo-analyst](runners/seo-analyst.md) | SEO analysis with issue/opportunity tables |

See [runners/README.md](runners/README.md) for creating runners from templates.

## Related

- `tools/ai-assistants/opencode-server.md` — full server API reference
- `tools/ai-assistants/overview.md` — AI assistant comparison
- `tools/ai-assistants/runners/` — runner templates
- `scripts/runner-helper.sh` — runner management CLI
- `scripts/cron-dispatch.sh`, `scripts/cron-helper.sh` — cron-triggered dispatch
- `scripts/matrix-dispatch-helper.sh`, `services/communications/matrix-bot.md` — Matrix chat dispatch
- `scripts/commands/pulse.md` — pulse supervisor (multi-agent coordination)
- `scripts/mail-helper.sh` — inter-agent mailbox
- `scripts/worker-token-helper.sh` — scoped GitHub tokens (t1412.2)
- `scripts/network-tier-helper.sh`, `scripts/sandbox-exec-helper.sh` — network tiering + sandbox
- `configs/network-tiers.conf` — domain classification database
- `tools/security/prompt-injection-defender.md` — prompt injection defense
- `memory/README.md` — memory system (supports namespaces)
