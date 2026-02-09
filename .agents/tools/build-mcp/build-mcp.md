---
name: build-mcp
description: MCP server development - building Model Context Protocol servers and tools
mode: subagent
---

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

**Related Agents**:
- `@code-standards` for linting TypeScript
- `tools/context/context7.md` for MCP SDK docs

**Git Workflow**:
- Branch strategy: `workflows/branch.md`
- Git operations: `tools/git.md`

**Testing**: Use OpenCode CLI to test new MCPs without restarting TUI:

```bash
opencode run "Test [mcp] tools" --agent Build+
```

See `tools/opencode/opencode.md` for CLI testing patterns.

**MCPs to Enable**: context7, augment-context-engine, repomix

<!-- AI-CONTEXT-END -->

## Why TypeScript + Bun + ElysiaJS?

| Criterion | Why This Stack |
|-----------|----------------|
| **Robustness** | Official MCP SDK, Zod validation, full spec compliance |
| **Speed** | Bun is 3-4x faster than Node.js |
| **Maintainability** | End-to-end type safety, auto-generated OpenAPI docs |
| **Future-Proof** | Anthropic-backed spec, growing ecosystem |

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

See `build-mcp/server-patterns.md` for complete tool, resource, and prompt registration patterns.

**Minimal tool example**:

```typescript
server.tool(
  'get_data',
  { query: z.string().describe('Search query') },
  async (args) => ({
    content: [{ type: 'text', text: JSON.stringify(await fetchData(args.query)) }],
  })
);
```

## Transport Selection

| Transport | Use Case |
|-----------|----------|
| stdio | Local dev, AI assistant spawns process |
| StreamableHTTP | Production HTTP servers |
| SSE | Legacy compatibility only |

See `build-mcp/transports.md` for complete transport configuration.

## Testing & Debugging

```bash
npx @modelcontextprotocol/inspector  # Connect to http://localhost:3000/mcp
```

Use `console.error()` for logging (stdout is MCP protocol).

## Deployment

See `build-mcp/deployment.md` for all AI assistant configurations.

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "my-mcp": {
      "type": "local",
      "command": ["bun", "run", "/path/to/my-mcp/src/index.ts"],
      "enabled": true
    }
  }
}
```

**Claude Code**: `claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts`

## AI-Friendly Tool Design

See `build-mcp/server-patterns.md` for complete naming conventions.

**Key rules**:
- Name: `verb_noun` pattern (`get_user`, `list_items`, `create_order`)
- Description: What it does, when to use, what it returns, side effects
- Parameters: Always use `.describe()` with constraints

```typescript
// Good
server.tool(
  'get_user',
  'Retrieves user by ID. Returns profile or null if not found.',
  { id: z.string().uuid().describe('User ID (UUID format)') }
);
```

## Common Patterns (Not Yet in Subagents)

These patterns are frequently needed but not yet documented in subagents:

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

1. **Validation**: Zod schemas with `.describe()`
2. **Errors**: Return structured JSON in content, set `isError: true`
3. **Logging**: `console.error()` only (stdout is protocol)
4. **Types**: Export input/output types

Run `@code-standards` before committing TypeScript.

## References

Use Context7 MCP for current documentation:
- MCP SDK: `resolve library-id for @modelcontextprotocol/sdk`
- ElysiaJS: `resolve library-id for elysia`
- Bun: `resolve library-id for bun`
