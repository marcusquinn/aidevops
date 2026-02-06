---
description: Matrix bot integration for dispatching messages to AI runners
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

# Matrix Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Bridge Matrix chat rooms to aidevops runners via OpenCode
- **Script**: `matrix-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|test|logs]`
- **Config**: `~/.config/aidevops/matrix-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/matrix-bot/`
- **SDK**: `matrix-bot-sdk` (npm, TypeScript, MIT, 245 stars)
- **Requires**: Node.js >= 18, jq, OpenCode server, Matrix homeserver

**Quick start**:

```bash
matrix-dispatch-helper.sh setup          # Interactive wizard
matrix-dispatch-helper.sh map '!room:server' code-reviewer
matrix-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Matrix Room      │     │ Matrix Bot       │     │ OpenCode Server  │
│                  │     │ (Node.js)        │     │                  │
│ User types:      │────▶│ 1. Parse prefix  │────▶│ runner-helper.sh │
│ !ai Review auth  │     │ 2. Check perms   │     │ → AI session     │
│                  │◀────│ 3. Lookup runner  │◀────│ → response       │
│ AI response      │     │ 4. Dispatch      │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

**Message flow**:

1. User sends `!ai <prompt>` in a mapped Matrix room
2. Bot receives message via Matrix sync
3. Bot checks user permissions (allowedUsers config)
4. Bot looks up room-to-runner mapping
5. Bot dispatches prompt to runner via `runner-helper.sh`
6. Runner executes via OpenCode (headless or warm server)
7. Bot posts response back to the Matrix room
8. Bot adds reaction emoji (hourglass while processing, checkmark on success, X on failure)

## Setup

### Prerequisites

1. **Matrix homeserver** - Synapse (recommended), Dendrite, or Conduit
2. **Bot account** - Dedicated Matrix user for the bot
3. **Access token** - Bot's Matrix access token
4. **OpenCode server** - Running locally or remotely
5. **Runners** - At least one runner created via `runner-helper.sh`

### Cloudron Setup (Recommended for Self-Hosted)

Cloudron provides one-click Synapse installation with automatic SSL and updates.

```bash
# 1. Install Synapse on Cloudron
# Dashboard > App Store > Matrix Synapse > Install

# 2. Create bot user
# Synapse Admin Console > Users > Create User
# Username: aibot
# Password: (generate secure password)
# Admin: No (bots don't need admin)

# 3. Get access token
# Login as bot via Element (https://app.element.io)
# Settings > Help & About > Advanced > Access Token
# Copy the token (starts with syt_)

# 4. Configure the bot
matrix-dispatch-helper.sh setup
# Enter: https://matrix.yourdomain.com
# Enter: syt_your_access_token_here
# Enter allowed users (optional)
# Enter default runner (optional)

# 5. Invite bot to rooms
# In Element: Invite @aibot:yourdomain.com to your rooms

# 6. Map rooms to runners
matrix-dispatch-helper.sh map '!roomid:yourdomain.com' code-reviewer

# 7. Start the bot
matrix-dispatch-helper.sh start --daemon
```

### Manual Synapse Setup

```bash
# Register bot user (if registration is closed)
register_new_matrix_user -c /etc/synapse/homeserver.yaml \
  http://localhost:8008 \
  --user aibot --password "secure-password" --no-admin

# Get access token via login API
curl -X POST "https://matrix.example.com/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": "aibot"},
    "password": "secure-password"
  }' | jq -r '.access_token'
```

## Configuration

### Config File

`~/.config/aidevops/matrix-bot.json` (600 permissions):

```json
{
  "homeserverUrl": "https://matrix.example.com",
  "accessToken": "syt_...",
  "allowedUsers": "@admin:example.com,@dev:example.com",
  "defaultRunner": "",
  "roomMappings": {
    "!abc123:example.com": "code-reviewer",
    "!def456:example.com": "seo-analyst",
    "!ghi789:example.com": "ops-monitor"
  },
  "botPrefix": "!ai",
  "ignoreOwnMessages": true,
  "maxPromptLength": 4000,
  "responseTimeout": 600
}
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `homeserverUrl` | (required) | Matrix homeserver URL |
| `accessToken` | (required) | Bot's Matrix access token |
| `allowedUsers` | `""` (all) | Comma-separated list of allowed Matrix user IDs |
| `defaultRunner` | `""` | Runner for unmapped rooms (empty = ignore) |
| `roomMappings` | `{}` | Room ID to runner name mapping |
| `botPrefix` | `!ai` | Command prefix to trigger the bot |
| `ignoreOwnMessages` | `true` | Ignore messages from the bot itself |
| `maxPromptLength` | `4000` | Max response length before truncation |
| `responseTimeout` | `600` | Max seconds to wait for runner response |

