---
description: Matterbridge multi-platform chat bridge — install, configure, and run bridges between 20+ platforms including Matrix, Discord, Telegram, Slack, IRC, WhatsApp, XMPP, and SimpleX via adapter
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Matterbridge — Multi-Platform Chat Bridge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Repo**: [github.com/42wim/matterbridge](https://github.com/42wim/matterbridge) (7.4K stars, Apache-2.0, Go)
- **Version**: v1.26.0 (stable)
- **Script**: `matterbridge-helper.sh [setup|start|stop|status|logs|validate|simplex-bridge]`
- **Config**: `~/.config/aidevops/matterbridge.toml` (600 permissions)
- **Data**: `~/.aidevops/.agent-workspace/matterbridge/`
- **Requires**: Go 1.18+ (build) or pre-compiled binary

**Quick start**:

```bash
matterbridge-helper.sh setup          # Download binary + interactive config
matterbridge-helper.sh validate       # Validate config before starting
matterbridge-helper.sh start --daemon
```

**Security/privacy warnings**: See `tools/security/opsec.md` — bridging to unencrypted platforms (Discord, Slack, IRC) exposes messages to those platforms' operators and metadata collection. E2E encryption is broken at bridge boundaries.

<!-- AI-CONTEXT-END -->

## Natively Supported Platforms

| Platform | Protocol | Notes |
|----------|----------|-------|
| Discord | Bot API | Requires bot token + server invite |
| Gitter | REST API | GitHub-owned |
| IRC | IRC | libera.chat, OFTC, etc. |
| Keybase | Keybase API | |
| Matrix | Client-Server API | E2E broken at bridge |
| Mattermost | API v4 | Self-hosted or cloud |
| Microsoft Teams | Graph API | Requires Azure app registration |
| Mumble | Mumble protocol | Voice-only (text chat) |
| Nextcloud Talk | Talk API | |
| Rocket.Chat | REST + WebSocket | |
| Slack | RTM/Events API | Bot token required |
| SSH-chat | SSH | |
| Telegram | Bot API | |
| Twitch | IRC | Chat only |
| VK | VK API | |
| WhatsApp | go-whatsapp (legacy) / whatsmeow (multidevice) | Unofficial; ToS risk |
| XMPP | XMPP | Jabber-compatible |
| Zulip | Zulip API | |

### 3rd Party via Matterbridge API

- **SimpleX**: [matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) adapter (MIT, Node.js) — routes via SimpleX CLI WebSocket API
- **Delta Chat**: matterdelta
- **Minecraft**: mattercraft, MatterBukkit

## Installation

### Binary (Recommended)

```bash
# Download latest stable
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-linux-64bit \
  -o /usr/local/bin/matterbridge
chmod +x /usr/local/bin/matterbridge

# macOS
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-amd64 \
  -o /usr/local/bin/matterbridge
chmod +x /usr/local/bin/matterbridge

# Verify
matterbridge -version
```

### Packages

```bash
snap install matterbridge          # Snap
scoop install matterbridge         # Windows Scoop
```

### Build from Source

```bash
# Standard build (all bridges, ~3GB RAM to compile)
go install github.com/42wim/matterbridge

# Reduced build (exclude MS Teams, saves ~2.5GB RAM)
go install -tags nomsteams github.com/42wim/matterbridge

# With WhatsApp multidevice (GPL3 dependency — binary not distributed)
go install -tags whatsappmulti github.com/42wim/matterbridge@master

# Without MS Teams + with WhatsApp multidevice
go install -tags nomsteams,whatsappmulti github.com/42wim/matterbridge@master
```

## Configuration

### Config File Location

```bash
# Default search order
./matterbridge.toml
~/.config/aidevops/matterbridge.toml  # aidevops convention

# Explicit path
matterbridge -conf /path/to/matterbridge.toml
```

### Basic Structure

Every config has three sections:

1. **Protocol blocks** — credentials and settings per platform instance
2. **`[general]`** — global settings (nick format, etc.)
3. **`[[gateway]]`** — bridge definitions connecting accounts to channels

```toml
# Protocol block: one per platform instance
[matrix]
  [matrix.home]
  Server="https://matrix.example.com"
  Login="bridgebot"
  Password="secret"
  RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

[discord]
  [discord.myserver]
  Token="Bot YOUR_DISCORD_BOT_TOKEN"
  Server="My Discord Server"

[telegram]
  [telegram.main]
  Token="YOUR_TELEGRAM_BOT_TOKEN"

[irc]
  [irc.libera]
  Server="irc.libera.chat:6667"
  Nick="matterbridge"
  UseTLS=true

# Global settings
[general]
RemoteNickFormat="[{PROTOCOL}/{BRIDGE}] <{NICK}> "

# Gateway: connects accounts + channels
[[gateway]]
name="mybridge"
enable=true

  [[gateway.inout]]
  account="matrix.home"
  channel="#general:example.com"

  [[gateway.inout]]
  account="discord.myserver"
  channel="general"

  [[gateway.inout]]
  account="telegram.main"
  channel="-1001234567890"  # Group chat ID (negative)

  [[gateway.inout]]
  account="irc.libera"
  channel="#myproject"
```

### Nick Format Variables

| Variable | Value |
|----------|-------|
| `{NICK}` | Sender's username |
| `{PROTOCOL}` | Platform name (matrix, discord, etc.) |
| `{BRIDGE}` | Bridge instance name |
| `{GATEWAY}` | Gateway name |

### One-Way Bridges (in/out)

```toml
[[gateway]]
name="announcements"
enable=true

  # Source: only receives from this channel
  [[gateway.in]]
  account="slack.work"
  channel="announcements"

  # Destinations: only sends to these channels
  [[gateway.out]]
  account="discord.myserver"
  channel="announcements"

  [[gateway.out]]
  account="matrix.home"
  channel="#announcements:example.com"
```

### Platform-Specific Configuration

#### Matrix

```toml
[matrix]
  [matrix.home]
  Server="https://matrix.example.com"
  Login="bridgebot"
  Password="secret"
  # Or use access token (preferred)
  # Token="syt_..."
  RemoteNickFormat="[{PROTOCOL}] <{NICK}> "
  # Preserve threading
  PreserveThreading=true
```

#### Discord

```toml
[discord]
  [discord.myserver]
  Token="Bot YOUR_BOT_TOKEN"
  Server="My Server Name"
  # Use webhooks for better username/avatar spoofing
  WebhookURL="https://discord.com/api/webhooks/..."
  RemoteNickFormat="{NICK} [{PROTOCOL}]"
```

#### Telegram

```toml
[telegram]
  [telegram.main]
  Token="YOUR_BOT_TOKEN"
  # For supergroups, use negative ID
  # Get ID: add @userinfobot to group
```

#### Slack

```toml
[slack]
  [slack.workspace]
  Token="xoxb-YOUR-BOT-TOKEN"
  # Legacy token (deprecated): xoxp-...
  # Bot token (recommended): xoxb-...
  PrefixMessagesWithNick=true
```

#### IRC

```toml
[irc]
  [irc.libera]
  Server="irc.libera.chat:6697"
  Nick="matterbridge"
  Password=""
  UseTLS=true
  SkipTLSVerify=false
  NickServNick="NickServ"
  NickServPassword="your-nickserv-password"
```

#### XMPP

```toml
[xmpp]
  [xmpp.jabber]
  Server="jabber.example.com:5222"
  Jid="bridgebot@jabber.example.com"
  Password="secret"
  Muc="conference.jabber.example.com"
  Nick="matterbridge"
```

#### Mattermost

```toml
[mattermost]
  [mattermost.work]
  Server="mattermost.example.com"
  Team="myteam"
  Login="bridgebot@example.com"
  Password="secret"
  PrefixMessagesWithNick=true
  RemoteNickFormat="[{PROTOCOL}] <{NICK}> "
```

### SimpleX via matterbridge-simplex Adapter

SimpleX is not natively supported by Matterbridge. The [matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) adapter (MIT, Node.js) bridges SimpleX Chat to Matterbridge's HTTP API, enabling SimpleX to connect to all 40+ platforms.

#### Architecture

```text
SimpleX CLI (WebSocket :5225)
    |
    | WebSocket JSON API (localhost)
    |
matterbridge-simplex (Node.js adapter)
    |
    | HTTP REST API (localhost:4242)
    |
Matterbridge (Go binary)
    |
    |--- Matrix rooms
    |--- Telegram groups
    |--- Discord channels
    |--- Slack workspaces
    |--- IRC channels
    |--- 40+ other platforms
```

**Message flow (SimpleX -> other platforms)**:

1. User sends message in SimpleX Chat (mobile/desktop/CLI)
2. SimpleX CLI receives via SMP protocol, emits `newChatItems` event on WebSocket
3. matterbridge-simplex adapter reads event, extracts text and sender
4. Adapter POSTs message to Matterbridge HTTP API (`/api/message`)
5. Matterbridge routes to all configured gateway destinations

**Message flow (other platforms -> SimpleX)**:

1. User sends message on Matrix/Telegram/Discord/etc.
2. Matterbridge receives via platform SDK, buffers in API endpoint
3. matterbridge-simplex adapter polls `/api/messages` (1s interval)
4. Adapter sends message to SimpleX CLI via `apiSendTextMessage` WebSocket command
5. SimpleX CLI delivers to the configured contact or group chat

#### Features and Limitations

| Feature | Status | Notes |
|---------|--------|-------|
| Text messages | Supported | Bidirectional |
| Image previews | Supported | SimpleX -> other platforms (preview only, not full file) |
| Full file transfer | Not yet | WIP in matterbridge-simplex |
| `/hide` prefix | Supported | Messages starting with `/hide` are not bridged — SimpleX-only |
| Contact chats | Supported | Bridge to a specific SimpleX contact |
| Group chats | Supported | Bridge to a specific SimpleX group |
| Multiple bridges | Supported | Run multiple adapter instances with different chat IDs |

#### Quick Setup (Docker Compose)

The recommended deployment uses Docker Compose with 3 containers. See `configs/matterbridge-simplex-compose.yml` for the full template.

```bash
# 1. Prepare SimpleX database
#    Run simplex-chat CLI first to create a profile and join/create the chat to bridge
simplex-chat
#    Then move the database:
mkdir -p data/simplex
cp ~/.simplex/simplex_v1_* data/simplex/
chmod -R 777 data/  # Required for Docker volume access

# 2. Get the chat ID to bridge
simplex-chat -e '/_get chats 1 pcc=off' \
  | tail -n +2 \
  | jq '.[].chatInfo | (.groupInfo // .contact) | {name: .localDisplayName, type: (if .groupId then "group" else "contact" end), id: .groupId // .contactId}'

# 3. Configure matterbridge.toml (copy from configs/matterbridge-simplex.toml.example)
cp configs/matterbridge-simplex.toml.example matterbridge.toml
# Edit: add your platform credentials and channel IDs

# 4. Deploy
matterbridge-helper.sh simplex-bridge up

# Or manually:
docker compose -f configs/matterbridge-simplex-compose.yml up --build -d
```

#### Quick Setup (Manual)

```bash
# 1. Install SimpleX CLI
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash

# 2. Clone matterbridge-simplex and build
git clone https://github.com/UnkwUsr/matterbridge-simplex.git
cd matterbridge-simplex
git submodule update --init --recursive --depth 1
( cd lib/simplex-chat-client-typescript/ && npm install && tsc )

# 3. Start SimpleX CLI as WebSocket server
simplex-chat -p 5225

# 4. Start Matterbridge with API endpoint
matterbridge -conf matterbridge.toml

# 5. Start the adapter
# Format: node main.js <MB_API_ADDR> <MB_GATEWAY> <SXC_WS_ADDR> <CHAT_ID> <CHAT_TYPE>
node main.js 127.0.0.1:4242 gateway1 127.0.0.1:5225 1 group
```

#### Matterbridge Config for SimpleX

```toml
# Matterbridge API endpoint — the adapter connects here
[api]
  [api.myapi]
  BindAddress="127.0.0.1:4242"
  Buffer=1000

# Add your destination platform(s)
[matrix]
  [matrix.home]
  Server="https://matrix.example.com"
  Login="bridgebot"
  Password="YOUR_MATRIX_PASSWORD"
  RemoteNickFormat="[SimpleX] <{NICK}> "

# Gateway connecting SimpleX (via API) to Matrix
[[gateway]]
name="simplex-matrix"
enable=true

  [[gateway.inout]]
  account="api.myapi"
  channel="api"

  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

See `configs/matterbridge-simplex.toml.example` for a complete template with Matrix, Telegram, and Discord examples.

#### Obtaining SimpleX Chat IDs

SimpleX uses separate ID spaces for contacts and groups. You need both the ID and type.

```bash
# Get info for a specific chat
simplex-chat -e '/i #group_name'    # Group
simplex-chat -e '/i @contact_name'  # Contact

# List all chats with IDs (requires jq)
simplex-chat -e '/_get chats 1 pcc=off' \
  | tail -n +2 \
  | jq '.[].chatInfo | (.groupInfo // .contact) | {name: .localDisplayName, type: (if .groupId then "group" else "contact" end), id: .groupId // .contactId}'
```

**Note**: The default chat ID in the Docker Compose template is `4`. Check your actual chat ID and update `docker-compose.yml` if it differs.

## Privacy Gradient

Matterbridge enables a **privacy gradient** — users choose their preferred privacy level while staying in the same conversation.

```text
Maximum Privacy                                          Maximum Convenience
|                                                                          |
SimpleX Chat ──> Matrix (self-hosted) ──> Matrix (public) ──> Telegram/Discord
No identifiers    Federated, E2E opt-in   Federated          Centralized
No metadata       Server stores metadata  Server stores      Full metadata
No phone/email    @user:server IDs        @user:server IDs   Phone/username
```

### How It Works

1. **SimpleX users** get maximum privacy — no identifiers, no metadata, E2E encrypted
2. **Matrix users** get federation and E2E encryption (when enabled), with `@user:server` identifiers
3. **Telegram/Discord/Slack users** get convenience and existing ecosystem, with full platform metadata
4. All users see the same messages, prefixed with `[Platform] <Username>` to identify origin
5. SimpleX users can send `/hide` messages that are not bridged — visible only on SimpleX

### Security Implications

**E2E encryption is broken at bridge boundaries.** When bridging:

- Messages are decrypted by the SimpleX CLI process
- Passed in plaintext to the matterbridge-simplex adapter (localhost only)
- Re-encrypted (or sent plaintext) to destination platform by Matterbridge
- The bridge host has access to all message content in plaintext
- Metadata (sender, timestamp) is visible to all bridged platforms

**Mitigations**:

- Run the entire bridge stack on a trusted, hardened host
- Use `network_mode: host` in Docker (default) — all traffic stays on localhost
- Use NetBird/WireGuard to restrict access to the bridge host
- Store platform credentials in gopass: `aidevops secret set MATTERBRIDGE_MATRIX_TOKEN`
- Config file must have 600 permissions: `chmod 600 matterbridge.toml`
- Consider one-way bridges (`[[gateway.in]]`/`[[gateway.out]]`) to limit exposure

See `tools/security/opsec.md` for full platform trust matrix and threat modeling.

## Running

### CLI

```bash
# Foreground (debug)
matterbridge -conf matterbridge.toml -debug

# Background
matterbridge -conf matterbridge.toml &

# Validate config only
matterbridge -conf matterbridge.toml -validate  # (if supported by version)
```

### Docker

```bash
# Docker run
docker run -d \
  --name matterbridge \
  --restart unless-stopped \
  -v /path/to/matterbridge.toml:/etc/matterbridge/matterbridge.toml:ro \
  42wim/matterbridge:stable

# Docker Compose
cat > docker-compose.yml <<'EOF'
version: "3"
services:
  matterbridge:
    image: 42wim/matterbridge:stable
    restart: unless-stopped
    volumes:
      - ./matterbridge.toml:/etc/matterbridge/matterbridge.toml:ro
EOF

docker compose up -d
```

### Systemd

```ini
# /etc/systemd/system/matterbridge.service
[Unit]
Description=Matterbridge chat bridge
After=network.target

[Service]
Type=simple
User=matterbridge
ExecStart=/usr/local/bin/matterbridge -conf /etc/matterbridge/matterbridge.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now matterbridge
sudo journalctl -fu matterbridge
```

## REST API

Matterbridge exposes a simple REST API for custom integrations:

```toml
[api]
  [api.myapi]
  BindAddress="127.0.0.1:4242"
  Token="your-secret-token"
  Buffer=1000
```

```bash
# Send message to bridge
curl -X POST http://localhost:4242/api/message \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello from API", "username": "bot", "gateway": "mybridge"}'

# Receive messages (long-poll)
curl http://localhost:4242/api/messages \
  -H "Authorization: Bearer your-secret-token"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Messages not bridging | Check `matterbridge -debug` output; verify account credentials |
| Discord bot not posting | Ensure bot has `Send Messages` permission in channel |
| Matrix messages duplicated | Check `IgnoreMessages` config; ensure bot is not in both sides |
| Telegram group ID wrong | Use `@userinfobot` or check bot updates for correct chat ID |
| WhatsApp disconnects | WhatsApp multidevice is beta; expect instability |
| High memory on build | Use `-tags nomsteams` to reduce build memory to ~500MB |
| IRC nick conflicts | Set `NickServPassword` or use unique nick |

## Security Considerations

See [Privacy Gradient > Security Implications](#security-implications) for detailed analysis of E2E encryption at bridge boundaries.

**Summary**: E2E encryption is broken at bridge boundaries. The bridge host sees all messages in plaintext. Run on a trusted host, use localhost-only networking, store credentials in gopass, and set config file permissions to 600.

## Related

- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/simplex.md` — SimpleX install, bot API, self-hosted servers
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
- `configs/matterbridge-simplex-compose.yml` — Docker Compose template for SimpleX bridge
- `configs/matterbridge-simplex.toml.example` — Config template for SimpleX-Matrix bridging
