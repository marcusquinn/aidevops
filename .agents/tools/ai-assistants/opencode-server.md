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

### Standalone Server

```bash
# Default (port 4096, localhost only)
opencode serve

# Custom port and hostname
opencode serve --port 8080 --hostname 0.0.0.0

# With mDNS discovery (for local network)
opencode serve --mdns

# With CORS for browser clients
opencode serve --cors http://localhost:5173 --cors https://app.example.com
```

### With Authentication

```bash
# Basic auth (recommended for network exposure)
OPENCODE_SERVER_PASSWORD=your-secure-password opencode serve

# Custom username
OPENCODE_SERVER_USERNAME=admin OPENCODE_SERVER_PASSWORD=secret opencode serve
```

### Alongside TUI

When you run `opencode` (TUI), it automatically starts a server on a random port. You can specify a fixed port:

```bash
opencode --port 4096 --hostname 127.0.0.1
```

## TypeScript SDK

### Installation

```bash
npm install @opencode-ai/sdk
```

### Creating a Client

```typescript
import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"

// Option 1: Start server + client together
const { client, server } = await createOpencode({
  port: 4096,
  hostname: "127.0.0.1",
  config: {
    model: "anthropic/claude-sonnet-4-20250514",
  },
})

// Option 2: Connect to existing server
const client = createOpencodeClient({
  baseUrl: "http://localhost:4096",
})
```

### Session Management

```typescript
// Create a new session
const session = await client.session.create({
  body: { title: "My automated task" },
})

// List all sessions
const sessions = await client.session.list()

// Get session details
const details = await client.session.get({
  path: { id: session.data.id },
})

// Delete a session
await client.session.delete({
  path: { id: session.data.id },
})
```

### Sending Prompts

```typescript
// Synchronous prompt (waits for full response)
const result = await client.session.prompt({
  path: { id: session.data.id },
  body: {
    model: {
      providerID: "anthropic",
      modelID: "claude-sonnet-4-20250514",
    },
    parts: [{ type: "text", text: "Explain this codebase structure" }],
  },
})

console.log(result.data.parts) // AI response parts

// Asynchronous prompt (fire and forget)
await client.session.promptAsync({
  path: { id: session.data.id },
  body: {
    parts: [{ type: "text", text: "Run the test suite" }],
  },
})
// Returns 204 No Content immediately
// Monitor via SSE events
```

### Context Injection (No Reply)

```typescript
// Inject context without triggering AI response
await client.session.prompt({
  path: { id: session.data.id },
  body: {
    noReply: true,
    parts: [
      {
        type: "text",
        text: "Context: This project uses TypeScript and Bun runtime.",
      },
    ],
  },
})
```

### Real-Time Events (SSE)

```typescript
// Subscribe to server events
const events = await client.event.subscribe()

for await (const event of events.stream) {
  switch (event.type) {
    case "session.message":
      console.log("New message:", event.properties)
      break
    case "session.status":
      console.log("Status change:", event.properties)
      break
    case "tool.call":
      console.log("Tool invoked:", event.properties)
      break
  }
}
```

## Direct HTTP API

### Create Session

```bash
curl -X POST http://localhost:4096/session \
  -H "Content-Type: application/json" \
  -d '{"title": "API Test Session"}'
```

### Send Prompt (Sync)

```bash
curl -X POST http://localhost:4096/session/{session_id}/message \
  -H "Content-Type: application/json" \
  -d '{
    "model": {
      "providerID": "anthropic",
      "modelID": "claude-sonnet-4-20250514"
    },
    "parts": [{"type": "text", "text": "Hello!"}]
  }'
```

### Send Prompt (Async)

```bash
curl -X POST http://localhost:4096/session/{session_id}/prompt_async \
  -H "Content-Type: application/json" \
  -d '{
    "parts": [{"type": "text", "text": "Run tests in background"}]
  }'
# Returns 204 immediately
```

### Subscribe to Events

