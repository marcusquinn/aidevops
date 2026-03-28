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

## Architecture

```text
OpenCode Server (opencode serve)
├── HTTP API (OpenAPI 3.1)
│   ├── /session              Session management
│   ├── /session/:id/message  Sync prompts (wait for reply)
│   ├── /session/:id/prompt_async  Async prompts (fire+forget)
│   ├── /event                SSE stream for real-time events
│   └── /tui/*                TUI control (if running)
└── Clients: TUI, SDK (@opencode-ai/sdk), curl/HTTP, custom apps
```

## Starting the Server

```bash
opencode serve                                    # default (port 4096, localhost)
opencode serve --port 8080 --hostname 0.0.0.0     # custom port/hostname
opencode serve --mdns                              # mDNS discovery
opencode serve --cors http://localhost:5173        # CORS for browser clients
OPENCODE_SERVER_PASSWORD=secret opencode serve    # with auth
OPENCODE_SERVER_USERNAME=admin OPENCODE_SERVER_PASSWORD=secret opencode serve
opencode --port 4096 --hostname 127.0.0.1         # alongside TUI (fixed port)
```

## TypeScript SDK (`npm install @opencode-ai/sdk`)

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"

// Option A: Start server + client together
const { client, server } = await createOpencode({
  port: 4096, hostname: "127.0.0.1",
  config: { model: "anthropic/claude-sonnet-4-6" },
})
// Option B: Connect to existing server
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

// Session lifecycle
const session = await client.session.create({ body: { title: "My automated task" } })
await client.session.list()
await client.session.delete({ path: { id: session.data.id } })

// Sync prompt (waits for response)
const result = await client.session.prompt({
  path: { id: session.data.id },
  body: {
    model: { providerID: "anthropic", modelID: "claude-sonnet-4-6" },
    parts: [{ type: "text", text: "Explain this codebase structure" }],
  },
})

// Async prompt (fire+forget — returns 204, monitor via SSE)
await client.session.promptAsync({
  path: { id: session.data.id },
  body: { parts: [{ type: "text", text: "Run the test suite" }] },
})

// Context injection (noReply: true — no AI response triggered)
await client.session.prompt({ path: { id: session.data.id },
  body: { noReply: true, parts: [{ type: "text", text: "Context: TypeScript + Bun runtime." }] },
})

// SSE events
for await (const event of (await client.event.subscribe()).stream) {
  // event.type: "session.message" | "session.status" | "tool.call"
  console.log(event.type, event.properties)
}

// Slash commands, shell, pre-edit check (aidevops integration)
await client.session.command({ path: { id: session.data.id },
  body: { command: "remember", arguments: "WORKING_SOLUTION: Use --no-verify for hotfixes" } })
await client.session.command({ path: { id: session.data.id },
  body: { command: "recall", arguments: "--type WORKING_SOLUTION --recent 10" } })
await client.session.shell({ path: { id: session.data.id },
  body: { agent: "default", command: "~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode" } })
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

# Subscribe to events (SSE) | Execute slash command | Run shell command
curl -N http://localhost:4096/event
curl -X POST http://localhost:4096/session/{session_id}/command \
  -H "Content-Type: application/json" \
  -d '{"command":"remember","arguments":"This pattern worked for async processing"}'
curl -X POST http://localhost:4096/session/{session_id}/shell \
  -H "Content-Type: application/json" \
  -d '{"agent":"default","command":"npm test"}'
