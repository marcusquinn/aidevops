<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1553: Implement tool execution for Cursor models in OpenCode

**Session origin**: Interactive session 2026-03-22, continuation of t1551 (Cursor proxy)
**Issue**: GH#5457

## What

Enable Cursor models (Composer 2, etc.) to use tools (bash, read, write, edit, grep, ls, glob) in OpenCode via the gRPC proxy.

## Why

The Cursor proxy (t1551) works for text/conversation but tool calling is disabled (`tool_call: false`) because:
- When tools are sent to Cursor, its native tool system activates
- The proxy can't execute Cursor's native tools (read, write, shell, grep)
- The model retries in a loop, causing the request to hang

Without tools, Cursor models are limited to conversation — they can't do coding tasks.

## How

Based on analysis of Nomadcxx/opencode-cursor (working implementation):

### Architecture

OpenCode drives the tool loop, not the proxy:

```
Request 1: User asks "what repo?"
  → Proxy sends to Cursor via gRPC
  → Cursor responds with tool_call (wants bash)
  → Proxy translates to OpenAI tool_calls format
  → OpenCode calls plugin's registered tool handler
  → Handler executes bash locally
  → OpenCode sends Request 2 with tool result
  → Cursor sees result, continues or responds
```

### Implementation steps

1. **Register tool handlers** in `index.mjs` via OpenCode's plugin `tool` hook
   - Use `@opencode-ai/plugin`'s `tool()` function
   - Register: bash, read, write, edit, grep, ls, glob (minimum)
   - Each handler executes locally via `child_process` / `fs`
   - Reference: Nomadcxx `src/tools/defaults.ts`

2. **Re-enable `tool_call: true`** in `cursor-proxy.mjs` `buildCursorProviderModels()`

3. **Strip MCP tools from proxy requests** (already done in v3.1.52)
   - Don't forward OpenAI tools to Cursor as MCP tools
   - Cursor sees tools only in the system prompt (OpenCode includes tool descriptions there)
   - The proxy just translates text/streaming responses

4. **Handle multi-turn messages** with tool results
   - When OpenCode sends a follow-up request with `role: "tool"` messages, the proxy's `parseMessages()` already handles this (lines 309-354 of proxy.js)
   - Verify the tool result is correctly included in the Cursor request

5. **Tool name alias resolution** (from Nomadcxx's 50+ alias map)
   - Cursor models may use variant names like `runcommand` instead of `bash`
   - Port `TOOL_NAME_ALIASES` from `src/proxy/tool-loop.ts`

### Key decision: Don't forward tools to Cursor

The proxy should NOT send tool definitions to Cursor via MCP. Instead:
- OpenCode includes tool descriptions in the system prompt
- Cursor generates text that includes tool call intent
- OpenCode's ai-sdk layer detects the tool call format and calls our handlers
- This avoids Cursor's native tool system entirely

### Files to modify

- `.agents/plugins/opencode-aidevops/index.mjs` — register tool handlers
- `.agents/plugins/opencode-aidevops/cursor-proxy.mjs` — re-enable `tool_call: true`
- `.agents/plugins/opencode-aidevops/cursor/proxy.js` — may need adjustments for tool result handling

### Files to create

- `.agents/plugins/opencode-aidevops/cursor-tools.mjs` — tool handler implementations

## Acceptance criteria

1. Composer 2 can execute `bash` commands in OpenCode (e.g., `git status`)
2. Composer 2 can read files via the `read` tool
3. Composer 2 can write/edit files via `write`/`edit` tools
4. Tool results feed back correctly (multi-turn conversation works)
5. No hang on tool-calling requests
6. Non-tool conversations still work (no regression)

## Context

### Current state (v3.1.52)

| Component | Status |
|-----------|--------|
| Auth (Keychain → pool → proxy) | Working |
| Chat (text/conversation) | Working |
| Streaming (SSE) | Working |
| Model discovery (12 models via gRPC) | Working |
| Tool calling | Disabled (this task) |

### Key files in current codebase

- `cursor/proxy.js:241` — `handleChatCompletion()` — request handler
- `cursor/proxy.js:309` — `parseMessages()` — already handles `role: "tool"` messages
- `cursor/proxy.js:575` — `processServerMessage()` — handles Cursor's gRPC responses
- `cursor/proxy.js:631` — `handleExecMessage()` — rejects Cursor's native tools
- `cursor/proxy.js:287` — MCP tools already stripped (empty array)
- `cursor-proxy.mjs:237` — `tool_call: false` (needs to be `true`)

### Nomadcxx reference files (use `gh api repos/Nomadcxx/opencode-cursor/contents/{path}`)

- `src/tools/defaults.ts` — 10 tool implementations (bash, read, write, edit, grep, ls, glob, mkdir, rm, stat)
- `src/proxy/tool-loop.ts` — tool call extraction, 50+ alias map, OpenAI response formatting
- `src/plugin.ts` — tool handler registration via `tool` hook, `chat.params` hook
- `src/tools/core/registry.ts` — tool handler registry
- `src/tools/schema.ts` — JSON Schema conversion for OpenAI format

### How Nomadcxx registers tool handlers

```typescript
// From src/plugin.ts — simplified
const toolHookEntries = {};
for (const [name, { tool: toolDef, handler }] of localRegistry.entries()) {
  toolHookEntries[name] = tool({
    description: toolDef.description,
    parameters: z.object(toolDef.parameters),
    execute: async (args) => handler(args),
  });
}
return { tool: toolHookEntries, ... };
```

### How OpenCode's plugin tool hook works

The plugin returns `{ tool: { name: tool({...}) } }` from its init function. OpenCode calls these handlers when the model returns `tool_calls` with matching names. The handler receives the parsed arguments and returns a string result.