```bash
curl -N http://localhost:4096/event
# SSE stream - first event is server.connected
```

### Execute Slash Command

```bash
curl -X POST http://localhost:4096/session/{session_id}/command \
  -H "Content-Type: application/json" \
  -d '{
    "command": "remember",
    "arguments": "This pattern worked for async processing"
  }'
```

### Run Shell Command

```bash
curl -X POST http://localhost:4096/session/{session_id}/shell \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "default",
    "command": "npm test"
  }'
```

## Use Cases for aidevops

### 1. Parallel Agent Orchestration

Run multiple AI sessions concurrently for different tasks:

```typescript
import { createOpencodeClient } from "@opencode-ai/sdk"

const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

// Create parallel sessions for different tasks
const [codeReview, docGen, testGen] = await Promise.all([
  client.session.create({ body: { title: "Code Review" } }),
  client.session.create({ body: { title: "Documentation" } }),
  client.session.create({ body: { title: "Test Generation" } }),
])

// Dispatch tasks in parallel
await Promise.all([
  client.session.promptAsync({
    path: { id: codeReview.data.id },
    body: { parts: [{ type: "text", text: "Review src/auth.ts for security issues" }] },
  }),
  client.session.promptAsync({
    path: { id: docGen.data.id },
    body: { parts: [{ type: "text", text: "Generate API documentation for src/api/" }] },
  }),
  client.session.promptAsync({
    path: { id: testGen.data.id },
    body: { parts: [{ type: "text", text: "Generate unit tests for src/utils/" }] },
  }),
])
```

### 2. Voice Dispatch (VoiceInk/iOS Shortcut)

Send voice transcriptions to OpenCode:

```bash
#!/bin/bash
# voice-dispatch.sh - Called by VoiceInk or iOS Shortcut

TRANSCRIPTION="$1"
SESSION_ID="${OPENCODE_SESSION_ID:-default}"
SERVER="http://localhost:4096"

curl -X POST "$SERVER/session/$SESSION_ID/prompt_async" \
  -H "Content-Type: application/json" \
  -d "{\"parts\": [{\"type\": \"text\", \"text\": \"$TRANSCRIPTION\"}]}"
```

### 3. Automated Agent Testing

Test agent changes in isolated sessions:

```typescript
async function testAgentChange(testPrompt: string, expectedPattern: RegExp) {
  const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

  // Create isolated test session
  const session = await client.session.create({
    body: { title: `Test: ${Date.now()}` },
  })

  try {
    // Send test prompt
    const result = await client.session.prompt({
      path: { id: session.data.id },
      body: {
        parts: [{ type: "text", text: testPrompt }],
      },
    })

    // Extract text from response
    const responseText = result.data.parts
      .filter((p) => p.type === "text")
      .map((p) => p.text)
      .join("\n")

    // Validate response
    const passed = expectedPattern.test(responseText)
    return { passed, response: responseText }
  } finally {
    // Cleanup
    await client.session.delete({ path: { id: session.data.id } })
  }
}
```

### 4. Self-Improving Agent Loop

Query memory, generate improvements, test in isolated session:

```typescript
async function selfImproveLoop() {
  const client = createOpencodeClient({ baseUrl: "http://localhost:4096" })

  // 1. Review phase - analyze memory for patterns
  const reviewSession = await client.session.create({
    body: { title: "Self-Improve: Review" },
  })

  const analysis = await client.session.prompt({
    path: { id: reviewSession.data.id },
    body: {
      parts: [
        {
          type: "text",
          text: `Analyze recent memory entries for failure patterns:
          
/recall --type FAILURE --recent 20

Identify gaps where we failed but don't have solutions.
Output as JSON: { gaps: [{ pattern, frequency, suggestion }] }`,
        },
      ],
    },
  })

  // 2. Refine phase - generate improvements
  const refineSession = await client.session.create({
    body: { title: "Self-Improve: Refine" },
  })

  const improvements = await client.session.prompt({
    path: { id: refineSession.data.id },
    body: {
      parts: [
        {
          type: "text",
          text: `Based on these gaps, propose agent improvements:
