---
description: MCP server patterns for tools, resources, and prompts
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP Server Patterns - Tools, Resources, Prompts

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Validation**: Always use Zod schemas with `.describe()`
- **SDK**: `@modelcontextprotocol/sdk` + `elysia-mcp`

**Pattern Types**:

| Type | Purpose | Naming | Example |
|------|---------|--------|---------|
| Tool | Execute actions, call APIs | `verb_noun` | `get_user`, `create_item` |
| Resource | Expose data/files | `protocol://path` | `config://settings` |
| Prompt | Reusable prompt templates | `action` or `action_context` | `summarize`, `code_review` |

**Tool Naming Verbs**: `get` (single by ID) · `list` (multiple) · `search` (query/filter) · `create` (new) · `update` (modify) · `delete` (remove) · `validate` · `convert` · `send` · `run`

<!-- AI-CONTEXT-END -->

## Tool Patterns

### Basic Tool

```typescript
import { z } from 'zod';

server.tool('greet', { name: z.string().describe('Name to greet') },
  async (args) => ({ content: [{ type: 'text', text: `Hello, ${args.name}!` }] })
);
```

### Tool with Optional Parameters and Enums

```typescript
server.tool('search', {
    query: z.string().describe('Search query'),
    status: z.enum(['active', 'inactive', 'pending']).describe('Filter by status'),
    limit: z.number().optional().default(10).describe('Max results'),
    offset: z.number().optional().default(0).describe('Result offset'),
  },
  async (args) => {
    const results = await performSearch(args.query, args.status, args.limit, args.offset);
    return { content: [{ type: 'text', text: JSON.stringify(results, null, 2) }] };
  }
);
```

### Tool with Nested Schema

```typescript
const AddressSchema = z.object({
  street: z.string(), city: z.string(), country: z.string(),
  postal: z.string().optional(),
});

server.tool('create_contact', {
    name: z.string().describe('Contact name'),
    email: z.string().email().describe('Email address'),
    address: AddressSchema.optional().describe('Mailing address'),
  },
  async (args) => ({ content: [{ type: 'text', text: JSON.stringify(await createContact(args)) }] })
);
```

### Tool with Structured Output

```typescript
server.registerTool('calculate', {
    title: 'Calculator',
    description: 'Perform mathematical calculations',
    inputSchema: { expression: z.string().describe('Math expression to evaluate') },
    outputSchema: { result: z.number(), expression: z.string(), timestamp: z.string() },
  },
  async ({ expression }) => {
    const result = evaluate(expression);
    const output = { result, expression, timestamp: new Date().toISOString() };
    return {
      content: [{ type: 'text', text: JSON.stringify(output) }],
      structuredContent: output,
    };
  }
);
```

### Tool with Error Handling

```typescript
server.tool('fetch_data', { url: z.string().url().describe('URL to fetch') },
  async (args) => {
    try {
      const response = await fetch(args.url);
      if (!response.ok) {
        return {
          content: [{ type: 'text', text: JSON.stringify({
            error: true, status: response.status,
            message: `HTTP ${response.status}: ${response.statusText}`,
          }) }],
          isError: true,
        };
      }
      return { content: [{ type: 'text', text: JSON.stringify(await response.json()) }] };
    } catch (error) {
      return {
        content: [{ type: 'text', text: JSON.stringify({
          error: true, message: error instanceof Error ? error.message : 'Unknown error',
        }) }],
        isError: true,
      };
    }
  }
);
```

## Resource Patterns

