---
name: build-mcp
description: MCP server development - building Model Context Protocol servers and tools
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Build-MCP - MCP Server Development Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build MCP servers with TypeScript + Bun + ElysiaJS
- **Stack**: `@modelcontextprotocol/sdk` + `elysia-mcp` + Zod
- **Starter**: `bun create https://github.com/kerlos/elysia-mcp-starter`
- **Inspector**: `npx @modelcontextprotocol/inspector`

**Quick Start**:

```bash
bun create https://github.com/kerlos/elysia-mcp-starter my-mcp
cd my-mcp && bun install && bun run dev
npx @modelcontextprotocol/inspector  # Connect to http://localhost:3000/mcp
```

**Subagents** (in this folder):

| Subagent | When to Read |
|----------|--------------|
| `server-patterns.md` | Registering tools, resources, prompts |
| `transports.md` | Configuring stdio, HTTP, SSE |
| `deployment.md` | Adding MCP to AI assistants |
| `api-wrapper.md` | Wrapping REST APIs as MCP |

**Related**: `@code-standards` (TypeScript linting), `tools/context/context7.md` (MCP SDK docs)

**Git Workflow**: `workflows/branch.md` (branching), `tools/git.md` (operations)

**Testing**: Use OpenCode CLI to test new MCPs without restarting TUI:

```bash
opencode run "Test [mcp] tools" --agent Build+
```

See `tools/opencode/opencode.md` for CLI testing patterns.

**MCPs to Enable**: context7, augment-context-engine, repomix

<!-- AI-CONTEXT-END -->

## Project Structure

```text
my-mcp/
├── src/
│   ├── index.ts          # Server entry point
│   ├── tools/            # Tool implementations
│   ├── resources/        # Resource handlers
│   └── prompts/          # Prompt templates
├── package.json
├── tsconfig.json
└── bunfig.toml
```

## Core Patterns

See `build-mcp/server-patterns.md` for tool, resource, and prompt registration. See `build-mcp/transports.md` for transport selection (stdio, StreamableHTTP, SSE). See `build-mcp/deployment.md` for AI assistant configurations.

**Claude Code quick deploy**: `claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts`

## AI-Friendly Tool Design

See `build-mcp/server-patterns.md` for complete naming conventions.

**Key rules**: Name with `verb_noun` (`get_user`, `list_items`). Describe what it does, when to use, what it returns, side effects. Always use `.describe()` with constraints on parameters.

## Common Patterns

### Authentication

```typescript
// API Key from environment
const API_KEY = process.env.API_KEY;
if (!API_KEY) throw new Error('API_KEY required');

// OAuth token refresh (implement in your auth module)
async function getAccessToken(): Promise<string> {
  // Check cache, refresh if expired
}
```

### Rate Limiting

```typescript
import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const ratelimit = new Ratelimit({
  redis: Redis.fromEnv(),
  limiter: Ratelimit.slidingWindow(10, '10 s'),
});

// In tool handler
const { success } = await ratelimit.limit(identifier);
if (!success) return { content: [{ type: 'text', text: 'Rate limited' }], isError: true };
```

### Retry Logic

```typescript
async function withRetry<T>(fn: () => Promise<T>, retries = 3): Promise<T> {
  for (let i = 0; i < retries; i++) {
    try { return await fn(); }
    catch (e) { if (i === retries - 1) throw e; await sleep(1000 * 2 ** i); }
  }
  throw new Error('Unreachable');
}
```

## Quality Standards

1. **Validation**: Zod schemas with `.describe()` on every parameter
2. **Errors**: Structured JSON in content, set `isError: true`
3. **Logging**: `console.error()` only (stdout is MCP protocol)
4. **Types**: Export input/output types

Run `@code-standards` before committing TypeScript.

## Security for MCP Server Authors

MCP servers are a trust boundary -- users grant access to conversation context, credentials, and system.

- **Tool response integrity**: Never include instructions or behavioural suggestions in tool responses. Responses must contain only requested data -- embedding instructions is the primary prompt injection vector (see `tools/security/prompt-injection-defender.md`).
- **Credentials**: Accept via environment variables, not CLI arguments (visible in process lists). Never log, persist, or transmit beyond intended use. Document minimum required permissions.
- **Minimal permissions**: Request only needed API scopes and filesystem access. Read-only server? Don't request write permissions. Document all permissions in README.
- **Dependency hygiene**: Keep dependencies minimal and audited. Run `npx @socketsecurity/cli npm info <your-package>` before publishing. Pin versions (not `@latest`). Use `npm audit` or Socket.dev in CI.
- **Input validation**: Validate all tool arguments with Zod. Never pass user-supplied strings directly to shell commands, SQL, or file paths without sanitisation.
- **Network transparency**: Document all external network connections. Users should know which domains your server contacts and why.

## Consuming Remote MCPs

The sections above cover **building** MCP servers. This section covers **consuming** third-party remote MCPs.

| Type | Transport | How it runs |
|------|-----------|-------------|
| **Local** | STDIO | Assistant spawns process; communicates via stdin/stdout |
| **Remote** | Streamable HTTP | Provider-hosted; HTTP POST with `Accept: application/json, text/event-stream` |

Remote MCPs may work on API plans that block direct REST access (provider hosts the server and controls transport).

### OpenCode Remote MCP Config

In `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "provider-name": {
      "type": "remote",
      "url": "https://mcp.provider.com/sse",
      "headers": { "Authorization": "Bearer <API_KEY>" },
      "enabled": true
    }
  }
}
```

Key fields: `type` (`local` | `remote`), `url` (Streamable HTTP endpoint), `headers` (auth), `timeout` (ms, optional), `oauth` (OAuth config, optional).

### Secure Key Injection

Never paste API keys into conversation context. Inject from gopass:

```bash
tmpfile=$(mktemp)
jq --arg key "$(gopass show -o provider/api-key)" \
  '.mcp["provider-name"].headers.Authorization = "Bearer " + $key' \
  ~/.config/opencode/opencode.json > "$tmpfile" && mv "$tmpfile" ~/.config/opencode/opencode.json
```

### Auth Debugging

| HTTP Status | Meaning | Action |
|-------------|---------|--------|
| **401** | No auth or invalid token | Check `headers.Authorization` is set and key is correct |
| **403** | Auth valid but insufficient scope/plan | Upgrade API plan or request required scope |
| **405** | Wrong HTTP method or transport | Ensure URL accepts POST with Streamable HTTP headers |

## References

Use Context7 MCP for current documentation:

- MCP SDK: `resolve library-id for @modelcontextprotocol/sdk`
- ElysiaJS: `resolve library-id for elysia`
- Bun: `resolve library-id for bun`
