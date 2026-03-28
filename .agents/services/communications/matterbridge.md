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

```bash
matterbridge-helper.sh setup          # Download binary + interactive config
matterbridge-helper.sh validate       # Validate config before starting
matterbridge-helper.sh start --daemon
```

**Security/privacy**: Bridging to unencrypted platforms (Discord, Slack, IRC) exposes messages to those platforms' operators. E2E encryption is broken at bridge boundaries. See `tools/security/opsec.md`.

<!-- AI-CONTEXT-END -->

## Supported Platforms

Discord, Gitter, IRC, Keybase, Matrix (E2E broken at bridge), Mattermost, Microsoft Teams (Azure app required), Mumble, Nextcloud Talk, Rocket.Chat, Slack, SSH-chat, Telegram, Twitch (chat only), VK, WhatsApp (whatsmeow multidevice — unofficial, ToS risk), XMPP, Zulip.

**3rd party via Matterbridge API**: SimpleX ([matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex)), Delta Chat (matterdelta), Minecraft (mattercraft, MatterBukkit).

## Installation

### Binary (Recommended)

```bash
# Linux
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-linux-64bit \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge

# macOS (Intel: darwin-64bit, Apple Silicon: darwin-arm64)
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-darwin-arm64 \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge

matterbridge -version
```

Packages: `snap install matterbridge` / `scoop install matterbridge`

### Build from Source

```bash
go install github.com/42wim/matterbridge                                    # All bridges (~3GB RAM)
go install -tags nomsteams github.com/42wim/matterbridge                    # Exclude MS Teams (~500MB)
go install -tags nomsteams,whatsappmulti github.com/42wim/matterbridge@master  # WhatsApp multidevice (GPL3)
```

## Configuration

Config is searched in order: `./matterbridge.toml`, `~/.config/aidevops/matterbridge.toml`, or explicit `-conf /path/to/matterbridge.toml`.

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

**Nick format variables**: `{NICK}` (username), `{PROTOCOL}` (platform), `{BRIDGE}` (instance), `{GATEWAY}` (gateway name).

**One-way bridges**: Use `[[gateway.in]]` / `[[gateway.out]]` instead of `[[gateway.inout]]` to restrict message flow direction.

### Platform-Specific Notes

| Platform | Key options |
|----------|-------------|
| Matrix | Use `Token=` (access token) over `Password=`; `PreserveThreading=true` |
| Discord | Add `WebhookURL=` for better username/avatar spoofing |
| Slack | Use `xoxb-` bot token (not legacy `xoxp-`); `PrefixMessagesWithNick=true` |
| IRC | `UseTLS=true`; `NickServPassword=` for registered nicks |
| XMPP | Requires `Jid=`, `Muc=` (conference server), `Nick=` |
| Mattermost | Requires `Server=`, `Team=`, `Login=`, `Password=` |
| Telegram | Get group chat ID (negative integer) via `@userinfobot` |

### SimpleX via Adapter

SimpleX is not natively supported. Use [matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex):

```bash
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash
go install github.com/simplex-chat/matterbridge-simplex@latest
matterbridge-simplex --port 4242 --profile simplex-bridge
```

Then configure an `[api.simplex]` block with `BindAddress="0.0.0.0:4243"` and `Token=`, and add a `[[gateway]]` with `account="api.simplex"` / `channel="api"` paired with your target platform account.

**Note**: SimpleX E2E encryption is broken at the bridge boundary.

## Running

```bash
matterbridge -conf matterbridge.toml -debug   # Foreground
matterbridge -conf matterbridge.toml &        # Background
```

### Docker

```bash
docker run -d --name matterbridge --restart unless-stopped \
  -v /path/to/matterbridge.toml:/etc/matterbridge/matterbridge.toml:ro \
  42wim/matterbridge:stable
```

### Systemd

```ini
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
  Token="<MATTERBRIDGE_API_TOKEN>"
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
