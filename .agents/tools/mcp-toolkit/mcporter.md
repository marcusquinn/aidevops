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
- **Platforms**: macOS, Linux, Windows
- **Runtime**: Bun preferred (auto-detected), Node.js fallback

**Install**:

```bash
npx mcporter list                        # zero-install via npx
pnpm add mcporter                        # project dependency
brew tap steipete/tap && brew install steipete/tap/mcporter  # Homebrew
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

**Config Locations** (resolution order):

1. `--config <path>` or `MCPORTER_CONFIG` env var
2. `<project>/config/mcporter.json`
3. `~/.mcporter/mcporter.json[c]`

**Auto-imports**: Cursor, Claude Code, Claude Desktop, Codex, Windsurf, OpenCode, VS Code configs merged automatically.

**Verification**: Run `npx mcporter list` -- should show all configured MCP servers with tool counts.

**Supported AI Assistants**: Claude Code, Claude Desktop, Cursor, Codex, Windsurf, OpenCode, VS Code (any MCP-compatible client).

**Related Agents**:

- `tools/build-mcp/build-mcp.md` for building MCP servers
- `tools/context/context7.md` for library documentation via MCP
- `tools/context/mcp-discovery.md` for MCP server discovery patterns

<!-- AI-CONTEXT-END -->

## Installation

### npx (zero-install)

Run any mcporter command without installing:

```bash
npx mcporter list
npx mcporter call context7.resolve-library-id query="React docs" libraryName=react
```

### Project dependency

```bash
pnpm add mcporter    # or npm install mcporter / yarn add mcporter
```

### Homebrew

```bash
brew tap steipete/tap
brew install steipete/tap/mcporter
```

## Discovery -- `mcporter list`

List all configured MCP servers and their available tools:

```bash
mcporter list                                    # all servers
mcporter list context7 --schema                  # single server with JSON schemas
mcporter list linear --all-parameters            # show every parameter
mcporter list https://mcp.linear.app/mcp         # ad-hoc URL
mcporter list --stdio "bun run ./server.ts"      # ad-hoc stdio server
mcporter list --json                             # machine-readable output
mcporter list --verbose                          # show config source per server
```

Single-server output renders TypeScript-style signatures:

```text
linear - Hosted Linear MCP; exposes issue search, create, and workflow tooling.
  23 tools . 1654ms . HTTP https://mcp.linear.app/mcp

  function create_comment(issueId: string, body: string, parentId?: string);
  function list_documents(query?: string, projectId?: string);
```

Required parameters always show. Optional parameters are hidden by default -- add `--all-parameters` to reveal them.

## Calling Tools -- `mcporter call`

Three equivalent call syntaxes:

```bash
# Flag style (key=value or key:value)
mcporter call linear.create_comment issueId:ENG-123 body:'Looks good!'

# Function-call style
mcporter call 'linear.create_comment(issueId: "ENG-123", body: "Looks good!")'

# Shorthand (infers `call` verb from dotted token)
mcporter linear.list_issues assignee=me
```

### Useful flags

| Flag | Description |
|------|-------------|
| `--config <path>` | Custom config file |
| `--root <path>` | Working directory for stdio commands |
| `--tail-log` | Print last 20 lines of referenced log files |
| `--output <format>` | Control output format (`json`, `raw`, or auto) |
| `--log-level <level>` | `debug`, `info`, `warn`, `error` |
| `--oauth-timeout <ms>` | Override OAuth browser wait (default 60s) |

### Auto-correction

MCPorter fuzzy-matches tool names. If you typo `listIssues`, it auto-corrects to `list_issues`. Larger mismatches print a "Did you mean ...?" hint.

### Timeouts

Defaults to 30s per call. Override with environment variables:

```bash
MCPORTER_LIST_TIMEOUT=120000 mcporter list vercel
MCPORTER_CALL_TIMEOUT=60000 mcporter call firecrawl.crawl url=https://example.com
```

## CLI Generation -- `mcporter generate-cli`

Turn any MCP server into a standalone CLI binary:

```bash
# From an HTTP URL
mcporter generate-cli --command https://mcp.context7.com/mcp

# From a stdio command
mcporter generate-cli --command "npx -y chrome-devtools-mcp@latest"

# With compilation to native binary (requires Bun)
mcporter generate-cli --command https://mcp.context7.com/mcp --compile
chmod +x context7
./context7 list-tools
./context7 resolve-library-id react

