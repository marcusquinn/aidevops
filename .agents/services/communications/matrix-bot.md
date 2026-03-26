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

- **Purpose**: Bridge Matrix rooms to aidevops runners via OpenCode with entity-aware context
- **Script**: `matrix-dispatch-helper.sh [setup|start|stop|status|map|unmap|mappings|sessions|test|logs]`
- **Config**: `~/.config/aidevops/matrix-bot.json` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/matrix-bot/`
- **Session DB**: `~/.aidevops/.agent-workspace/memory/memory.db` (shared entity tables, SQLite WAL)
- **Entity helper**: `entity-helper.sh` (identity resolution, Layer 0/1 interaction logging)
- **SDK**: `matrix-bot-sdk`, `better-sqlite3` (npm); Node.js >= 18, jq, OpenCode server, Matrix homeserver

```bash
matrix-dispatch-helper.sh setup          # Interactive wizard
matrix-dispatch-helper.sh map '!room:server' code-reviewer
matrix-dispatch-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Architecture

```text
Matrix Room ──▶ Matrix Bot ──▶ OpenCode / runner-helper.sh ──▶ AI session
                    │
                    ▼
              memory.db (shared)
              ├── entities / entity_channels / entity_profiles  (Layer 2)
              ├── interactions      (Layer 0: immutable log)
              ├── conversations     (Layer 1: summaries)
              └── matrix_room_sessions
```

**Message flow**: `!ai <prompt>` → sync → permission check → room-to-runner lookup → entity resolution → Layer 0 log → load entity profile + conversation summary + recent interactions → privacy filter → dispatch → log response → post to room + reaction (⏳/✓/✗).

**Session lifecycle**: First message creates session → entity linked → all messages logged to Layer 0 (immutable) → after `sessionIdleTimeout` idle, AI summarises → summary stored in Layer 1; **Layer 0 never deleted** → next message primed with entity profile + summary → SIGINT/SIGTERM compacts all sessions before exit.

## Setup

**Prerequisites**: Matrix homeserver (Synapse recommended), bot account + access token, OpenCode server, at least one runner.

```bash
matrix-dispatch-helper.sh setup --dry-run  # Preview without saving
matrix-dispatch-helper.sh setup            # Apply (prompts: homeserver URL, access token,
                                           # allowed users, default runner, session idle timeout)
```

### Cloudron Setup (Recommended)

```bash
# 1. Install Synapse: Dashboard > App Store > Matrix Synapse > Install
# 2. Create bot user (App > Terminal):
/app/code/env/bin/register_new_matrix_user -c /app/data/configs/homeserver.yaml http://localhost:8008
# 3. Get access token:
curl -s -X POST "http://localhost:8008/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"aibot"},"password":"YOUR_PASSWORD"}' \
  | python3 -m json.tool   # copy access_token
# 4. In homeserver.yaml: set enable_registration: false, remove 'federation' from resources. Restart.
# 5. Create unencrypted rooms via Element (NOT FluffyChat — forces encryption with no toggle)
#    Or via API: curl -X POST ".../createRoom" -d '{"preset":"private_chat","initial_state":[]}'
# 6. Configure + map + start:
matrix-dispatch-helper.sh setup
runner-helper.sh create code-reviewer --workdir ~/Git/myproject
matrix-dispatch-helper.sh map '!roomid:yourdomain.com' code-reviewer
matrix-dispatch-helper.sh start --daemon
```

**Stale invites** (bot crashes on startup): `matrix-dispatch-helper.sh cleanup-invites`

### Manual Synapse

```bash
register_new_matrix_user -c /etc/synapse/homeserver.yaml http://localhost:8008 \
  --user aibot --password "secure-password" --no-admin
curl -X POST "https://matrix.example.com/_matrix/client/v3/login" \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"aibot"},"password":"secure-password"}' \
  | jq -r '.access_token'
```

## Configuration

`~/.config/aidevops/matrix-bot.json` (600 permissions):

```json
{
  "homeserverUrl": "https://matrix.example.com",
  "accessToken": "syt_...",
  "allowedUsers": "@admin:example.com,@dev:example.com",
  "defaultRunner": "",
  "roomMappings": {
    "!abc123:example.com": "code-reviewer",
    "!def456:example.com": "seo-analyst"
  },
  "botPrefix": "!ai",
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300
}
```

| Option | Default | Description |
|--------|---------|-------------|
| `homeserverUrl` | required | Matrix homeserver URL |
| `accessToken` | required | Bot's access token |
| `allowedUsers` | `""` (all) | Comma-separated allowed user IDs |
| `defaultRunner` | `""` | Runner for unmapped rooms |
| `roomMappings` | `{}` | Room ID → runner name |
| `botPrefix` | `!ai` | Command prefix |
| `ignoreOwnMessages` | `true` | Ignore bot's own messages |
| `maxPromptLength` | `3000` | Max prompt length |
| `responseTimeout` | `600` | Max seconds to wait for runner |
| `sessionIdleTimeout` | `300` | Idle timeout before compaction |

