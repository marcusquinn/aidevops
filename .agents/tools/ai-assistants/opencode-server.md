---
description: OpenCode server mode for programmatic AI interaction
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

# OpenCode Server Mode

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Start server**: `opencode serve [--port 4096] [--hostname 127.0.0.1]`
- **SDK**: `npm install @opencode-ai/sdk`
- **API spec**: `http://localhost:4096/doc`
- **Auth**: `OPENCODE_SERVER_PASSWORD=xxx opencode serve`
- **Key endpoints**: `/session`, `/session/:id/prompt_async`, `/event` (SSE)
- **Use cases**: Parallel agents, voice dispatch, automated testing, CI/CD integration

<!-- AI-CONTEXT-END -->

OpenCode server mode (`opencode serve`) exposes an HTTP API for programmatic interaction with AI sessions. This enables parallel agent orchestration, voice dispatch, automated testing, and custom integrations.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    OpenCode Server                          │
│                   (opencode serve)                          │
├─────────────────────────────────────────────────────────────┤
│  HTTP API (OpenAPI 3.1)                                     │
│  ├── /session          - Session management                 │
│  ├── /session/:id/message - Sync prompts (wait for reply)   │
│  ├── /session/:id/prompt_async - Async prompts (fire+forget)│
│  ├── /event            - SSE stream for real-time events    │
│  └── /tui/*            - TUI control (if running)           │
├─────────────────────────────────────────────────────────────┤
│  Clients                                                    │
│  ├── TUI (opencode)    - Default terminal interface         │
│  ├── SDK               - @opencode-ai/sdk (TypeScript)      │
│  ├── curl/HTTP         - Direct API calls                   │
│  └── Custom apps       - Voice, chat bots, CI/CD            │
└─────────────────────────────────────────────────────────────┘
```

## Starting the Server

```bash
opencode serve                                                    # default (port 4096, localhost)
opencode serve --port 8080 --hostname 0.0.0.0                    # custom port/hostname
opencode serve --mdns                                             # mDNS discovery
opencode serve --cors http://localhost:5173                       # CORS for browser clients
OPENCODE_SERVER_PASSWORD=secret opencode serve                   # with auth
OPENCODE_SERVER_USERNAME=admin OPENCODE_SERVER_PASSWORD=secret opencode serve
opencode --port 4096 --hostname 127.0.0.1                        # alongside TUI (fixed port)
```

## TypeScript SDK

```bash
npm install @opencode-ai/sdk
```

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"

// Option 1: Start server + client together
const { client, server } = await createOpencode({
  port: 4096,
  hostname: "127.0.0.1",
  config: { model: "anthropic/claude-sonnet-4-6" },
})

// Option 2: Connect to existing server
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

// Session management
const session = await client.session.create({ body: { title: "My automated task" } })
const sessions = await client.session.list()
await client.session.delete({ path: { id: session.data.id } })

// Synchronous prompt (waits for full response)
const result = await client.session.prompt({
  path: { id: session.data.id },
  body: {
    model: { providerID: "anthropic", modelID: "claude-sonnet-4-6" },
    parts: [{ type: "text", text: "Explain this codebase structure" }],
  },
})
console.log(result.data.parts)

// Asynchronous prompt (fire and forget — returns 204, monitor via SSE)
await client.session.promptAsync({
  path: { id: session.data.id },
  body: { parts: [{ type: "text", text: "Run the test suite" }] },
})

// Context injection (no AI response triggered)
await client.session.prompt({
  path: { id: session.data.id },
  body: {
    noReply: true,
    parts: [{ type: "text", text: "Context: This project uses TypeScript and Bun runtime." }],
  },
})

// Real-time events (SSE)
const events = await client.event.subscribe()
for await (const event of events.stream) {
  switch (event.type) {
    case "session.message": console.log("New message:", event.properties); break
    case "session.status":  console.log("Status change:", event.properties); break
    case "tool.call":       console.log("Tool invoked:", event.properties); break
  }
}
```

## Direct HTTP API

```bash
# Create session
curl -X POST http://localhost:4096/session \
  -H "Content-Type: application/json" \
  -d '{"title": "API Test Session"}'

# Send prompt (sync)
curl -X POST http://localhost:4096/session/{session_id}/message \
  -H "Content-Type: application/json" \
  -d '{"model":{"providerID":"anthropic","modelID":"claude-sonnet-4-6"},"parts":[{"type":"text","text":"Hello!"}]}'

# Send prompt (async — returns 204 immediately)
curl -X POST http://localhost:4096/session/{session_id}/prompt_async \
  -H "Content-Type: application/json" \
  -d '{"parts":[{"type":"text","text":"Run tests in background"}]}'

# Subscribe to events (SSE)
curl -N http://localhost:4096/event

# Execute slash command
curl -X POST http://localhost:4096/session/{session_id}/command \
  -H "Content-Type: application/json" \
  -d '{"command":"remember","arguments":"This pattern worked for async processing"}'

# Run shell command
curl -X POST http://localhost:4096/session/{session_id}/shell \
  -H "Content-Type: application/json" \
  -d '{"agent":"default","command":"npm test"}'
```

## Use Cases for aidevops

### 1. Parallel Agent Orchestration

```typescript
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

const [codeReview, docGen, testGen] = await Promise.all([
  client.session.create({ body: { title: "Code Review" } }),
  client.session.create({ body: { title: "Documentation" } }),
  client.session.create({ body: { title: "Test Generation" } }),
])

await Promise.all([
  client.session.promptAsync({ path: { id: codeReview.data.id },
    body: { parts: [{ type: "text", text: "Review src/auth.ts for security issues" }] } }),
  client.session.promptAsync({ path: { id: docGen.data.id },
    body: { parts: [{ type: "text", text: "Generate API documentation for src/api/" }] } }),
  client.session.promptAsync({ path: { id: testGen.data.id },
    body: { parts: [{ type: "text", text: "Generate unit tests for src/utils/" }] } }),
])
```

### 2. Voice Dispatch (VoiceInk/iOS Shortcut)

```bash
#!/bin/bash
# voice-dispatch.sh - Called by VoiceInk or iOS Shortcut
TRANSCRIPTION="$1"
SESSION_ID="${OPENCODE_SESSION_ID:-default}"
curl -X POST "http://localhost:4096/session/$SESSION_ID/prompt_async" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": \"$TRANSCRIPTION\"}]}"
```

### 3. Automated Agent Testing

```typescript
async function testAgentChange(testPrompt: string, expectedPattern: RegExp) {
  const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })
  const session = await client.session.create({ body: { title: `Test: ${Date.now()}` } })
  try {
    const result = await client.session.prompt({
      path: { id: session.data.id },
      body: { parts: [{ type: "text", text: testPrompt }] },
    })
    const responseText = result.data.parts.filter((p) => p.type === "text").map((p) => p.text).join("\n")
    return { passed: expectedPattern.test(responseText), response: responseText }
  } finally {
    await client.session.delete({ path: { id: session.data.id } })
  }
}
```

### 4. Self-Improving Agent Loop

Pattern: Review phase (analyze memory for failure patterns) → Refine phase (generate improvements in isolated session) → Test phase (validate against test prompts) → PR phase (create PR if tests pass, with privacy filter). Use `client.session.command` with `/recall` and `/remember` for memory access.

### 5. CI/CD Integration

```bash
# In GitHub Actions: start server, create session, send review prompt, post comment
opencode serve --port 4096 &
sleep 5
SESSION=$(curl -s -X POST http://localhost:4096/session \
  -H "Content-Type: application/json" -d '{"title":"PR Review"}' | jq -r '.id')
curl -X POST "http://localhost:4096/session/$SESSION/message" \
  -H "Content-Type: application/json" \
  -d '{"parts":[{"type":"text","text":"Review the changes in this PR for security issues. Output as markdown."}]}' \
  | jq -r '.parts[0].text' > review.md
# Then post review.md as a PR comment via actions/github-script
```

## API Reference

### Session Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/session` | List all sessions |
| `POST` | `/session` | Create new session |
| `GET` | `/session/:id` | Get session details |
| `DELETE` | `/session/:id` | Delete session |
| `PATCH` | `/session/:id` | Update session (title) |
| `POST` | `/session/:id/message` | Send prompt (sync) |
| `POST` | `/session/:id/prompt_async` | Send prompt (async) |
| `POST` | `/session/:id/command` | Execute slash command |
| `POST` | `/session/:id/shell` | Run shell command |
| `POST` | `/session/:id/abort` | Abort running session |
| `POST` | `/session/:id/fork` | Fork session at message |
| `GET` | `/session/:id/diff` | Get session file changes |
| `GET` | `/session/:id/todo` | Get session todo list |

### Global / File Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/global/health` | Server health check |
| `GET` | `/event` | SSE event stream |
| `GET` | `/doc` | OpenAPI 3.1 spec |
| `GET` | `/find?pattern=<pat>` | Search text in files |
| `GET` | `/find/file?query=<q>` | Find files by name |
| `GET` | `/file/content?path=<p>` | Read file content |

### TUI Control (when TUI is running)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/tui/append-prompt` | Add text to prompt |
| `POST` | `/tui/submit-prompt` | Submit current prompt |
| `POST` | `/tui/clear-prompt` | Clear prompt |
| `POST` | `/tui/execute-command` | Run command |
| `POST` | `/tui/show-toast` | Show notification |

## Integration with aidevops

```typescript
// Store/recall memories via slash command
await client.session.command({ path: { id: sessionId },
  body: { command: "remember", arguments: "WORKING_SOLUTION: Use --no-verify for emergency hotfixes" } })
await client.session.command({ path: { id: sessionId },
  body: { command: "recall", arguments: "--type WORKING_SOLUTION --recent 10" } })
```

```bash
# Mailbox dispatch to parallel agents
mail-helper.sh send --to "code-reviewer" --type "task_dispatch" \
  --subject "Review PR #123" --body "Review security implications of auth changes"
```

```typescript
// Pre-edit check before file modifications in automated sessions
const preCheck = await client.session.shell({ path: { id: sessionId },
  body: { agent: "default", command: "~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode" } })
```

## Security Considerations

1. **Network exposure**: Use `--hostname 127.0.0.1` (default) for local-only access
2. **Authentication**: Always set `OPENCODE_SERVER_PASSWORD` when exposing to network
3. **CORS**: Only allow trusted origins with `--cors`
4. **Credentials**: Never pass secrets in prompts — use environment variables
5. **Session cleanup**: Delete sessions after use to prevent data leakage

## Troubleshooting

```bash
lsof -i :4096                          # check if port is in use
pkill -f "opencode serve"              # kill existing process
curl http://localhost:4096/global/health  # verify server is running
```

SDK timeout: pass `timeout: 30000` to `createOpencode({ timeout: 30000 })`.

## Related Documentation

- `tools/ai-assistants/overview.md` - AI assistant comparison
- `workflows/git-workflow.md` - Git workflow integration
- `reference/memory.md` - Memory system documentation
- OpenCode SDK docs: `https://opencode.ai/docs/sdk/`
- OpenCode Server docs: `https://opencode.ai/docs/server/`
