---
description: SimpleX Chat — install, bot API (TypeScript SDK + CLI), business addresses, SMP/XFTP self-hosted servers, protocol overview, voice/files, multi-platform, cross-device workarounds, and limitations
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

# SimpleX Chat

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized encrypted messaging — no user identifiers, no phone numbers, no central servers
- **License**: AGPL-3.0 (client, servers, and TypeScript SDK)
- **Apps**: iOS, Android, Desktop (Linux/macOS/Windows), Terminal CLI
- **Bot API**: WebSocket JSON API via CLI (`simplex-chat -p 5225`)
- **TypeScript SDK**: `simplex-chat` + `@simplex-chat/types` (npm)
- **Data**: `~/.simplex/` (SQLite: `simplex_v1_chat.db`, `simplex_v1_agent.db`)
- **Protocol**: SMP (messaging), XFTP (files), WebRTC (calls) — all E2E encrypted
- **Encryption**: Double ratchet (X3DH, Curve448) + NaCl crypto_box (Curve25519) + TLS 1.3
- **Docs**: https://simplex.chat/docs/ | https://github.com/simplex-chat/simplex-chat
- **Bot API docs**: https://github.com/simplex-chat/simplex-chat/tree/stable/bots

**Key differentiator**: No user identifiers — not even random ones. Connections are pairs of uni-directional queues. Strongest option for zero-knowledge communications. Use over Matrix when: maximum privacy needed, no phone/email, agent-to-agent comms. Use Matrix when: team collaboration, bridges to other platforms, production-grade groups.

<!-- AI-CONTEXT-END -->

## Installation

### CLI (Linux/macOS)

```bash
curl -fsSLo simplex-install.sh https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh
less simplex-install.sh  # Review before executing
bash simplex-install.sh
```

On macOS: System Settings > Privacy & Security > Allow (Gatekeeper).

