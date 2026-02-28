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

- **Purpose**: Bridge Matrix chat rooms to aidevops runners via OpenCode with entity-aware context
- **Script**: `matrix-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|sessions|test|logs]`
- **Config**: `~/.config/aidevops/matrix-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/matrix-bot/`
- **Session DB**: `~/.aidevops/.agent-workspace/memory/memory.db` (shared entity tables, SQLite WAL)
- **Entity helper**: `entity-helper.sh` (identity resolution, Layer 0/1 interaction logging)
- **SDK**: `matrix-bot-sdk`, `better-sqlite3` (npm)
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
│                  │◀────│ 3. Resolve entity │◀────│ → response       │
│ AI response      │     │ 4. Load context  │     │                  │
│                  │     │ 5. Dispatch      │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │ memory.db (shared)   │
                    │ ├── entities         │  Layer 2: Entity profiles
                    │ ├── entity_channels  │  Cross-channel identity
                    │ ├── interactions     │  Layer 0: Immutable log
                    │ ├── conversations    │  Layer 1: Context summaries
                    │ └── matrix_room_     │  Room-to-entity mapping
                    │     sessions         │
                    └──────────────────────┘
```

**Message flow**:

1. User sends `!ai <prompt>` in a mapped Matrix room
2. Bot receives message via Matrix sync
3. Bot checks user permissions (allowedUsers config)
4. Bot looks up room-to-runner mapping
5. **Entity resolution**: Bot resolves Matrix user ID (`@user:server`) to an entity via `entity-helper.sh` (creates entity if new)
6. **Layer 0 logging**: Bot logs the user message as an immutable interaction (append-only, never deleted)
7. **Context loading**: Bot loads entity profile (preferences, communication style) + conversation summary + recent interactions
8. **Privacy filtering**: Cross-channel information is filtered based on channel privacy level
9. Bot dispatches entity-aware contextual prompt to runner via `runner-helper.sh`
10. Runner executes via OpenCode (headless or warm server)
11. Bot logs the AI response to Layer 0 and posts it back to the Matrix room
12. Bot adds reaction emoji (hourglass while processing, checkmark on success, X on failure)

**Session lifecycle**:

1. First message in a room creates a session in `matrix_room_sessions` (shared memory.db)
2. Entity is resolved from Matrix user ID and linked to the session
3. All messages are logged to Layer 0 (immutable `interactions` table) via `entity-helper.sh`
4. Subsequent messages include entity profile + conversation summary + recent interactions as context
5. After `sessionIdleTimeout` seconds of inactivity, the bot compacts the session (AI summarises the conversation)
6. The compacted summary is stored in the `conversations` table (Layer 1); **Layer 0 interactions are never deleted**
7. Next message in that room primes a new session with the entity profile and conversation summary
8. On graceful shutdown (SIGINT/SIGTERM), all active sessions are compacted before exit

## Setup

### Prerequisites

1. **Matrix homeserver** - Synapse (recommended), Dendrite, or Conduit
2. **Bot account** - Dedicated Matrix user for the bot
3. **Access token** - Bot's Matrix access token
4. **OpenCode server** - Running locally or remotely
5. **Runners** - At least one runner created via `runner-helper.sh`

### Auto-Setup Wizard

The interactive setup wizard guides you through configuration with validation and defaults.

```bash
# Test configuration without saving (dry-run mode)
matrix-dispatch-helper.sh setup --dry-run

# Run full setup (saves configuration)
matrix-dispatch-helper.sh setup
```

**Dry-run mode** is useful for:
- Testing configuration before committing to a live server
- Previewing settings without installing dependencies
- Validating homeserver URL and token format
- Training or documentation purposes

The wizard will prompt for:
1. **Homeserver URL** - Your Matrix server (e.g., `https://matrix.example.com`)
2. **Access token** - Bot account token (securely stored with 600 permissions)
3. **Allowed users** - Optional comma-separated list of Matrix user IDs
4. **Default runner** - Optional fallback runner for unmapped rooms
5. **Session idle timeout** - Seconds before compacting conversation context (default: 300)

After setup, the wizard automatically:
- Installs Node.js dependencies (`matrix-bot-sdk`, `better-sqlite3`)
- Generates session store and bot scripts
- Creates necessary directories with secure permissions

### Cloudron Setup (Recommended for Self-Hosted)

Cloudron provides one-click Synapse installation with automatic SSL and updates. See `services/hosting/cloudron.md` for the `install-app` command reference.

