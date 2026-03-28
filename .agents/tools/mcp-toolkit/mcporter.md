---
name: mcporter
description: MCPorter - TypeScript runtime, CLI, and code-generation toolkit for MCP servers
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

# MCPorter - MCP Toolkit

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover, call, compose, and generate CLIs/typed clients for MCP servers
- **Package**: `mcporter` (npm) | `steipete/tap/mcporter` (Homebrew)
- **Repo**: [steipete/mcporter](https://github.com/steipete/mcporter) (MIT, 2k+ stars) | **Site**: [mcporter.dev](https://mcporter.dev)
- **Runtime**: Bun preferred (auto-detected), Node.js fallback

**Install**:

```bash
npx mcporter list                                       # zero-install
pnpm add mcporter                                       # project dependency
brew tap steipete/tap && brew install mcporter          # Homebrew
```

**Core Commands**:

| Command | Purpose |
|---------|---------|
| `mcporter list` | Discover configured MCP servers and their tools |
| `mcporter call` | Invoke an MCP tool with arguments |
| `mcporter generate-cli` | Mint a standalone CLI from any MCP server |
| `mcporter emit-ts` | Emit `.d.ts` interfaces or typed client wrappers |
| `mcporter auth` | Complete OAuth login for a server |
| `mcporter config` | Manage `mcporter.json` entries |
| `mcporter daemon` | Keep stateful MCP servers warm between calls |

**Config Locations** (resolution order): `--config <path>` / `MCPORTER_CONFIG` → `<project>/config/mcporter.json` → `~/.mcporter/mcporter.json[c]`

**Auto-imports**: Cursor, Claude Code, Claude Desktop, Codex, Windsurf, OpenCode, VS Code configs merged automatically.

**Related Agents**: `tools/build-mcp/build-mcp.md` | `tools/context/context7.md` | `tools/context/mcp-discovery.md`

<!-- AI-CONTEXT-END -->

## Discovery

```bash
mcporter list                                    # all servers
mcporter list context7 --schema                  # single server with JSON schemas
mcporter list linear --all-parameters            # show every parameter
mcporter list https://mcp.linear.app/mcp         # ad-hoc URL
mcporter list --stdio "bun run ./server.ts"      # ad-hoc stdio server
mcporter list --json                             # machine-readable output
mcporter list --verbose                          # show config source per server
```

Single-server output renders TypeScript-style signatures. Required parameters always show; optional hidden by default (`--all-parameters` to reveal).

## Calling Tools

```bash
# Flag style
mcporter call linear.create_comment issueId:ENG-123 body:'Looks good!'

# Function-call style
mcporter call 'linear.create_comment(issueId: "ENG-123", body: "Looks good!")'

# Shorthand (infers `call` from dotted token)
mcporter linear.list_issues assignee=me
```

**Flags:** `--config <path>` | `--root <path>` | `--tail-log` | `--output json|raw` | `--log-level debug|info|warn|error` | `--oauth-timeout <ms>`

**Auto-correction:** Fuzzy-matches tool names. Typo `listIssues` → auto-corrects to `list_issues`.

**Timeouts** (default 30s): `MCPORTER_LIST_TIMEOUT=120000 mcporter list vercel` | `MCPORTER_CALL_TIMEOUT=60000 mcporter call firecrawl.crawl url=...`

## CLI Generation

```bash
mcporter generate-cli --command https://mcp.context7.com/mcp
mcporter generate-cli --command "npx -y chrome-devtools-mcp@latest"
mcporter generate-cli --command https://mcp.context7.com/mcp --compile   # native binary (Bun)
mcporter generate-cli linear --bundle dist/linear.js
```

**Flags:** `--name <name>` | `--bundle [path]` | `--compile [path]` | `--runtime bun|node` | `--include-tools a,b,c` | `--exclude-tools a,b,c` | `--minify` | `--from <artifact>`

Generated CLIs embed tool schemas (skip `listTools` round-trips). Regenerate from existing artifact:

```bash
mcporter inspect-cli dist/context7.js              # view embedded metadata
mcporter generate-cli --from dist/context7.js      # regenerate with latest mcporter
```

## Typed Client Emission

```bash
mcporter emit-ts linear --out types/linear-tools.d.ts                    # types only
mcporter emit-ts linear --mode client --out clients/linear.ts            # full client
```

| Mode | Output | Use case |
|------|--------|----------|
| `types` (default) | `.d.ts` interface | Import types anywhere |
| `client` | `.d.ts` + `.ts` proxy factory | Ready-to-use typed client |

**Flags:** `--mode types|client` | `--out <path>` | `--include-optional` | `--json`

## OAuth Authentication

```bash
mcporter auth vercel                    # named server from config
mcporter auth https://mcp.example.com   # ad-hoc URL
rm -rf ~/.mcporter/<server>/            # reset credentials
```

Launches a temporary callback server on `127.0.0.1`, completes OAuth flow, persists tokens under `~/.mcporter/<server>/`.

## Daemon Mode

```bash
mcporter daemon start|status|stop|restart
mcporter daemon start --log                          # tee to stdout
mcporter daemon start --log-file /tmp/daemon.log
```

Servers with `"lifecycle": "keep-alive"` auto-start with the daemon. Set `MCPORTER_KEEPALIVE=name` to opt in via env; `MCPORTER_DISABLE_KEEPALIVE=name` or `"lifecycle": "ephemeral"` to opt out.

## Ad-Hoc Connections

```bash
mcporter list --http-url https://mcp.linear.app/mcp --name linear
mcporter call --stdio "bun run ./local-server.ts" --name local-tools local-tools.some_tool arg=value
mcporter list --stdio "npx -y some-mcp" --env API_KEY=sk_example --cwd /project
mcporter list --http-url https://mcp.example.com/mcp --persist config/mcporter.json
```

**Flags:** `--http-url <url>` | `--stdio "command"` | `--env KEY=value` | `--cwd <path>` | `--name <slug>` | `--persist <config>` | `--allow-http`

STDIO transports inherit your shell environment. Use `--env` only for overrides.

## Config

```jsonc
{
  "mcpServers": {
    "context7": {
      "description": "Context7 docs MCP",
      "baseUrl": "https://mcp.context7.com/mcp",
      "headers": { "Authorization": "$env:CONTEXT7_API_KEY" }
    },
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest"],
      "env": { "npm_config_loglevel": "error" }
    }
  },
  "imports": ["cursor", "claude-code", "claude-desktop", "codex", "windsurf", "opencode", "vscode"]
}
```

**Features:** Variable interpolation (`${VAR}`, `$env:VAR`), OAuth token caching under `~/.mcporter/<server>/`, import merging (first entry wins on conflicts), `bearerToken`/`bearerTokenEnv` fields auto-populate `Authorization` headers.

```bash
mcporter config list|get|add|remove|import   # manage entries
mcporter config add my-server https://example.com/mcp
mcporter config import cursor --copy
```

## Runtime API

```typescript
import { callOnce, createRuntime, createServerProxy } from "mcporter";
// One-shot
const result = await callOnce({ server: "firecrawl", toolName: "crawl", args: { url: "https://anthropic.com" } });
// Pooled runtime
const runtime = await createRuntime();
const tools = await runtime.listTools("context7");
const result = await runtime.callTool("context7", "resolve-library-id", { args: { libraryName: "react" } });
await runtime.close();
// Server proxy (camelCase API)
const linear = createServerProxy(runtime, "linear");
const docs = await linear.searchDocumentation({ query: "automations" });
console.log(docs.json());     // parsed JSON
console.log(docs.text());     // plain text
console.log(docs.markdown()); // markdown
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPORTER_CONFIG` | -- | Override config file path |
| `MCPORTER_LOG_LEVEL` | `warn` | Log verbosity |
| `MCPORTER_LIST_TIMEOUT` | `60000` | List command timeout (ms) |
| `MCPORTER_CALL_TIMEOUT` | `30000` | Call command timeout (ms) |
| `MCPORTER_OAUTH_TIMEOUT_MS` | `60000` | OAuth browser wait (ms) |
| `MCPORTER_KEEPALIVE` | -- | Server names to keep alive in daemon |
| `MCPORTER_DISABLE_KEEPALIVE` | -- | Server names to exclude from daemon |
| `MCPORTER_DEBUG_HANG` | -- | Enable verbose handle diagnostics |
| `BUN_BIN` | -- | Override Bun binary path |

## Troubleshooting

```bash
mcporter list --verbose                                          # check config sources
MCPORTER_LOG_LEVEL=debug mcporter call <server>.<tool>          # verbose logging
rm -rf ~/.mcporter/<server>/ && mcporter auth <server>          # reset OAuth
MCPORTER_DEBUG_HANG=1 mcporter list                             # hanging connections
mcporter daemon restart                                          # bounce daemon
MCPORTER_LIST_TIMEOUT=120000 mcporter list <server>             # slow startup
```

## Security

**MCP servers are a distinct trust boundary** — each runs as a persistent process with network access and full visibility into your AI assistant's conversation context.

| Risk | Description |
|------|-------------|
| Prompt injection via tool responses | Malicious server embeds instructions in tool responses to manipulate agent behaviour |
| Credential access | Servers with `env` blocks receive API keys; stdio servers inherit your full shell environment |
| Conversation context exposure | Servers see full tool call context including file contents and conversation history |
| Supply chain attacks | Same risks as any npm/pip dependency — typosquatting, compromised maintainers |
| Persistent process risks | Daemon-mode servers have sustained system access |

**Before installing an MCP server:**

1. Verify source — check repo, maintainer reputation, star count, recent commits
2. Scan dependencies: `npx @socketsecurity/cli npm info <package-name>`
3. Scan source for injection patterns: `git clone <repo> /tmp/mcp && skill-scanner scan /tmp/mcp`
4. Review permissions — use scoped tokens, not full-access API keys
5. Prefer HTTPS endpoints (mcporter enforces this by default)

### Runtime Description Auditing (t1428.2)

MCP tool descriptions are injected into the AI model's context at runtime. A malicious server can embed prompt injection payloads in descriptions — the most underappreciated MCP attack vector per Grith/Invariant Labs research.

```bash
mcp-audit-helper.sh scan                    # all configured servers
mcp-audit-helper.sh scan --server context7  # specific server
mcp-audit-helper.sh scan --json             # CI/CD integration
mcp-audit-helper.sh report                  # audit history
```

Detects: file read instructions (CRITICAL), credential exfiltration (CRITICAL), data exfiltration (HIGH), hidden instructions (HIGH), scope escalation (MEDIUM).

**Run during:** `aidevops init`, after `mcporter config add`, periodic security audits.

**Ongoing:** Pin versions (not `@latest`); re-run `mcp-audit-helper.sh scan` after updates; remove unused servers; monitor daemon logs for unexpected network activity.

**Related:** `tools/security/prompt-injection-defender.md` | `scripts/mcp-audit-helper.sh` | `tools/code-review/skill-scanner.md` | `services/monitoring/socket.md`

## References

- **Repo**: [steipete/mcporter](https://github.com/steipete/mcporter) | **npm**: [mcporter](https://www.npmjs.com/package/mcporter)
- **MCP Spec**: [modelcontextprotocol/specification](https://github.com/modelcontextprotocol/specification)