```

## Use Cases

### Parallel Agent Orchestration

Create multiple sessions, dispatch async prompts concurrently via `Promise.all`:

```typescript
const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })
const [review, docs, tests] = await Promise.all([
  client.session.create({ body: { title: "Code Review" } }),
  client.session.create({ body: { title: "Documentation" } }),
  client.session.create({ body: { title: "Test Generation" } }),
])
await Promise.all([
  client.session.promptAsync({ path: { id: review.data.id },
    body: { parts: [{ type: "text", text: "Review src/auth.ts for security issues" }] } }),
  client.session.promptAsync({ path: { id: docs.data.id },
    body: { parts: [{ type: "text", text: "Generate API docs for src/api/" }] } }),
  client.session.promptAsync({ path: { id: tests.data.id },
    body: { parts: [{ type: "text", text: "Generate unit tests for src/utils/" }] } }),
])
```

### Voice Dispatch (VoiceInk/iOS Shortcut)

```bash
#!/bin/bash
# voice-dispatch.sh - Called by VoiceInk or iOS Shortcut
curl -X POST "http://localhost:4096/session/${OPENCODE_SESSION_ID:-default}/prompt_async" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": \"$1\"}]}"
```

### Automated Agent Testing

```typescript
async function testAgentChange(prompt: string, expected: RegExp) {
  const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })
  const session = await client.session.create({ body: { title: `Test: ${Date.now()}` } })
  try {
    const result = await client.session.prompt({
      path: { id: session.data.id },
      body: { parts: [{ type: "text", text: prompt }] },
    })
    const text = result.data.parts.filter((p) => p.type === "text").map((p) => p.text).join("\n")
    return { passed: expected.test(text), response: text }
  } finally { await client.session.delete({ path: { id: session.data.id } }) }
}
```

### Self-Improving Agent Loop

Pattern: Review (analyze memory for failure patterns) → Refine (generate improvements in isolated session) → Test (validate against test prompts) → PR (create if tests pass, with privacy filter). Use `client.session.command` with `/recall` and `/remember`.

### CI/CD Integration (GitHub Actions)

```bash
opencode serve --port 4096 &
sleep 5
SESSION=$(curl -s -X POST http://localhost:4096/session \
  -H "Content-Type: application/json" -d '{"title":"PR Review"}' | jq -r '.id')
curl -X POST "http://localhost:4096/session/$SESSION/message" \
  -H "Content-Type: application/json" \
  -d '{"parts":[{"type":"text","text":"Review this PR for security issues. Output as markdown."}]}' \
  | jq -r '.parts[0].text' > review.md
# Post review.md as PR comment via actions/github-script
```

## API Reference

Full spec at `http://localhost:4096/doc`. Key endpoints:

| Method | Path | Description |
|--------|------|-------------|
| `GET/POST` | `/session` | List / create sessions |
| `GET/DELETE/PATCH` | `/session/:id` | Get / delete / update session |
| `POST` | `/session/:id/message` | Send prompt (sync) |
| `POST` | `/session/:id/prompt_async` | Send prompt (async) |
| `POST` | `/session/:id/command` | Execute slash command |
| `POST` | `/session/:id/shell` | Run shell command |
| `POST` | `/session/:id/abort` | Abort running session |
| `POST` | `/session/:id/fork` | Fork session at message |
| `GET` | `/session/:id/diff` | Session file changes |
| `GET` | `/session/:id/todo` | Session todo list |
| `GET` | `/global/health` | Health check |
| `GET` | `/event` | SSE event stream |
| `GET` | `/doc` | OpenAPI 3.1 spec |
| `GET` | `/find?pattern=<pat>` | Search text in files |
| `GET` | `/find/file?query=<q>` | Find files by name |
| `GET` | `/file/content?path=<p>` | Read file content |
| `POST` | `/tui/*` | TUI control: `append-prompt`, `submit-prompt`, `clear-prompt`, `execute-command`, `show-toast` |

## Mailbox Dispatch

```bash
mail-helper.sh send --to "code-reviewer" --type "task_dispatch" \
  --subject "Review PR #123" --body "Review security implications of auth changes"
```

## Security

1. **Network**: `--hostname 127.0.0.1` (default) for local-only access
2. **Auth**: Always set `OPENCODE_SERVER_PASSWORD` when exposing to network
3. **CORS**: Only allow trusted origins with `--cors`
4. **Credentials**: Never pass secrets in prompts — use environment variables
5. **Cleanup**: Delete sessions after use to prevent data leakage

## Troubleshooting

```bash
lsof -i :4096                          # check if port is in use
pkill -f "opencode serve"              # kill existing process
curl http://localhost:4096/global/health  # verify server is running
```

SDK timeout: `createOpencode({ timeout: 30000 })`.

## Related

- `tools/ai-assistants/overview.md` — AI assistant comparison
- `workflows/git-workflow.md` — Git workflow integration
- `reference/memory.md` — Memory system documentation
- OpenCode SDK: `https://opencode.ai/docs/sdk/`
- OpenCode Server: `https://opencode.ai/docs/server/`