```typescript
// Static resource
server.resource('README', 'resource://readme', async () => ({
  contents: [{ uri: 'resource://readme', mimeType: 'text/markdown', text: '# My MCP Server\n\n...' }],
}));

// Dynamic (load at request time)
server.resource('Config', 'resource://config', async () => ({
  contents: [{ uri: 'resource://config', mimeType: 'application/json',
    text: JSON.stringify(await loadConfig(), null, 2) }],
}));

// Parameterized URI
server.resource('User Profile', 'resource://user/{id}', async (uri) => {
  const user = await getUser(uri.pathname.split('/').pop());
  return { contents: [{ uri: uri.href, mimeType: 'application/json', text: JSON.stringify(user) }] };
});

// Binary (use blob instead of text)
server.resource('Logo', 'resource://logo.png', async () => ({
  contents: [{ uri: 'resource://logo.png', mimeType: 'image/png',
    blob: (await readFile('./logo.png')).toString('base64') }],
}));
```

## Prompt Patterns

```typescript
// Simple
server.prompt('summarize', 'Summarize the given text',
  { text: z.string().describe('Text to summarize') },
  async (args) => ({
    description: 'Text summarization prompt',
    messages: [{ role: 'user', content: { type: 'text', text: `Please summarize:\n\n${args.text}` } }],
  })
);

// With system message
server.prompt('code_review', 'Review code for issues', {
    code: z.string().describe('Code to review'),
    language: z.string().optional().describe('Programming language'),
  },
  async (args) => ({
    description: 'Code review prompt',
    messages: [
      { role: 'system', content: { type: 'text', text: 'You are an expert code reviewer. Focus on security, performance, and maintainability.' } },
      { role: 'user', content: { type: 'text', text: `Review this ${args.language || 'code'}:\n\n\`\`\`${args.language || ''}\n${args.code}\n\`\`\`` } },
    ],
  })
);

// Conditional messages: use spread to include system message only when context is provided
// ...(args.context ? [{ role: 'system' as const, content: { type: 'text' as const, text: args.context } }] : [])
```

## Naming & Description Best Practices

Use `snake_case` `verb_noun`. Compound: `get_user_with_orders`, `list_active_sessions`, `deploy_to_production`. Avoid: `do_thing`, `process`, `getUser` (camelCase), `tool_get_user` (redundant prefix).

**Tool descriptions** -- state what it does, when to use it, and side effects:

```typescript
// BAD: vague, no side-effect info
server.tool('delete_user', 'Deletes a user', { /* ... */ });

// GOOD: clear purpose, constraints, side effects
server.tool('get_user',
  'Retrieves a user by their unique ID. Returns profile including name, email, role. Returns null if not found. Read-only.',
  { id: z.string().uuid().describe('Unique user identifier (UUID format)') }
);
server.tool('delete_user',
  'Permanently deletes user and all data. IRREVERSIBLE. Requires admin privileges.',
  { id: z.string().uuid().describe('User ID to delete') }
);
server.tool('search_documents',
  'Full-text search across all documents. Use when looking for documents by content rather than by ID. Supports wildcards and phrase matching.',
  {
    query: z.string().describe('Search query (supports * wildcards and "exact phrases")'),
    limit: z.number().min(1).max(100).optional().default(20).describe('Results per page (1-100, default: 20)'),
  }
);
server.tool('send_email',
  'Sends an email to the specified recipient. Cannot be undone once sent.',
  { /* ... */ }
);
```

**Parameter descriptions** -- include constraints and format:

```typescript
// BAD: z.string() (no describe), z.string().describe('Query') (redundant), z.number().describe('Limit') (no constraints)
// GOOD: specific types, constraints, format hints
query: z.string().describe('Search query - supports wildcards (*) and exact phrases ("...")')
limit: z.number().min(1).max(100).optional().default(20).describe('Results per page (1-100, default: 20)')
date: z.string().describe('Date in ISO 8601 format (YYYY-MM-DD)')
email: z.string().email().describe('User email address')
url: z.string().url().describe('Webhook URL')
count: z.number().int().positive().describe('Number of items')
```

**Return structured JSON** (not unstructured text):

```typescript
return { content: [{ type: 'text', text: JSON.stringify({ success: true, data: result }, null, 2) }] };
```

**Handle errors with `isError`** (don't throw -- crashes the tool call). See "Tool with Error Handling" pattern above.