# From a configured server name
mcporter generate-cli linear --bundle dist/linear.js
```

### Key flags

| Flag | Description |
|------|-------------|
| `--name <name>` | Override inferred CLI name |
| `--description "..."` | Custom help summary |
| `--bundle [path]` | Emit bundled JS (Rolldown for Node, Bun for Bun) |
| `--compile [path]` | Emit native binary via `bun build --compile` |
| `--runtime bun\|node` | Target runtime (auto-detected) |
| `--output <path>` | Write template to specific path |
| `--include-tools a,b,c` | Generate CLI for subset of tools |
| `--exclude-tools a,b,c` | Exclude specific tools |
| `--minify` | Shrink bundled output |
| `--from <artifact>` | Regenerate from existing CLI metadata |

Generated CLIs embed tool schemas, so subsequent runs skip `listTools` round-trips. Every artifact includes regeneration metadata:

```bash
mcporter inspect-cli dist/context7.js              # view embedded metadata
mcporter generate-cli --from dist/context7.js      # regenerate with latest mcporter
```

## Typed Client Emission -- `mcporter emit-ts`

Generate TypeScript type definitions or full client wrappers:

```bash
# Types-only (.d.ts interface)
mcporter emit-ts linear --out types/linear-tools.d.ts

# Client wrapper (.d.ts + .ts proxy factory)
mcporter emit-ts linear --mode client --out clients/linear.ts
```

### Modes

| Mode | Output | Use case |
|------|--------|----------|
| `types` (default) | `.d.ts` interface with Promise signatures | Import types anywhere |
| `client` | `.d.ts` + `.ts` helper wrapping `createRuntime`/`createServerProxy` | Ready-to-use typed client |

### Flags

| Flag | Description |
|------|-------------|
| `--mode types\|client` | Output mode |
| `--out <path>` | Output file path |
| `--include-optional` | Include all optional fields (mirrors `--all-parameters`) |
| `--json` | Emit structured summary for scripting |

The `<server>` argument accepts server names, HTTP URLs, and `.tool` suffixes -- same as the main CLI.

## OAuth Authentication -- `mcporter auth`

Complete OAuth login for servers that require it (Vercel, Supabase, etc.):

```bash
mcporter auth vercel                    # named server from config
mcporter auth https://mcp.example.com   # ad-hoc URL (auto-detects OAuth)
```

### How it works

1. Launches a temporary callback server on `127.0.0.1`
2. Opens the authorization URL in your default browser (or prints it)
3. Exchanges the code and persists tokens under `~/.mcporter/<server>/`

### Reset credentials

Delete `~/.mcporter/<server>/` and rerun the command for a fresh login.

### Flags

| Flag | Description |
|------|-------------|
| `--json` | Structured error output for scripting |
| `--oauth-timeout <ms>` | Override browser wait timeout |

## Daemon Mode

Keep stateful MCP servers (Chrome DevTools, mobile-mcp, etc.) warm between agent calls:

```bash
mcporter daemon start                   # pre-warm configured keep-alive servers
mcporter daemon status                  # check running servers
mcporter daemon stop                    # shut down
mcporter daemon restart                 # bounce after config changes
```

### Server lifecycle

- Servers with `"lifecycle": "keep-alive"` in config auto-start with the daemon
- Set `MCPORTER_KEEPALIVE=name` to opt a server in via environment
- Set `MCPORTER_DISABLE_KEEPALIVE=name` or `"lifecycle": "ephemeral"` to opt out
- Ad-hoc servers (via `--stdio`/`--http-url`) remain per-process; persist them to participate in the daemon

### Daemon logging

```bash
mcporter daemon start --log                          # tee to stdout
mcporter daemon start --log-file /tmp/daemon.log     # write to file
mcporter daemon start --log-servers chrome-devtools   # filter by server
```

Per-server config: `"logging": { "daemon": { "enabled": true } }`.

## Ad-Hoc Connections

Connect to any MCP endpoint without editing config:

```bash
# HTTP server
mcporter list --http-url https://mcp.linear.app/mcp --name linear
mcporter call --http-url https://mcp.linear.app/mcp.list_issues assignee=me

# Stdio server
mcporter call --stdio "bun run ./local-server.ts" --name local-tools

# With environment variables
mcporter list --stdio "npx -y some-mcp" --env API_KEY=sk_example --cwd /project