## Room-to-Runner Mapping

```bash
matrix-dispatch-helper.sh map '!dev-room:server' code-reviewer
matrix-dispatch-helper.sh mappings
matrix-dispatch-helper.sh unmap '!dev-room:server'
```

| Room | Runner | Purpose |
|------|--------|---------|
| `#dev:server` | `code-reviewer` | Code review, security analysis |
| `#seo:server` | `seo-analyst` | SEO audits, keyword research |
| `#ops:server` | `ops-monitor` | Server health, deployment status |
| `#general:server` | (default) | General AI assistance |

## Usage

```text
!ai Review src/auth.ts for security vulnerabilities
!ai Generate unit tests for the user registration flow
!ai What are the top 10 keywords for "cloud hosting"?
```

**Bot behaviour**: typing indicator; hourglass/checkmark/X reactions; one dispatch per room (prevents flooding); long responses truncated; auto-joins on invite; per-room context persisted.

## Session Persistence & Entity Integration

**Entity resolution**: `@user:server` → lookup `entity_channels` → create if new → cache per session. Cross-channel profiles available if the same person is linked on SimpleX, email, etc.

**Context loaded per prompt**:

1. Entity profile (Layer 2) — preferences, communication style
2. Conversation summary (Layer 1) — previous context for this room
3. Recent interactions (Layer 0) — last N messages from this channel only
4. Privacy filter — emails, IPs, API keys redacted; cross-channel private info not leaked

```bash
matrix-dispatch-helper.sh sessions list
matrix-dispatch-helper.sh sessions stats
matrix-dispatch-helper.sh sessions clear '!room:server'
matrix-dispatch-helper.sh sessions clear-all
```

**Storage** (`memory.db`, SQLite WAL): `matrix_room_sessions` (per-room state), `interactions` (Layer 0 immutable), `conversations` (Layer 1 summaries), `entities`/`entity_channels`/`entity_profiles` (Layer 2 identity). Legacy `sessions.db` auto-detected.

## Operations

```bash
matrix-dispatch-helper.sh start --daemon   # Background
matrix-dispatch-helper.sh start            # Foreground (debug)
matrix-dispatch-helper.sh stop
matrix-dispatch-helper.sh status
matrix-dispatch-helper.sh logs [--follow] [--tail 200]
matrix-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
```

## Runners

```bash
runner-helper.sh create code-reviewer --description "Reviews code for security and quality"
runner-helper.sh create seo-analyst --description "SEO analysis and keyword research"
runner-helper.sh edit code-reviewer
```

Dispatches via `runner-helper.sh` — handles AGENTS.md, OpenCode sessions, memory namespace isolation, mailbox, run logging.

## Security

1. Config stored with 600 permissions
2. `allowedUsers` restricts who can trigger the bot
3. Only mapped rooms can dispatch to runners
4. Bot account should NOT have Synapse admin privileges
5. OpenCode server should be localhost-only unless secured
6. One dispatch per room prevents resource exhaustion
7. Set `OPENCODE_SERVER_PASSWORD` env var (recommended on shared systems)
8. Bot cannot read encrypted messages — rooms must have encryption disabled; use Element (not FluffyChat) when creating rooms

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Bot not responding | `matrix-dispatch-helper.sh status` + logs |
| "Not mapped" error | `matrix-dispatch-helper.sh map '!room:server' runner` |
| Runner dispatch fails | Ensure OpenCode server running: `opencode serve` |
| Runner not found | `runner-helper.sh create <name> --workdir /path` |
| Access denied | Check `allowedUsers` in config |
| Bot not joining rooms | Invite bot user via Element |
| Bot crashes on startup | `matrix-dispatch-helper.sh cleanup-invites` |
| Raw JSON in responses | `matrix-dispatch-helper.sh setup` then restart |
| Stale PID file | `matrix-dispatch-helper.sh stop` |
| Wrong working directory | `runner-helper.sh status <name>` (verify workdir) |

## Related

- `scripts/entity-helper.sh` — Entity memory system (identity resolution, Layer 0/1/2)
- `scripts/runner-helper.sh` — Runner management
- `scripts/memory-helper.sh` — Memory system (shared memory.db)
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- `tools/ai-assistants/opencode-server.md` — OpenCode server API
- `tools/ai-assistants/openclaw.md` — Alternative: OpenClaw multi-channel bot
- `services/hosting/cloudron.md` — Cloudron platform for hosting Synapse
