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

**Tool Naming Verbs**:

| Verb | Use Case | Examples |
|------|----------|----------|
| `get` | Single item by ID | `get_user`, `get_config` |
| `list` | Multiple items | `list_users`, `list_files` |
| `search` | Query with filters | `search_docs`, `search_logs` |
| `create` | New resource | `create_user`, `create_project` |
| `update` | Modify existing | `update_user`, `update_settings` |
| `delete` | Remove resource | `delete_user`, `delete_file` |
| `validate` | Check validity | `validate_email`, `validate_config` |
| `convert` | Transform format | `convert_currency`, `convert_image` |
| `send` | Transmit data | `send_email`, `send_notification` |
| `run` | Execute process | `run_build`, `run_tests` |

<!-- AI-CONTEXT-END -->

## Tool Patterns

### Basic Tool

```typescript
import { z } from 'zod';

server.tool(
  'greet',
  {
    name: z.string().describe('Name to greet'),
  },
  async (args) => ({
    content: [{ type: 'text', text: `Hello, ${args.name}!` }],
  })
);
```

### Tool with Optional Parameters

```typescript
server.tool(
  'search',
  {
    query: z.string().describe('Search query'),
    limit: z.number().optional().default(10).describe('Max results'),
    offset: z.number().optional().default(0).describe('Result offset'),
  },
  async (args) => {
    const results = await performSearch(args.query, args.limit, args.offset);
    return {
      content: [{ type: 'text', text: JSON.stringify(results, null, 2) }],
    };
  }
);
```

### Tool with Enum Validation

```typescript
server.tool(
  'set_status',
  {
    status: z.enum(['active', 'inactive', 'pending']).describe('New status'),
    reason: z.string().optional().describe('Reason for change'),
  },
  async (args) => {
    await updateStatus(args.status, args.reason);
    return {
      content: [{ type: 'text', text: `Status updated to: ${args.status}` }],
    };
  }
);
```

### Tool with Complex Input

```typescript
const AddressSchema = z.object({
  street: z.string(),
  city: z.string(),
  country: z.string(),
  postal: z.string().optional(),
});

server.tool(
  'create_contact',
  {
    name: z.string().describe('Contact name'),
    email: z.string().email().describe('Email address'),
    phone: z.string().optional().describe('Phone number'),
    address: AddressSchema.optional().describe('Mailing address'),
  },
  async (args) => {
    const contact = await createContact(args);
    return {
      content: [{ type: 'text', text: JSON.stringify(contact) }],
    };
  }
);
```

### Tool with Structured Output

```typescript
server.registerTool(
  'calculate',
  {
    title: 'Calculator',
    description: 'Perform mathematical calculations',
    inputSchema: {
      expression: z.string().describe('Math expression to evaluate'),
    },
    outputSchema: {
      result: z.number(),
      expression: z.string(),
      timestamp: z.string(),
    },
  },
  async ({ expression }) => {
    const result = evaluate(expression);
    const output = {
      result,
      expression,
      timestamp: new Date().toISOString(),
    };
    return {
      content: [{ type: 'text', text: JSON.stringify(output) }],
      structuredContent: output,
    };
  }
);
```

### Tool with Error Handling

```typescript
server.tool(
  'fetch_data',
  {
    url: z.string().url().describe('URL to fetch'),
  },
  async (args) => {
    try {
      const response = await fetch(args.url);
      if (!response.ok) {
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              error: true,
              status: response.status,
              message: `HTTP ${response.status}: ${response.statusText}`,
            }),
          }],
          isError: true,
        };
      }
      const data = await response.json();
      return {
        content: [{ type: 'text', text: JSON.stringify(data) }],
      };
    } catch (error) {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            error: true,
            message: error instanceof Error ? error.message : 'Unknown error',
          }),
        }],
        isError: true,
      };
    }
  }
);
```

## Resource Patterns

### Static Resource

```typescript
server.resource('README', 'resource://readme', async () => ({
  contents: [{
    uri: 'resource://readme',
    mimeType: 'text/markdown',
    text: '# My MCP Server\n\nThis server provides...',
  }],
}));
```

### Dynamic Resource

```typescript
server.resource('Config', 'resource://config', async () => {
  const config = await loadConfig();
  return {
    contents: [{
      uri: 'resource://config',
      mimeType: 'application/json',
      text: JSON.stringify(config, null, 2),
    }],
  };
});
```

### File Resource

```typescript
import { readFile } from 'fs/promises';

server.resource('Schema', 'file://schema.json', async () => {
  const content = await readFile('./schema.json', 'utf-8');
  return {
    contents: [{
      uri: 'file://schema.json',
      mimeType: 'application/json',
      text: content,
    }],
  };
});
```

### Resource with Parameters

```typescript
// Register a resource template
server.resource(
  'User Profile',
  'resource://user/{id}',
  async (uri) => {
    const id = uri.pathname.split('/').pop();
    const user = await getUser(id);
    return {
      contents: [{
        uri: uri.href,
        mimeType: 'application/json',
        text: JSON.stringify(user),
      }],
    };
  }
);
```

### Binary Resource

```typescript
server.resource('Logo', 'resource://logo.png', async () => {
  const buffer = await readFile('./logo.png');
  return {
    contents: [{
      uri: 'resource://logo.png',
      mimeType: 'image/png',
      blob: buffer.toString('base64'),
    }],
  };
});
```

## Prompt Patterns

### Simple Prompt

```typescript
server.prompt(
  'summarize',
  'Summarize the given text',
  {
    text: z.string().describe('Text to summarize'),
  },
  async (args) => ({
    description: 'Text summarization prompt',
    messages: [{
      role: 'user',
      content: { type: 'text', text: `Please summarize:\n\n${args.text}` },
    }],
  })
);
```