# Persist for future use
mcporter list --http-url https://mcp.example.com/mcp --persist config/mcporter.json
```

### Flags for ad-hoc connections

| Flag | Description |
|------|-------------|
| `--http-url <url>` | HTTP/SSE MCP endpoint |
| `--stdio "command"` | Stdio MCP command |
| `--env KEY=value` | Inject environment variables |
| `--cwd <path>` | Working directory for stdio |
| `--name <slug>` | Name the ad-hoc server |
| `--persist <config>` | Save definition to config file |
| `--allow-http` | Allow cleartext HTTP (HTTPS required by default) |

STDIO transports inherit your shell environment automatically. Use `--env` only for overrides.

## Config Resolution

MCPorter reads one primary config per run, in this order:

1. `--config <path>` flag or programmatic `configPath`
2. `MCPORTER_CONFIG` environment variable
3. `<project>/config/mcporter.json`
4. `~/.mcporter/mcporter.json` or `~/.mcporter/mcporter.jsonc`

### Config format

```jsonc
{
  "mcpServers": {
    "context7": {
      "description": "Context7 docs MCP",
      "baseUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "Authorization": "$env:CONTEXT7_API_KEY"
      }
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

### Config features

- **Variable interpolation**: `${VAR}`, `${VAR:-fallback}`, `$env:VAR` in headers and env
- **OAuth token caching**: Automatic under `~/.mcporter/<server>/` (override with `tokenCacheDir`)
- **Import merging**: Auto-merges Cursor, Claude, Codex, Windsurf, OpenCode, VS Code configs
- **Import precedence**: Array order; first entry wins on conflicts
- **Convenience auth**: `bearerToken` or `bearerTokenEnv` fields auto-populate `Authorization` headers

### Managing config via CLI

```bash
mcporter config list                              # show local entries
mcporter config list --source import              # show imported entries
mcporter config get linear                        # show single server config
mcporter config add my-server https://example.com/mcp  # add a server
mcporter config remove old-server                 # remove a server
mcporter config import cursor --copy              # copy Cursor entries locally
mcporter config --config ~/.mcporter/mcporter.json add global https://api.example.com/mcp
```

## Runtime API

### One-shot call

```typescript
import { callOnce } from "mcporter";

const result = await callOnce({
  server: "firecrawl",
  toolName: "crawl",
  args: { url: "https://anthropic.com" },
});
```

### Pooled runtime

```typescript
import { createRuntime } from "mcporter";

const runtime = await createRuntime();
const tools = await runtime.listTools("context7");
const result = await runtime.callTool("context7", "resolve-library-id", {
  args: { libraryName: "react" },
});
await runtime.close();
```

### Server proxy (ergonomic camelCase API)

```typescript
import { createRuntime, createServerProxy } from "mcporter";

const runtime = await createRuntime();
const linear = createServerProxy(runtime, "linear");

// camelCase maps to tool names: searchDocumentation -> search_documentation
const docs = await linear.searchDocumentation({ query: "automations" });
console.log(docs.json());    // parsed JSON
console.log(docs.text());    // plain text
console.log(docs.markdown());// markdown
console.log(docs.raw);       // full MCP envelope

await runtime.close();
```

### CallResult helpers

| Method | Returns |
|--------|---------|
| `.text()` | Plain text content |
| `.markdown()` | Markdown-formatted content |
| `.json<T>()` | Parsed JSON with type parameter |
| `.content()` | Raw content array |
| `.raw` | Full MCP response envelope |

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

### Server not responding

```bash
mcporter list --verbose          # check config sources
mcporter list <server> --json    # structured error info
MCPORTER_LOG_LEVEL=debug mcporter call <server>.<tool>  # verbose logging
```

### OAuth issues

```bash
rm -rf ~/.mcporter/<server>/     # reset tokens
mcporter auth <server>           # re-authenticate
mcporter auth <server> --json    # structured error output
```

### Hanging connections

```bash
MCPORTER_DEBUG_HANG=1 mcporter list    # verbose handle diagnostics
mcporter daemon restart                # bounce the daemon
```

### Slow server startup

```bash
MCPORTER_LIST_TIMEOUT=120000 mcporter list <server>
```

## References

- **Repository**: [steipete/mcporter](https://github.com/steipete/mcporter)
- **npm**: [mcporter](https://www.npmjs.com/package/mcporter)
- **Website**: [mcporter.dev](https://mcporter.dev)
- **Docs**: `docs/cli-reference.md`, `docs/adhoc.md`, `docs/emit-ts.md`, `docs/config.md` in the repo
- **MCP Spec**: [modelcontextprotocol/specification](https://github.com/modelcontextprotocol/specification)

Use Context7 MCP for current mcporter documentation:

```bash
mcporter call context7.resolve-library-id query="mcporter MCP toolkit" libraryName=mcporter
```