## Room-to-Runner Mapping

Each Matrix room maps to exactly one runner. This determines which AI personality and instructions handle messages from that room.

```bash
# Map rooms to runners
matrix-dispatch-helper.sh map '!dev-room:server' code-reviewer
matrix-dispatch-helper.sh map '!seo-room:server' seo-analyst
matrix-dispatch-helper.sh map '!ops-room:server' ops-monitor

# List mappings
matrix-dispatch-helper.sh mappings

# Remove a mapping
matrix-dispatch-helper.sh unmap '!dev-room:server'
```

### Recommended Room Layout

| Room | Runner | Purpose |
|------|--------|---------|
| `#dev:server` | `code-reviewer` | Code review, security analysis |
| `#seo:server` | `seo-analyst` | SEO audits, keyword research |
| `#ops:server` | `ops-monitor` | Server health, deployment status |
| `#general:server` | (default runner) | General AI assistance |

## Usage in Matrix

### Basic Commands

```text
!ai Review src/auth.ts for security vulnerabilities
!ai Generate unit tests for the user registration flow
!ai What are the top 10 keywords for "cloud hosting"?
!ai Check the deployment status of production
```

### Bot Behavior

- **Typing indicator**: Bot shows typing while processing
- **Reactions**: Hourglass while processing, checkmark on success, X on failure
- **Concurrency**: One dispatch per room at a time (prevents flooding)
- **Truncation**: Long responses are truncated with a note about full logs
- **Auto-join**: Bot automatically joins rooms when invited

## Operations

### Start/Stop

```bash
# Start in daemon mode (background)
matrix-dispatch-helper.sh start --daemon

# Start in foreground (for debugging)
matrix-dispatch-helper.sh start

# Stop the bot
matrix-dispatch-helper.sh stop

# Check status
matrix-dispatch-helper.sh status
```

### Monitoring

```bash
# View latest logs
matrix-dispatch-helper.sh logs

# Follow logs in real-time
matrix-dispatch-helper.sh logs --follow

# View more history
matrix-dispatch-helper.sh logs --tail 200
```

### Testing

```bash
# Test dispatch without Matrix (directly to runner)
matrix-dispatch-helper.sh test code-reviewer "Review src/auth.ts"

# Test room mapping resolution
matrix-dispatch-helper.sh test '!abc123:server' "Test message"
```

## Integration with Runners

The bot dispatches to runners via `runner-helper.sh`, which handles:

- Runner AGENTS.md (personality/instructions)
- OpenCode session management
- Memory namespace isolation
- Mailbox integration (status reports)
- Run logging

```bash
# Create runners for Matrix rooms
runner-helper.sh create code-reviewer \
  --description "Reviews code for security and quality"

runner-helper.sh create seo-analyst \
  --description "SEO analysis and keyword research"

# Edit runner instructions
runner-helper.sh edit code-reviewer
```

## Security

1. **Access token**: Stored in config file with 600 permissions
2. **User allowlist**: Restrict which Matrix users can trigger the bot
3. **Room mapping**: Only mapped rooms can dispatch to runners
4. **No admin access**: Bot account should not have Synapse admin privileges
5. **Network**: OpenCode server should be localhost-only unless secured
6. **Concurrency**: One dispatch per room prevents resource exhaustion

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not responding | Check `matrix-dispatch-helper.sh status` and logs |
| "Not mapped" error | Map the room: `matrix-dispatch-helper.sh map '!room:server' runner` |
| Runner dispatch fails | Ensure OpenCode server is running: `opencode serve` |
| Access denied | Check `allowedUsers` in config |
| Bot not joining rooms | Invite the bot user to the room via Element |
| Stale PID file | Run `matrix-dispatch-helper.sh stop` to clean up |

## Related

- `scripts/runner-helper.sh` - Runner management
- `scripts/cron-dispatch.sh` - Cron-triggered dispatch (similar pattern)
- `tools/ai-assistants/headless-dispatch.md` - Headless dispatch patterns
- `tools/ai-assistants/opencode-server.md` - OpenCode server API
- `tools/ai-assistants/openclaw.md` - Alternative: OpenClaw multi-channel bot
- `services/hosting/cloudron.md` - Cloudron platform for hosting Synapse
