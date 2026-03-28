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
**Don't use for**: interactive dev (use TUI), frequent human-in-the-loop, single quick questions.

**Draft agents**: Share domain instructions across workers via `~/.aidevops/agents/draft/`. See `tools/build-agent/build-agent.md`.
**Remote dispatch**: `tools/containers/remote-dispatch.md` (SSH/Tailscale with credential forwarding).

> **Never use bare `opencode run` for dispatch** — skips lifecycle reinforcement, workers stop after PR creation (GH#5096). Always use `headless-runtime-helper.sh run`.

<!-- AI-CONTEXT-END -->

## Security

1. **Network**: `--hostname 127.0.0.1` (default) | Set `OPENCODE_SERVER_PASSWORD` for network exposure
2. **Permissions**: `OPENCODE_PERMISSION` env var for headless autonomy (`'{"*":"allow"}'` for CI/CD)
3. **Credentials**: Never pass secrets in prompts — use environment variables. Delete sessions after use.
4. **Scoped tokens** (t1412.2): Workers get minimal-permission GitHub tokens (`contents:write`, `pull_requests:write`, `issues:write`) scoped to target repo. Flow: `worker-token-helper.sh create --repo owner/repo --ttl 3600` → `GH_TOKEN` env → worker executes → `worker-token-helper.sh revoke`. Strategies: GitHub App installation tokens (repo-scoped, 1h TTL) or delegated tokens (advisory tracking, configurable TTL). Disable: `WORKER_SCOPED_TOKENS=false`.
5. **Worker sandbox** (t1412.1): Headless workers run with fake HOME — only `.gitconfig`, `GH_TOKEN`, `.aidevops/` symlink (read-only), MCP config, writable XDG dirs. No access to `~/.ssh/`, gopass, `credentials.sh`, cloud/publish tokens, browser profiles. `WORKER_SANDBOX_ENABLED=true` (default). CLI: `worker-sandbox-helper.sh create <task_id>` → auto-clean on exit → `cleanup-stale` for >24h.
6. **Network tiering** (t1412.3): 5-tier domain classification. Tier 5 (exfiltration) denied, Tier 4 (unknown) flagged. Config: `configs/network-tiers.conf`. See `network-tier-helper.sh`.

**GitHub App setup** (recommended for t1412.2): Create at `https://github.com/settings/apps/new` with Contents/PRs/Issues R&W. Install on account/org, download private key, configure `~/.config/aidevops/github-app.json` (app_id, private_key_path, installation_id) with 600 permissions.

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

### Parallel vs Sequential

| Scenario | Pattern |
|----------|---------|
| PR review (security + quality + style) | Parallel — independent read-only |
| Bug fix + tests | Sequential — tests depend on fix |
| Multi-page SEO audit | Parallel — each page independent |
| Refactor + update docs | Sequential — docs depend on refactored code |
| Tests for 5 modules | Parallel — each module independent |
| Plan → implement → verify | Sequential — each step depends on previous |
| Decomposed subtasks | Batch (`batch-strategy-helper.sh`) |

**Batch strategies (t1408.4)**: `depth-first` (default) or `breadth-first` (one subtask per branch per batch). `batch-strategy-helper.sh next-batch --strategy depth-first --tasks "$JSON" --concurrency "$SLOTS"` — respects `blocked_by:` dependencies.

### SDK Parallel

Use `Promise.all` for concurrent sessions. Monitor via SSE (`client.event.subscribe()`). See SDK docs for full API.

### OAuth-Aware Dispatch Routing (t1163)

When `SUPERVISOR_PREFER_OAUTH=true` (default), Anthropic model requests route through Claude CLI if OAuth available (zero marginal cost). Non-Anthropic models always use `opencode` CLI. Override: `export SUPERVISOR_CLI=opencode`. Detection: checks `~/.claude/` credentials, cached 5 min.

Budget tracking: `budget-tracker-helper.sh configure claude-oauth --billing-type subscription`

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

Templates: [code-reviewer](runners/code-reviewer.md), [seo-analyst](runners/seo-analyst.md). See [runners/README.md](runners/README.md).

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

## Worker Behaviour (Cross-References)

These topics are documented in their canonical locations — loaded on demand, not duplicated here:

- **Worker Uncertainty Framework** (t158/t174/t176): `scripts/commands/full-loop.md` "Headless Dispatch Rules" — when to proceed vs exit BLOCKED
- **Worker Efficiency Protocol**: `prompts/worker-efficiency-protocol.md` — TodoWrite decomposition, commit-early, ShellCheck gate, parallel sub-work
- **Lineage Context for Subtasks** (t1408/t1408.3): `scripts/commands/full-loop.md` Step 1.7 — scope isolation for dot-notation task IDs
- **Task Decomposition** (t1408.2): `reference/orchestration.md` "Task Decomposition" — atomic vs composite classification, `task-decompose-helper.sh`

## Related

- `tools/ai-assistants/opencode-server.md` — full server API reference
- `tools/ai-assistants/overview.md` — AI assistant comparison
- `tools/ai-assistants/runners-` — runner templates
- `scripts/runner-helper.sh` — runner management CLI
- `scripts/cron-dispatch.sh`, `scripts/cron-helper.sh` — cron-triggered dispatch
- `scripts/matrix-dispatch-helper.sh`, `services/communications/matrix-bot.md` — Matrix chat dispatch
- `scripts/commands/pulse.md` — pulse supervisor (multi-agent coordination)
- `scripts/mail-helper.sh` — inter-agent mailbox
- `scripts/worker-token-helper.sh` — scoped GitHub tokens (t1412.2)
- `scripts/network-tier-helper.sh`, `scripts/sandbox-exec-helper.sh` — network tiering + sandbox
- `configs/network-tiers.conf` — domain classification database
- `tools/security/prompt-injection-defender.md` — prompt injection defense
- `reference/memory.md` — memory system (supports namespaces)
