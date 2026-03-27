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
- **Repo**: [steipete/mcporter](https://github.com/steipete/mcporter) (MIT, 2k+ stars)
- **Runtime**: Bun preferred (auto-detected), Node.js fallback
- **Config resolution**: `--config <path>` / `MCPORTER_CONFIG` -> `<project>/config/mcporter.json` -> `~/.mcporter/mcporter.json[c]`
- **Auto-imports**: Cursor, Claude Code, Claude Desktop, Codex, Windsurf, OpenCode, VS Code configs merged automatically

**Install**: `npx mcporter list` (zero-install) | `pnpm add mcporter` (project dep) | `brew tap steipete/tap && brew install mcporter`

**Commands**: `list` (discover servers/tools) | `call` (invoke tool) | `generate-cli` (mint standalone CLI) | `emit-ts` (typed clients/`.d.ts`) | `auth` (OAuth login) | `config` (manage entries) | `daemon` (keep servers warm)

**Related**: `tools/build-mcp/build-mcp.md` | `tools/context/context7.md` | `tools/context/mcp-discovery.md`

<!-- AI-CONTEXT-END -->

## Discovery and Calling Tools

```bash
mcporter list                                    # all servers
mcporter list context7 --schema                  # single server with JSON schemas
mcporter list --json                             # machine-readable
mcporter list https://mcp.linear.app/mcp         # ad-hoc URL
mcporter call linear.create_comment issueId:ENG-123 body:'Looks good!'
mcporter call 'linear.create_comment(issueId: "ENG-123", body: "Looks good!")'
mcporter linear.list_issues assignee=me          # shorthand (dotted token infers `call`)
```

**Flags**: `--all-parameters` | `--verbose` | `--config <path>` | `--root <path>` | `--tail-log` | `--output json|raw` | `--log-level debug|info|warn|error`

Auto-correction fuzzy-matches tool names (`listIssues` -> `list_issues`). Timeouts: `MCPORTER_CALL_TIMEOUT` (30s default) / `MCPORTER_LIST_TIMEOUT` (60s default).

## CLI Generation

```bash
mcporter generate-cli --command https://mcp.context7.com/mcp              # from URL
mcporter generate-cli --command https://mcp.context7.com/mcp --compile    # native binary (Bun)
mcporter generate-cli linear --bundle dist/linear.js                      # bundled JS
mcporter inspect-cli dist/context7.js                                     # view embedded metadata
mcporter generate-cli --from dist/context7.js                             # regenerate from artifact
```

**Flags**: `--name` | `--bundle [path]` | `--compile [path]` | `--runtime bun|node` | `--include-tools a,b,c` | `--exclude-tools a,b,c` | `--minify` | `--from <artifact>`. Generated CLIs embed tool schemas (skip `listTools` round-trips).

## Typed Client Emission

`mcporter emit-ts linear --out types/linear-tools.d.ts` (types only, default) | `--mode client --out clients/linear.ts` (full typed client). **Flags**: `--mode types|client` | `--out <path>` | `--include-optional` | `--json`

## OAuth, Daemon, Ad-Hoc

```bash
mcporter auth vercel                             # OAuth (persists tokens to ~/.mcporter/<server>/)
mcporter auth https://mcp.example.com            # ad-hoc OAuth
rm -rf ~/.mcporter/<server>/                     # reset credentials
mcporter daemon start|status|stop|restart        # keep stateful servers warm
mcporter list --http-url https://mcp.linear.app/mcp --name linear   # ad-hoc HTTP
mcporter call --stdio "bun run ./local-server.ts" --name local local.some_tool arg=value
mcporter list --http-url https://mcp.example.com/mcp --persist config/mcporter.json
```

**Ad-hoc flags**: `--http-url <url>` | `--stdio "command"` | `--env KEY=value` | `--cwd <path>` | `--name <slug>` | `--persist <config>` | `--allow-http`. STDIO inherits shell env; `--env` for overrides only. Daemon config: `"lifecycle": "keep-alive"` | `MCPORTER_KEEPALIVE=name`.

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

Variable interpolation: `${VAR}`, `$env:VAR`. OAuth tokens cached under `~/.mcporter/<server>/`. Import merging: first entry wins. `bearerToken`/`bearerTokenEnv` auto-populate `Authorization` headers. Manage: `mcporter config list|get|add|remove|import`, e.g. `mcporter config add my-server https://example.com/mcp`.

## Runtime API

```typescript
import { callOnce, createRuntime, createServerProxy } from "mcporter";
const result = await callOnce({ server: "firecrawl", toolName: "crawl", args: { url: "https://anthropic.com" } });
const runtime = await createRuntime();                                    // pooled runtime
await runtime.callTool("context7", "resolve-library-id", { args: { libraryName: "react" } });
await runtime.close();
const linear = createServerProxy(runtime, "linear");                     // server proxy (camelCase)
const docs = await linear.searchDocumentation({ query: "automations" }); // .json() .text() .markdown()
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCPORTER_CONFIG` | -- | Override config file path |
| `MCPORTER_LOG_LEVEL` | `warn` | Log verbosity (`debug\|info\|warn\|error`) |
| `MCPORTER_LIST_TIMEOUT` | `60000` | List timeout (ms) |
| `MCPORTER_CALL_TIMEOUT` | `30000` | Call timeout (ms) |
| `MCPORTER_OAUTH_TIMEOUT_MS` | `60000` | OAuth browser wait (ms) |
| `MCPORTER_KEEPALIVE` / `MCPORTER_DISABLE_KEEPALIVE` | -- | Daemon keep-alive include/exclude |
| `MCPORTER_DEBUG_HANG` | -- | Verbose handle diagnostics |
| `BUN_BIN` | -- | Override Bun binary path |

## Troubleshooting

`mcporter list --verbose` (config sources) | `MCPORTER_LOG_LEVEL=debug mcporter call <server>.<tool>` (verbose) | `rm -rf ~/.mcporter/<server>/ && mcporter auth <server>` (reset OAuth) | `MCPORTER_DEBUG_HANG=1 mcporter list` (hanging) | `MCPORTER_LIST_TIMEOUT=120000 mcporter list <server>` (slow startup)

## Security

MCP servers are a distinct trust boundary -- persistent processes with network access and conversation context visibility. **Risks**: prompt injection via tool responses, credential access (env blocks / inherited shell env), conversation context exposure, supply chain attacks, persistent daemon access.

**Before installing**: (1) verify source (repo, maintainer, stars); (2) `npx @socketsecurity/cli npm info <pkg>`; (3) `skill-scanner scan /tmp/mcp`; (4) scoped tokens only; (5) prefer HTTPS (default).

**Runtime description auditing (t1428.2)**: tool descriptions injected into model context can carry prompt injection payloads (Grith/Invariant Labs). Scan: `mcp-audit-helper.sh scan [--server name] [--json]` | `mcp-audit-helper.sh report`. Detects: file read (CRITICAL), credential exfiltration (CRITICAL), data exfiltration (HIGH), hidden instructions (HIGH), scope escalation (MEDIUM). Run during `aidevops init`, after `mcporter config add`, and periodically. Pin versions (not `@latest`); remove unused servers.

**Related**: `tools/security/prompt-injection-defender.md` | `scripts/mcp-audit-helper.sh` | `tools/code-review/skill-scanner.md` | `services/monitoring/socket.md`

## References

- **Repo**: [steipete/mcporter](https://github.com/steipete/mcporter) | **npm**: [mcporter](https://www.npmjs.com/package/mcporter) | **Site**: [mcporter.dev](https://mcporter.dev)
- **MCP Spec**: [modelcontextprotocol/specification](https://github.com/modelcontextprotocol/specification)

```bash
mcporter call context7.resolve-library-id query="mcporter MCP toolkit" libraryName=mcporter
```
