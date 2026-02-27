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
- **Script**: `matterbridge-helper.sh [setup|start|stop|status|logs|validate]`
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

- **SimpleX**: [matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex) adapter — routes via SimpleX CLI
- **Delta Chat**: matterdelta
- **Minecraft**: mattercraft, MatterBukkit

## Installation

### Binary (Recommended)

```bash
# Download latest stable
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-linux-64bit \
  -o /usr/local/bin/matterbridge
chmod +x /usr/local/bin/matterbridge

# macOS (Intel)
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-64bit \
  -o /usr/local/bin/matterbridge
chmod +x /usr/local/bin/matterbridge

# macOS (Apple Silicon)
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-arm64 \
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

### SimpleX via Adapter

SimpleX is not natively supported. Use [matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex):

```bash
# Install SimpleX CLI first
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash

# Install matterbridge-simplex adapter
go install github.com/simplex-chat/matterbridge-simplex@latest

# Run adapter (exposes Matterbridge API endpoint)
matterbridge-simplex --port 4242 --profile simplex-bridge
```

```toml
# Matterbridge config: use API bridge to connect to adapter
[api]
  [api.simplex]
  BindAddress="0.0.0.0:4243"
  Token="your-api-token"

[[gateway]]
name="simplex-matrix"
enable=true

  [[gateway.inout]]
  account="api.simplex"
  channel="api"

  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

**Note**: SimpleX E2E encryption is broken at the bridge boundary. Messages entering the bridge are decrypted and re-encrypted for the destination platform. See `tools/security/opsec.md` for implications.

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

**E2E encryption is broken at bridge boundaries.** When bridging:

- Messages are decrypted by Matterbridge process
- Re-encrypted (or sent plaintext) to destination platform
- The bridge host has access to all message content in plaintext
- Metadata (sender, timestamp, channel) is visible to all bridged platforms

**Mitigations**:

- Run Matterbridge on a trusted, hardened host
- Use NetBird/WireGuard to restrict access to the bridge host
- Avoid bridging sensitive channels to unencrypted platforms (IRC, Slack, Discord)
- Store credentials in gopass: `aidevops secret set MATTERBRIDGE_DISCORD_TOKEN`
- Config file must have 600 permissions: `chmod 600 matterbridge.toml`

See `tools/security/opsec.md` for full platform trust matrix and threat modeling.

## Related

- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/simplex.md` — SimpleX install, bot API, self-hosted servers
- `tools/security/opsec.md` — Platform trust matrix, E2E status, metadata warnings
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