```bash
# 1. Install Synapse on Cloudron
# Dashboard > App Store > Matrix Synapse > Install
# Or via CLI: cloudron-helper.sh install-app production matrix synapse.yourdomain.com

# 2. Create bot user
# Synapse Admin Console > Users > Create User
# Username: aibot
# Password: (generate secure password)
# Admin: No (bots don't need admin)

# 3. Get access token
# Login as bot via Element (https://app.element.io)
# Settings > Help & About > Advanced > Access Token
# Copy the token (starts with syt_)

# 4. Configure the bot (use --dry-run to test first)
matrix-dispatch-helper.sh setup --dry-run  # Preview configuration
matrix-dispatch-helper.sh setup            # Apply configuration
# Enter: https://synapse.yourdomain.com
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
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
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
| `sessionIdleTimeout` | `300` | Seconds of inactivity before compacting a session |

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
- **Session persistence**: Each room maintains conversation context across messages

## Session Persistence and Entity Integration

Each Matrix room maintains a persistent conversation session backed by the shared `memory.db` entity tables. This gives a continuous conversation feel with entity-aware context — the bot knows who you are, your preferences, and your conversation history across sessions.

### How It Works

1. **Message arrives** in room -- bot resolves Matrix user ID to entity via `entity-helper.sh`
2. **Interaction logged** -- message recorded in Layer 0 (immutable, append-only `interactions` table)
3. **Context loaded** -- entity profile + conversation summary + recent interactions prepended to prompt
4. **Response received** -- AI response also logged to Layer 0
5. **Idle timeout** (default 300s) -- bot asks the AI to summarise the conversation
6. **Summary stored** -- conversation summary saved to Layer 1 (`conversations` table); **Layer 0 interactions are never deleted**
7. **Next message** -- session primed with entity profile and conversation summary

### Entity Resolution

When a Matrix user sends a message, the bot resolves their Matrix user ID to an entity:

- **Known user**: Exact match on `entity_channels` table (channel=matrix, channel_id=@user:server)
- **New user**: Creates a new entity via `entity-helper.sh create` with the Matrix user ID linked
- **Cross-channel**: If the same person is linked on other channels (SimpleX, email), their full profile is available

Entity resolution is cached per bot session to avoid repeated lookups.

### Privacy-Aware Context

When loading entity context for a prompt:

1. **Entity profile** (Layer 2) -- preferences, communication style, known needs
2. **Conversation summary** (Layer 1) -- previous conversation context for this room
3. **Recent interactions** (Layer 0) -- last N messages from this channel only
4. **Privacy filter** -- emails, IPs, and API keys are redacted; cross-channel private information is not leaked

### Session Management

```bash
# List all sessions with stats
matrix-dispatch-helper.sh sessions list

# View session statistics
matrix-dispatch-helper.sh sessions stats

# Clear a specific room's session
matrix-dispatch-helper.sh sessions clear '!room:server'

# Clear all sessions
matrix-dispatch-helper.sh sessions clear-all
```

### Graceful Shutdown

When the bot receives SIGINT or SIGTERM, it compacts all active sessions before exiting. This ensures no conversation context is lost on restart.

### Storage

- **Database**: `~/.aidevops/.agent-workspace/memory/memory.db` (shared with entity system)
- **Mode**: SQLite WAL (concurrent reads, single writer)
- **Tables**:
  - `matrix_room_sessions` -- per-room session state (room-to-entity mapping, activity tracking)
  - `interactions` -- Layer 0 immutable interaction log (shared across all channels)
  - `conversations` -- Layer 1 conversation summaries
  - `entities` / `entity_channels` -- Layer 2 entity identity and cross-channel linking
  - `entity_profiles` -- Layer 2 versioned entity preferences and needs
- **Compaction**: Summarises conversation to Layer 1; Layer 0 interactions are never deleted
- **Legacy**: Old `sessions.db` is still supported for backward compatibility (auto-detected)

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

- `scripts/entity-helper.sh` - Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` - Runner management
- `scripts/memory-helper.sh` - Memory system (shared memory.db)
- `scripts/cron-dispatch.sh` - Cron-triggered dispatch (similar pattern)
- `tools/ai-assistants/headless-dispatch.md` - Headless dispatch patterns
- `tools/ai-assistants/opencode-server.md` - OpenCode server API
- `tools/ai-assistants/openclaw.md` - Alternative: OpenClaw multi-channel bot
- `services/hosting/cloudron.md` - Cloudron platform for hosting Synapse