**Apps**: [iOS](https://apps.apple.com/app/simplex-chat/id1605771084) | [Android](https://play.google.com/store/apps/details?id=chat.simplex.app) / [F-Droid](https://simplex.chat/fdroid/) | [Linux Flathub](https://flathub.org/apps/chat.simplex.simplex) | [macOS DMG / Windows MSI / AppImage](https://github.com/simplex-chat/simplex-chat/releases)

Build from source: `git clone git@github.com:simplex-chat/simplex-chat.git && git checkout stable` then Docker (`DOCKER_BUILDKIT=1 docker build --output ~/.local/bin .`) or Haskell (`cabal install simplex-chat`, requires GHC 9.6.3).

## CLI Usage

```bash
simplex-chat -p 5225                  # WebSocket server for bot API
simplex-chat -d mybot                 # Custom database prefix
simplex-chat -s smp://fingerprint@smp.example.com  # Custom SMP server
simplex-chat -x                       # Tor; --socks-proxy=127.0.0.1:9050
simplex-chat -p 5225 --create-bot-display-name "MyBot" --create-bot-allow-files
```

**Essential commands**: `/c` (create invite), `/c <link>` (connect), `@<name> <msg>` (DM), `#<group> <msg>` (group), `/g <name>` (create group), `/a <group> <name>` (add member), `/f @<contact> <path>` (send file), `/ad` (create address), `/ac <name>` (accept request), `/help`

**Database**: `~/.simplex/` (Linux/macOS), `%APPDATA%/simplex` (Windows). SQLite WAL mode. Backup: copy both `.db` files while CLI is stopped.

## Bot API

### Command / Event Format

Bot sends: `{ "corrId": "1", "cmd": "/ad" }` — CLI responds with matching `corrId`. CLI pushes events without `corrId`.

Full reference: [Commands](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/COMMANDS.md) | [Events](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/EVENTS.md) | [Types](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/TYPES.md)

### Key API Commands

| Command | Network | Description |
|---------|---------|-------------|
| `CreateActiveUser` | no | Create user profile |
| `APIUpdateProfile` | background | Update profile (set `peerType: "bot"`) |
| `APICreateMyAddress` | interactive | Create long-term address |
| `APIAcceptContact` | interactive | Accept incoming contact request |
| `APISendMessages` | background | Send message(s) |
| `APINewGroup` | no | Create group |
| `APIAddMember` | interactive | Add member to group |
| `APISetContactPrefs` | background | Set per-contact preferences |

### Essential Bot Events

| Event type tag | When | Action |
|----------------|------|--------|
| `contactConnected` | User connects via address | Send welcome, store contactId |
| `acceptingBusinessRequest` | User connects via business address | New business chat created |
| `newChatItems` | Message received | Parse and respond |
| `receivedContactRequest` | Auto-accept off | Call `/_accept <id>` |
| `rcvFileDescrReady` | File incoming | Call `/freceive <fileId>` |
| `rcvFileComplete` | File downloaded | Process file |
| `receivedGroupInvitation` | Bot invited to group | Call `/_join #<groupId>` |

**Error events** (`messageError`, `chatError`, `chatErrors`): Log but do not fail — common network/delivery errors.

### ChatRef Syntax

`@<contactId>` (DM), `#<groupId>` (group), `*<noteFolderId>` (local notes). Example: `/_send @42 json [...]`

### TypeScript SDK

```bash
npm install simplex-chat @simplex-chat/types
```

```typescript
import {ChatClient} from "simplex-chat"
import {ChatType} from "simplex-chat/dist/command"

const chat = await ChatClient.create("ws://localhost:5225")
const user = await chat.apiGetActiveUser()
const address = await chat.apiGetUserAddress(user.userId)
  || await chat.apiCreateUserAddress(user.userId)
await chat.enableAddressAutoAccept()
await chat.apiSendTextMessage(ChatType.Direct, contactId, "Hello!")

for await (const event of chat.msgQ) {
  switch (event.type) {
    case "contactConnected": /* send welcome */ break
    case "newChatItems": /* parse and respond */ break
  }
}
```

**Bun**: Use `bun:sqlite` instead of `better-sqlite3`. See: [TypeScript SDK README](https://github.com/simplex-chat/simplex-chat/tree/stable/packages/simplex-chat-client/typescript)

**Key types**: `MsgContent` union (`text`, `image` base64, `file`, `voice` with duration, `link` with preview). `ComposedMessage` has `fileSource`, `quotedItemId`, `msgContent`, `mentions`. `AddressSettings` has `businessAddress`, `autoAccept`, `autoReply`. `GroupMemberRole`: `observer | author | member | moderator | admin | owner`. Full types: [API Types](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/TYPES.md)

### Bot Profile and Command Menus

**Requires CLI v6.4.3+.** Set `peerType: "bot"` for command highlighting, menu UI, and bot badge.

```text
/create bot [files=on] <name>[ <bio>]
/set bot commands 'Help':/help,'Status':/status,'Ask AI':{'Quick':/'ask <q>','Detailed':/'analyze <topic>'}
```

Tappable commands with hidden params: `/'role 2'` (UI shows `/role 2`, tapping sends it).

### Bot API Constraints

- **No WebSocket auth** — run on localhost or behind TLS proxy with basic auth + firewall
- **Tolerate unknown events** — ignore undocumented types, allow extra JSON properties
- **File handling** — files on CLI's filesystem; bot accesses via local path
- **Concurrent commands** — supported; TypeScript SDK sends sequentially by default

## Business Addresses

Business addresses (v6.2+) create per-customer group chats. Customer connects → new business chat (group under the hood). Business sees customer avatar; can add team members for escalation. Use cases: customer support, sales channels, service delivery, multi-agent triage.

## Protocol

**SMP**: Pairs of uni-directional queues. Double ratchet (X3DH, Curve448) + NaCl crypto_box (Curve25519) + 2-hop onion routing + stateless servers (memory only) + TLS 1.3 + Ed448 server auth.

**XFTP**: Files split into fixed-size chunks, padded, E2E encrypted, distributed across relays. Upload once, multi-recipient. 48-hour default retention.

**WebRTC**: E2E encrypted calls. ICE via SMP. Mobile/desktop only (not CLI). Self-hostable TURN/STUN: `simplex.chat/docs/webrtc.html`

**Voice/files**: Voice received via `newChatItems` with file info; send via `APISendMessages` with `MsgContent` type `voice`. Speech-to-text: `.agents/tools/voice/speech-to-speech.md`. File transfer: `/f @contact /path` (CLI) or `APISendMessages` with attachment (bot must share filesystem with CLI).

## Cross-Device Workarounds

**Core limitation**: Cannot sync a profile across multiple devices simultaneously.

**Option 1 — XRCP**: Run CLI on server (`simplex-chat -p 5225`), enable Developer Tools in desktop app, SSH tunnel (`ssh -R 12345:127.0.0.1:12345 -N user@server`), then in CLI: `/crc <link>` + `/verify remote ctrl <code>`.

**Option 2 — Cloud CLI + tmux**: `useradd -m simplex-cli && tmux new -s simplex-cli && su - simplex-cli && simplex-chat -p 5225`. Detach: Ctrl+B D. Reattach: `tmux attach -t simplex-cli`.

**Option 3 — Database migration**: Settings > Database > Export → transfer → Import. **Warning**: Same database on two devices simultaneously causes delivery failures and data corruption.

## Self-Hosted Servers

Requirements: VPS, domain, ports 443 + 5223 (SMP) open.

```bash
# Install (choose option 1=SMP, 2=XFTP)
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh -o simplex-server-install.sh
less simplex-server-install.sh && bash simplex-server-install.sh

# SMP init
su smp -c 'smp-server init --yes --store-log --control-port --fqdn=smp.example.com'
systemctl enable --now smp-server.service && cat /etc/opt/simplex/fingerprint

# XFTP init
su xftp -c 'xftp-server init -l --fqdn=xftp.example.com -q 100gb -p /srv/xftp/'
systemctl enable --now xftp-server.service
```

Address formats: `smp://<fingerprint>[:<password>]@<hostname>[,<onion>]` | `xftp://<fingerprint>[:<password>]@<hostname>[,<onion>]`

Docker (SMP): set `ADDR=smp.example.com` in `.env`, fetch `docker-compose-smp-complete.yml` from simplexmq stable, `docker compose up -d`.

**Security**: Initialize offline, move CA key to secure storage, rotate certs every 3 months, enable Tor, use Caddy for TLS, enable `control_port`. Never use `--no-password` in production.

Add to apps: Settings > Network & Servers > SMP/XFTP Servers > Add. Only affects new connections.

## Limitations

- **Cross-device**: No simultaneous multi-device sync. See [Cross-Device Workarounds](#cross-device-workarounds).
- **Single profile per instance**: Multiple CLI instances need separate DB prefixes (`-d bot1`, `-d bot2`) on different ports.
- **Owner role recovery**: Lost group owner profile cannot be recovered. Add backup owner proactively.
- **Group stability**: Delayed delivery, member list desync, 1000+ members experimental.
- **No server-side search**: All messages E2E encrypted. Local search in mobile/desktop only.
- **Bot WebSocket security**: No built-in auth. Require TLS reverse proxy + HTTP basic auth + firewall.
- **XFTP file limits**: Depends on server storage quota and 48-hour default retention.
- **AGPL-3.0 SDK**: Bot code importing SDK must be AGPL-3.0 compatible or use raw WebSocket API. Internal-only bots exempt from source disclosure.
- **Push notifications**: Optional via Apple/Google — privacy trade-off. Alternative: periodic background fetch.

## Security

**Threat model**: Protects against server compromise (E2E), network surveillance (2-hop onion), identity correlation (no IDs), traffic analysis (padding, queue rotation). Does **not** protect against device compromise, timing analysis, or social engineering.

**Bot security**: (1) sanitize all inbound before AI models, (2) require DM approval for unknown contacts, (3) sandbox commands, (4) isolate credentials from chat context, (5) scan outbound for credential patterns, (6) per-group command permissions.

**Opsec**: Use Tor (`-x`), self-host SMP/XFTP, enable database passphrase, incognito mode, rotate contact addresses, back up database securely.

## Integration with aidevops

| Component | File | Task |
|-----------|------|------|
| Subagent doc | `.agents/services/communications/simplex.md` | t1327.2 |
| Helper script | `.agents/scripts/simplex-helper.sh` | t1327.3 |
| Bot framework | `.agents/scripts/simplex-bot/` (TypeScript/Bun) | t1327.4 |
| Mailbox transport | `.agents/scripts/mail-helper.sh` | t1327.5 |
| Opsec agent | `.agents/tools/security/opsec.md` | t1327.6 |
| Prompt injection defense | `.agents/scripts/prompt-guard-helper.sh` | t1327.8 |
| Outbound leak detection | `.agents/scripts/simplex-bot/src/leak-detector.ts` | t1327.9 |
| Exec approval flow | `.agents/scripts/simplex-bot/src/approval.ts` | t1327.10 |

**Slash command coexistence**: SimpleX `/help`, `/status` and aidevops `/define`, `/pr` both use `/` but operate in separate contexts. No conflict.

**Matterbridge** (t1328): [matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) bridges to 40+ platforms. Docker-compose (3 containers). Requires matterbridge >1.26.0. MIT licensed.

**Upstream**: Log limitations at `~/.aidevops/.agent-workspace/work/simplex/upstream-feedback.md`. AGPL-3.0: modified SMP/XFTP servers require source publication. Contributing: fork → branch from `stable` → PR → [contributing guide](https://simplex.chat/docs/contributing.html).

## Related

- `.agents/services/communications/matrix-bot.md` — Matrix messaging integration
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice note transcription
- SimpleX Docs: https://simplex.chat/docs/
- SimpleX Whitepaper: https://github.com/simplex-chat/simplexmq/blob/stable/protocol/overview-tjr.md
- Matterbridge-SimpleX: https://github.com/UnkwUsr/matterbridge-simplex
