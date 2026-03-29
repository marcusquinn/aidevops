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

- **Repo**: [42wim/matterbridge](https://github.com/42wim/matterbridge) (7.4K stars, Apache-2.0, Go) — v1.26.0 stable
- **Script**: `matterbridge-helper.sh [setup|start|stop|status|logs|validate]`
- **Config**: `~/.config/aidevops/matterbridge.toml` (600 perms) | **Data**: `~/.aidevops/.agent-workspace/matterbridge/`
- **Requires**: Go 1.18+ (build) or pre-compiled binary

```bash
matterbridge-helper.sh setup          # Download binary + interactive config
matterbridge-helper.sh validate       # Validate config before starting
matterbridge-helper.sh start --daemon
```

<!-- AI-CONTEXT-END -->

## Security

**E2E encryption is broken at bridge boundaries** — the bridge host decrypts and re-encrypts (or sends plaintext) all messages. Run on a trusted, hardened host (NetBird/WireGuard). Avoid bridging sensitive channels to unencrypted platforms. Store credentials in gopass (`aidevops secret set MATTERBRIDGE_DISCORD_TOKEN`); config: `chmod 600 matterbridge.toml`. See `tools/security/opsec.md` for platform trust matrix.

## Supported Platforms

Discord, Gitter, IRC, Keybase, Matrix (E2E broken at bridge), Mattermost, Microsoft Teams (Azure app required), Mumble, Nextcloud Talk, Rocket.Chat, Slack, SSH-chat, Telegram, Twitch (chat only), VK, WhatsApp (whatsmeow multidevice — unofficial, ToS risk), XMPP, Zulip.

**3rd party via API**: SimpleX ([matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex)), Delta Chat (matterdelta), Minecraft (mattercraft, MatterBukkit).

## Installation

```bash
# Binary (replace linux-64bit with darwin-arm64 for Apple Silicon, darwin-64bit for Intel Mac)
curl -L https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-1.26.0-linux-64bit \
  -o /usr/local/bin/matterbridge && chmod +x /usr/local/bin/matterbridge
# Packages: snap install matterbridge | scoop install matterbridge
# Build from source (all bridges ~3GB RAM; -tags nomsteams ~500MB; add whatsappmulti for WhatsApp GPL3)
go install github.com/42wim/matterbridge
```

## Configuration

Config search order: `./matterbridge.toml`, `~/.config/aidevops/matterbridge.toml`, or `-conf /path/to/matterbridge.toml`. Three sections: **protocol blocks** (credentials per platform), **`[general]`** (global settings), **`[[gateway]]`** (bridge definitions).

> **Security**: Values below are `<PLACEHOLDER>` examples. Store actual tokens via `aidevops secret set NAME` (gopass). See `tools/credentials/gopass.md`.

```toml
# Protocol blocks — one per platform (see Platform-Specific Notes for all options)
[matrix.home]
Server="https://matrix.example.com"
Login="bridgebot"
Password="<MATRIX_PASSWORD>"
RemoteNickFormat="[{PROTOCOL}] <{NICK}> "
[discord.myserver]
Token="Bot <DISCORD_BOT_TOKEN>"
Server="My Discord Server"
[telegram.main]
Token="<TELEGRAM_BOT_TOKEN>"
[irc.libera]
Server="irc.libera.chat:6667"
Nick="matterbridge"
UseTLS=true
# Global + gateway
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
```

**Nick format variables**: `{NICK}`, `{PROTOCOL}`, `{BRIDGE}`, `{GATEWAY}`. **One-way bridges**: Use `[[gateway.in]]` / `[[gateway.out]]` instead of `[[gateway.inout]]`. Add more `[[gateway.inout]]` blocks for Telegram (`channel="-1001234567890"`), IRC, etc.

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

Not natively supported — use [matterbridge-simplex](https://github.com/simplex-chat/matterbridge-simplex): install SimpleX CLI, then `go install github.com/simplex-chat/matterbridge-simplex@latest && matterbridge-simplex --port 4242 --profile simplex-bridge`. Configure `[api.simplex]` with `BindAddress="0.0.0.0:4243"` and `Token=`, add `[[gateway]]` with `account="api.simplex"` / `channel="api"`. E2E encryption is broken at the bridge boundary.

## Running

```bash
matterbridge -conf matterbridge.toml -debug   # Foreground with debug
matterbridge -conf matterbridge.toml &         # Background
docker run -d --name matterbridge --restart unless-stopped \
  -v /path/to/matterbridge.toml:/etc/matterbridge/matterbridge.toml:ro 42wim/matterbridge:stable
```

**Systemd**: Unit with `Type=simple`, `User=matterbridge`, `ExecStart=/usr/local/bin/matterbridge -conf /etc/matterbridge/matterbridge.toml`, `Restart=on-failure`. Then `systemctl daemon-reload && systemctl enable --now matterbridge`.

## REST API

Add to config: `[api.myapi]` with `BindAddress="127.0.0.1:4242"`, `Token="<MATTERBRIDGE_API_TOKEN>"`, `Buffer=1000`.

```bash
# Send message
curl -X POST http://localhost:4242/api/message \
  -H "Authorization: Bearer <MATTERBRIDGE_API_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello from API", "username": "bot", "gateway": "mybridge"}'
# Read messages
curl http://localhost:4242/api/messages -H "Authorization: Bearer <MATTERBRIDGE_API_TOKEN>"
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

## Related

- `services/communications/matrix-bot.md`, `simplex.md`, `telegram.md`, `signal.md`, `whatsapp.md`, `slack.md`, `discord.md`, `msteams.md`, `nextcloud-talk.md`
- `services/communications/nostr.md`, `imessage.md`, `google-chat.md`, `urbit.md` — no native Matterbridge support; `bitchat.md` — Bluetooth mesh; `xmtp.md` — Web3 messaging; `tools/security/opsec.md` — platform trust matrix