${JSON.stringify(analysis.data)}

Generate specific edits to agent files. Use worktree isolation.`,
        },
      ],
    },
  })

  // 3. Test phase - validate in isolated session
  const testSession = await client.session.create({
    body: { title: "Self-Improve: Test" },
  })

  // Run test prompts against improved agents...

  // 4. PR phase - create PR if tests pass (with privacy filter)
}
```

### 5. CI/CD Integration

Trigger AI analysis from GitHub Actions:

```yaml
# .github/workflows/ai-review.yml
name: AI Code Review

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start OpenCode Server
        run: |
          opencode serve --port 4096 &
          sleep 5

      - name: Run AI Review
        run: |
          SESSION=$(curl -s -X POST http://localhost:4096/session \
            -H "Content-Type: application/json" \
            -d '{"title": "PR Review"}' | jq -r '.id')

          curl -X POST "http://localhost:4096/session/$SESSION/message" \
            -H "Content-Type: application/json" \
            -d '{
              "parts": [{
                "type": "text",
                "text": "Review the changes in this PR for security issues and code quality. Output as markdown."
              }]
            }' | jq -r '.parts[0].text' > review.md

      - name: Post Review Comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs')
            const review = fs.readFileSync('review.md', 'utf8')
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: review
            })
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

### Global Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/global/health` | Server health check |
| `GET` | `/event` | SSE event stream |
| `GET` | `/doc` | OpenAPI 3.1 spec |

### File Endpoints

| Method | Path | Description |
|--------|------|-------------|
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

### Memory System

Use the server API to store/recall memories programmatically:

```typescript
// Store a memory via slash command
await client.session.command({
  path: { id: sessionId },
  body: {
    command: "remember",
    arguments: "WORKING_SOLUTION: Use --no-verify for emergency hotfixes",
  },
})

// Recall memories
await client.session.command({
  path: { id: sessionId },
  body: {
    command: "recall",
    arguments: "--type WORKING_SOLUTION --recent 10",
  },
})
```

### Mailbox System

Dispatch tasks to parallel agents via mailbox:

```bash
# Send task to another agent session
mail-helper.sh send \
  --to "code-reviewer" \
  --type "task_dispatch" \
  --subject "Review PR #123" \
  --body "Review security implications of auth changes"
```

### Pre-Edit Check

Always run pre-edit check before file modifications:

```typescript
// Before any file edits in automated sessions
const preCheck = await client.session.shell({
  path: { id: sessionId },
  body: {
    agent: "default",
    command: "~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode",
  },
})
```

## Security Considerations

1. **Network exposure**: Use `--hostname 127.0.0.1` (default) for local-only access
2. **Authentication**: Always set `OPENCODE_SERVER_PASSWORD` when exposing to network
3. **CORS**: Only allow trusted origins with `--cors`
4. **Credentials**: Never pass secrets in prompts - use environment variables
5. **Session cleanup**: Delete sessions after use to prevent data leakage

## Troubleshooting

### Server won't start

```bash
# Check if port is in use
lsof -i :4096

# Kill existing process
pkill -f "opencode serve"
```

### Connection refused

```bash
# Verify server is running
curl http://localhost:4096/global/health

# Check firewall (macOS)
sudo pfctl -s rules | grep 4096
```

### SDK timeout

```typescript
// Increase timeout for long operations
const { client } = await createOpencode({
  timeout: 30000, // 30 seconds
})
```

## Related Documentation

- [OpenCode CLI](/docs/cli/) - Command-line interface
- [OpenCode SDK](https://opencode.ai/docs/sdk/) - Official SDK documentation
- [OpenCode Server](https://opencode.ai/docs/server/) - Full API reference
- `tools/ai-assistants/overview.md` - AI assistant comparison
- `workflows/git-workflow.md` - Git workflow integration
- `memory/README.md` - Memory system documentation