### Prompt with System Message

```typescript
server.prompt(
  'code_review',
  'Review code for issues',
  {
    code: z.string().describe('Code to review'),
    language: z.string().optional().describe('Programming language'),
  },
  async (args) => ({
    description: 'Code review prompt',
    messages: [
      {
        role: 'system',
        content: {
          type: 'text',
          text: 'You are an expert code reviewer. Focus on security, performance, and maintainability.',
        },
      },
      {
        role: 'user',
        content: {
          type: 'text',
          text: `Review this ${args.language || 'code'}:\n\n\`\`\`${args.language || ''}\n${args.code}\n\`\`\``,
        },
      },
    ],
  })
);
```

### Prompt with Context

```typescript
server.prompt(
  'analyze_with_context',
  'Analyze data with additional context',
  {
    data: z.string().describe('Data to analyze'),
    context: z.string().optional().describe('Additional context'),
    focus: z.enum(['performance', 'security', 'quality']).describe('Analysis focus'),
  },
  async (args) => ({
    description: `${args.focus} analysis prompt`,
    messages: [
      ...(args.context ? [{
        role: 'system' as const,
        content: { type: 'text' as const, text: args.context },
      }] : []),
      {
        role: 'user',
        content: {
          type: 'text',
          text: `Analyze the following with focus on ${args.focus}:\n\n${args.data}`,
        },
      },
    ],
  })
);
```

## Tool Naming

AI assistants select tools by name and description. Use `snake_case` `verb_noun` format.

### Anti-Patterns

```typescript
// BAD: Vague or generic
'do_thing'        // What thing?
'process'         // Process what?
'handle_data'     // Too generic

// BAD: Wrong casing or redundant prefixes
'getUser'         // Use snake_case, not camelCase
'tool_get_user'   // "tool_" prefix is redundant
'mcp_list_items'  // "mcp_" prefix is redundant

// GOOD: Clear, consistent, descriptive
'get_user'
'list_items'
'search_documents'
```

### Compound Actions

For multi-step or domain-specific operations:

```typescript
'get_user_with_orders'    // Returns user + their orders
'list_active_sessions'    // Filtered list
'search_and_replace'      // Combined action
'deploy_to_production'
'sync_inventory'
'generate_report'
'export_to_csv'
```

## Descriptions & Best Practices

Tool descriptions determine when AI assistants use a tool. Every description should cover: **what** it does, **when** to use it, and **side effects** (if any).

### Tool Descriptions

```typescript
// BAD: Too vague — AI can't determine when to use it
server.tool('get_data', 'Gets data', { /* ... */ });

// BAD: Missing side-effect info
server.tool('delete_user', 'Deletes a user', { /* ... */ });

// GOOD: Clear purpose, behavior, constraints
server.tool(
  'get_user',
  'Retrieves a user by their unique ID. Returns user profile including name, email, and role. Returns null if user not found.',
  { id: z.string().uuid().describe('Unique user identifier (UUID format)') }
);

// GOOD: Documents side effects and irreversibility
server.tool(
  'delete_user',
  'Permanently deletes a user account and all associated data. This action cannot be undone. Requires admin privileges.',
  { id: z.string().uuid().describe('User ID to delete') }
);

// GOOD: Explains when to use (vs alternatives)
server.tool(
  'search_documents',
  'Full-text search across all documents. Use this when looking for documents by content rather than by ID. Supports wildcards and phrase matching.',
  {
    query: z.string().describe('Search query (supports * wildcards and "exact phrases")'),
    limit: z.number().optional().default(20).describe('Maximum results to return'),
  }
);
```

### Parameter Descriptions

```typescript
// BAD
query: z.string()                           // No description
query: z.string().describe('Query')         // Redundant
limit: z.number().describe('Limit')         // Missing constraints

// GOOD
query: z.string().describe('Search query - supports wildcards (*) and exact phrases ("...")')
status: z.enum(['pending', 'active', 'completed']).describe('Filter by status')
limit: z.number().min(1).max(100).optional().default(20)
  .describe('Results per page (1-100, default: 20)')
date: z.string().describe('Date in ISO 8601 format (YYYY-MM-DD)')
user_id: z.string().uuid().describe('ID of the user who owns this resource')
```

### Use Specific Types

```typescript
// BAD — loses validation
email: z.string()
url: z.string()
count: z.number()

// GOOD — validates at schema level
email: z.string().email().describe('User email address')
url: z.string().url().describe('Webhook URL')
count: z.number().int().positive().describe('Number of items')
```

### Return Structured JSON

```typescript
// GOOD — structured, parseable
return {
  content: [{
    type: 'text',
    text: JSON.stringify({ success: true, data: result }, null, 2),
  }],
};

// BAD — unstructured text
return {
  content: [{ type: 'text', text: `Success! Got ${result.length} items` }],
};
```

### Handle Errors with `isError`

```typescript
// GOOD — structured error with isError flag
return {
  content: [{
    type: 'text',
    text: JSON.stringify({ error: true, code: 'NOT_FOUND', message: 'Item not found' }),
  }],
  isError: true,
};

// BAD — throws exception (crashes the tool call)
throw new Error('Item not found');
```

### Document Side Effects

```typescript
// Read-only — no side effects
server.tool('get_user', 'Retrieves user details. Read-only operation.', { /* ... */ });

// Write — modifies state
server.tool('update_user', 'Updates user profile fields. Modifies the user record in the database.', { /* ... */ });

// Destructive — irreversible
server.tool('delete_user', 'Permanently deletes user and all data. IRREVERSIBLE. Requires confirmation.', { /* ... */ });

// External — cannot be undone
server.tool('send_email', 'Sends an email to the specified recipient. Cannot be undone once sent.', { /* ... */ });
```
