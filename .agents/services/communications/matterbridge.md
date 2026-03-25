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

**Security/privacy**: Bridging to unencrypted platforms (Discord, Slack, IRC) exposes messages to those platforms' operators. E2E encryption is broken at bridge boundaries. See `tools/security/opsec.md`.

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
# Linux
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-linux-64bit \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge

# macOS Intel
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-64bit \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge

# macOS Apple Silicon
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-arm64 \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge

matterbridge -version
```

Packages: `snap install matterbridge` / `scoop install matterbridge`

### Build from Source

```bash
go install github.com/42wim/matterbridge                                    # All bridges (~3GB RAM)
go install -tags nomsteams github.com/42wim/matterbridge                    # Exclude MS Teams (~500MB)
go install -tags whatsappmulti github.com/42wim/matterbridge@master         # WhatsApp multidevice (GPL3)
go install -tags nomsteams,whatsappmulti github.com/42wim/matterbridge@master
```

## Configuration

### Config File Location

```bash
./matterbridge.toml                        # Current directory
~/.config/aidevops/matterbridge.toml       # aidevops convention
matterbridge -conf /path/to/matterbridge.toml  # Explicit path
```

### Basic Structure

Every config has three sections:

1. **Protocol blocks** — credentials and settings per platform instance
2. **`[general]`** — global settings (nick format, etc.)
3. **`[[gateway]]`** — bridge definitions connecting accounts to channels

> **Security**: All credential values below are `<PLACEHOLDER>` examples. Store actual tokens via `aidevops secret set NAME` (gopass). See `tools/credentials/gopass.md`.

```toml
[matrix]
  [matrix.home]
  Server="https://matrix.example.com"
  Login="bridgebot"
  Password="<MATRIX_PASSWORD>"
  RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

[discord]
  [discord.myserver]
  Token="Bot <DISCORD_BOT_TOKEN>"
  Server="My Discord Server"

[telegram]
  [telegram.main]
  Token="<TELEGRAM_BOT_TOKEN>"

[irc]
  [irc.libera]
  Server="irc.libera.chat:6667"
  Nick="matterbridge"
  UseTLS=true

[general]
RemoteNickFormat="[{PROTOCOL}/{BRIDGE}] <{NICK}> "

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

### One-Way Bridges

```toml
[[gateway]]
name="announcements"
enable=true

  [[gateway.in]]
  account="slack.work"
  channel="announcements"

  [[gateway.out]]
  account="discord.myserver"
  channel="announcements"

  [[gateway.out]]
  account="matrix.home"
  channel="#announcements:example.com"
```

### Platform-Specific Configuration

```toml
# Matrix — use access token (preferred over password)
[matrix.home]
Server="https://matrix.example.com"
Login="bridgebot"
Token="<MATRIX_ACCESS_TOKEN>"   # aidevops secret set MATTERBRIDGE_MATRIX_TOKEN
PreserveThreading=true

# Discord — use webhooks for better username/avatar spoofing
[discord.myserver]
Token="Bot <DISCORD_BOT_TOKEN>"
Server="My Server Name"
WebhookURL="<DISCORD_WEBHOOK_URL>"   # aidevops secret set MATTERBRIDGE_DISCORD_WEBHOOK

# Telegram — get group ID via @userinfobot
[telegram.main]
Token="<TELEGRAM_BOT_TOKEN>"   # aidevops secret set MATTERBRIDGE_TELEGRAM_TOKEN

# Slack — use bot token (xoxb-...), not legacy xoxp-
[slack.workspace]
Token="<SLACK_BOT_TOKEN>"   # aidevops secret set MATTERBRIDGE_SLACK_TOKEN
PrefixMessagesWithNick=true

# IRC
[irc.libera]
Server="irc.libera.chat:6697"
Nick="matterbridge"
UseTLS=true
NickServPassword="<IRC_NICKSERV_PASSWORD>"   # aidevops secret set MATTERBRIDGE_IRC_NICKSERV_PASSWORD

# XMPP
[xmpp.jabber]
Server="jabber.example.com:5222"
Jid="bridgebot@jabber.example.com"
Password="<XMPP_PASSWORD>"   # aidevops secret set MATTERBRIDGE_XMPP_PASSWORD
Muc="conference.jabber.example.com"
Nick="matterbridge"

# Mattermost
[mattermost.work]
Server="mattermost.example.com"
Team="myteam"
Login="bridgebot@example.com"
Password="<MATTERMOST_PASSWORD>"   # aidevops secret set MATTERBRIDGE_MATTERMOST_PASSWORD
PrefixMessagesWithNick=true
```

### SimpleX via Adapter

SimpleX is not natively supported. Use [matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex):

```bash
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash
go install github.com/simplex-chat/matterbridge-simplex@latest
matterbridge-simplex --port 4242 --profile simplex-bridge
```

```toml
[api]
  [api.simplex]
  BindAddress="0.0.0.0:4243"
  Token="<SIMPLEX_API_TOKEN>"   # aidevops secret set MATTERBRIDGE_SIMPLEX_API_TOKEN

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

**Note**: SimpleX E2E encryption is broken at the bridge boundary.

## Running

```bash
# Foreground (debug)
matterbridge -conf matterbridge.toml -debug

# Background
matterbridge -conf matterbridge.toml &
```

### Docker

```bash
docker run -d --name matterbridge --restart unless-stopped \
  -v /path/to/matterbridge.toml:/etc/matterbridge/matterbridge.toml:ro \
  42wim/matterbridge:stable
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
sudo systemctl daemon-reload && sudo systemctl enable --now matterbridge
sudo journalctl -fu matterbridge
```

## REST API

```toml
[api]
  [api.myapi]
  BindAddress="127.0.0.1:4242"
  Token="<MATTERBRIDGE_API_TOKEN>"   # aidevops secret set MATTERBRIDGE_API_TOKEN
  Buffer=1000
```

```bash
curl -X POST http://localhost:4242/api/message \
  -H "Authorization: Bearer <MATTERBRIDGE_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello from API", "username": "bot", "gateway": "mybridge"}'

curl http://localhost:4242/api/messages \
  -H "Authorization: Bearer <MATTERBRIDGE_API_TOKEN>"
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

## Security

**E2E encryption is broken at bridge boundaries.** Messages are decrypted by Matterbridge and re-encrypted (or sent plaintext) to the destination. The bridge host has access to all message content.

**Mitigations**:
- Run on a trusted, hardened host (NetBird/WireGuard to restrict access)
- Avoid bridging sensitive channels to unencrypted platforms (IRC, Slack, Discord)
- Store credentials in gopass: `aidevops secret set MATTERBRIDGE_DISCORD_TOKEN`
- Config file must have 600 permissions: `chmod 600 matterbridge.toml`

See `tools/security/opsec.md` for full platform trust matrix and threat modeling.

## Related

- `services/communications/matrix-bot.md`, `simplex.md`, `telegram.md`, `signal.md`, `whatsapp.md`, `slack.md`, `discord.md`, `msteams.md`, `nextcloud-talk.md`
- `services/communications/nostr.md`, `imessage.md`, `google-chat.md`, `urbit.md` — no native Matterbridge support
- `services/communications/bitchat.md` — Bluetooth mesh, offline P2P
- `services/communications/xmtp.md` — Web3 messaging, agent SDK
- `tools/security/opsec.md` — Platform trust matrix, privacy comparison
- `tools/ai-assistants/headless-dispatch.md` — Headless dispatch patterns
