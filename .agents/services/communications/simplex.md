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
- **CLI install**: Download installer, verify, then execute (see [Installation](#installation))
- **Data**: `~/.simplex/` (SQLite: `simplex_v1_chat.db`, `simplex_v1_agent.db`)
- **Protocol**: SMP (messaging), XFTP (files), WebRTC (calls) — all E2E encrypted
- **Encryption**: Double ratchet (X3DH, Curve448) + NaCl crypto_box (Curve25519) + TLS 1.3
- **Docs**: https://simplex.chat/docs/ | https://github.com/simplex-chat/simplex-chat
- **Bot API docs**: https://github.com/simplex-chat/simplex-chat/tree/stable/bots

**Key differentiator**: SimpleX has no user identifiers at all — not even random ones. Connections are pairs of uni-directional message queues. No phone number, no username, no account. This makes it the strongest option for zero-knowledge communications.

**When to use SimpleX over Matrix**:

| Criterion | SimpleX | Matrix |
|-----------|---------|--------|
| User identifiers | None | `@user:server` |
| Server metadata | Stateless (memory only) | Full history stored |
| Phone/email required | No | Optional but common |
| Federation | Decentralized (no federation needed) | Federated |
| Bot ecosystem | Growing (WebSocket API) | Mature (SDK, bridges) |
| Group scalability | Experimental (1000+) | Production-grade |
| Best for | Maximum privacy, agent-to-agent comms | Team collaboration, bridges |

<!-- AI-CONTEXT-END -->

## Architecture

```text
SimpleX App (iOS/Android/Desktop/CLI)
    │ SimpleX Protocol (E2E encrypted, no user IDs)
    ▼
SMP Relay Servers (stateless, messages in memory only)
    │
SimpleX CLI (WebSocket server on port 5225)
    │ WebSocket JSON API
    ▼
Bot Process (TypeScript/Bun)
    ├─ Command router
    ├─ Event handler
    ├─ File/voice handler
    └─ aidevops dispatch
```

**Message flow**: Sender encrypts with double ratchet (X3DH + Curve448) → wrapped in NaCl crypto_box for SMP queue → sent via TLS 1.3 → 2-hop onion routing hides sender IP → relay deletes message from memory after delivery.

## Installation

### CLI (Linux/macOS)

```bash
curl -fsSLo simplex-install.sh https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh
less simplex-install.sh  # Review before executing
bash simplex-install.sh
simplex-chat --version
```

On macOS, allow Gatekeeper: System Settings > Privacy & Security > Allow.

### Mobile and Desktop Apps

| Platform | Link |
|----------|------|
| iOS | [App Store](https://apps.apple.com/app/simplex-chat/id1605771084) |
| Android | [Google Play](https://play.google.com/store/apps/details?id=chat.simplex.app) / [F-Droid](https://simplex.chat/fdroid/) / [APK](https://github.com/simplex-chat/simplex-chat/releases) |
| Linux | [Flathub](https://flathub.org/apps/chat.simplex.simplex) / [AppImage](https://github.com/simplex-chat/simplex-chat/releases) |
| macOS | [DMG](https://github.com/simplex-chat/simplex-chat/releases) |
| Windows | [MSI](https://github.com/simplex-chat/simplex-chat/releases) |

### Build from Source

```bash
git clone git@github.com:simplex-chat/simplex-chat.git && cd simplex-chat && git checkout stable
DOCKER_BUILDKIT=1 docker build --output ~/.local/bin .  # Docker (Linux)
# Or via Haskell: requires GHCup, GHC 9.6.3, cabal 3.10.1.0
cabal update && cabal install simplex-chat
```

## CLI Usage

```bash
simplex-chat                          # Start interactive chat
simplex-chat -d mybot                 # Custom database prefix
simplex-chat -s smp://fingerprint@smp.example.com  # Custom SMP server
simplex-chat -p 5225                  # Run as WebSocket server for bot API
simplex-chat -x                       # Access via Tor
simplex-chat --socks-proxy=127.0.0.1:9050
simplex-chat -p 5225 --create-bot-display-name "MyBot" --create-bot-allow-files
```

**Essential CLI commands**: `/c` (create invite), `/c <link>` (connect), `@<name> <msg>` (DM), `#<group> <msg>` (group), `/g <name>` (create group), `/a <group> <name>` (add member), `/f @<contact> <path>` (send file), `/ad` (create address), `/ac <name>` (accept request), `/help`

**Database**: `~/.simplex/` (Linux/macOS), `%APPDATA%/simplex` (Windows). SQLite WAL mode. Backup: copy both `.db` files while CLI is stopped.

## Bot API

### Starting the WebSocket Server

```bash
simplex-chat -p 5225
simplex-chat -p 5225 --create-bot-display-name "AIBot" --create-bot-allow-files
```

### Command / Event Format

Bot sends commands:

```json
{ "corrId": "1", "cmd": "/ad" }
```

CLI responds with correlated results:

```json
{ "corrId": "1", "resp": { "type": "userContactLinkCreated", "connLinkContact": { "connFullLink": "simplex:/contact#...", "connShortLink": "https://simplex.chat/c#..." } } }
```

CLI pushes events (no `corrId`):

```json
{ "resp": { "type": "newChatItems", "chatItems": [{ "chatItem": { "content": { "type": "rcvMsgContent", "msgContent": { "type": "text", "text": "/help" } } } }] } }
```

### Key Commands

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

Full reference: [API Commands](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/COMMANDS.md) | [API Events](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/EVENTS.md) | [API Types](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/api/TYPES.md)

### Essential Bot Events

| Event | Type Tag | When | Action |
|-------|----------|------|--------|
| Contact connected | `contactConnected` | User connects via address | Send welcome, store contactId |
| Business request | `acceptingBusinessRequest` | User connects via business address | New business chat created |
| New message | `newChatItems` | Message received | Parse and respond |
| Contact request | `receivedContactRequest` | Auto-accept off | Call `/_accept <id>` |
| File ready | `rcvFileDescrReady` | File incoming | Call `/freceive <fileId>` |
| File complete | `rcvFileComplete` | File downloaded | Process file |
| Group invitation | `receivedGroupInvitation` | Bot invited to group | Call `/_join #<groupId>` |

**Error events** (`messageError`, `chatError`, `chatErrors`): Log but do not fail — common network/delivery errors, not bot failures.

### ChatRef Syntax

| Prefix | Target | Example |
|--------|--------|---------|
| `@<contactId>` | Direct chat | `/_send @42 json [...]` |
| `#<groupId>` | Group chat | `/_send #7 json [...]` |
| `*<noteFolderId>` | Local notes | `/_send *1 json [...]` |

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
await chat.apiSendTextMessage(ChatType.Group, groupId, "Hello group!")

// Raw command (for commands not wrapped by SDK)
const resp = await chat.sendChatCmd(`/_show_address ${user.userId}`)

// Event loop
for await (const event of chat.msgQ) {
  switch (event.type) {
    case "contactConnected": /* send welcome */ break
    case "newChatItems": /* parse and respond */ break
  }
}
```

**Bun compatibility**: Use `bun:sqlite` instead of `better-sqlite3` to avoid native module compilation.

See: [TypeScript SDK README](https://github.com/simplex-chat/simplex-chat/tree/stable/packages/simplex-chat-client/typescript)

### Key Types

```typescript
type MsgContent =
  | { type: "text"; text: string }
  | { type: "image"; text: string; image: string }  // base64
  | { type: "file"; text: string }
  | { type: "voice"; text: string; duration: number }
  | { type: "link"; text: string; preview: { uri: string; title: string; description: string; image: string } }

interface ComposedMessage {
  fileSource?: { filePath: string; cryptoArgs?: Record<string, unknown> }
  quotedItemId?: number
  msgContent: MsgContent
  mentions: { [displayName: string]: number }
}

interface AddressSettings {
  businessAddress: boolean
  autoAccept?: { acceptIncognito: boolean }
  autoReply?: MsgContent
}

type GroupMemberRole = "observer" | "author" | "member" | "moderator" | "admin" | "owner"
```

### Bot Profile Configuration

**Requires CLI v6.4.3+.** Set `peerType: "bot"` to enable command highlighting, command menu UI, and bot badge.

```text
/create bot [files=on] <name>[ <bio>]
```

### Bot Command Menus

```text
/set bot commands 'Help':/help,'System Status':/status,'Ask AI':{'Quick question':/'ask <question>','Detailed analysis':/'analyze <topic>'},'DevOps':{'Run command':/'run <command>','Deploy':/'deploy <project>','View logs':/'logs <service>'}
```

Commands in messages are highlighted based on `/`. Bots can send tappable commands with parameters: `/'role 2'` (quotes hidden in UI, tapping sends `/role 2`).

### Important Bot API Constraints

- **No authentication on WebSocket API** — must run on localhost or behind TLS proxy with basic auth
- **Bot must tolerate unknown events** — ignore undocumented event types, allow additional JSON properties
- **File handling** — files stored on CLI's filesystem; bot accesses them via local path
- **Concurrent commands** — supported, but TypeScript SDK sends sequentially by default

## Business Addresses

Business addresses (v6.2+) create per-customer group chats — ideal for support bots.

1. Business creates a business address (special contact address)
2. Customer connects via the address → new business chat created (group under the hood)
3. Customer sees business name/logo; business sees customer name/avatar
4. Business can add team members to the conversation (escalation)

| Scenario | Implementation |
|----------|----------------|
| **Customer support** | Bot accepts requests, answers FAQs, escalates to humans |
| **Sales** | Per-customer private channel with sales rep |
| **Service delivery** | Automated status updates, file delivery |
| **Multi-agent support** | Bot triages, adds appropriate team member |

## Protocol Overview

**SMP**: No user identifiers — connections are pairs of uni-directional queues. Double ratchet (X3DH, Curve448) + NaCl crypto_box per-queue (Curve25519) + 2-hop onion routing + stateless servers (memory only) + TLS 1.3 + Ed448 server authentication.

**XFTP**: Files split into fixed-size chunks, padded, E2E encrypted, distributed across multiple relays. Efficient multi-recipient sending (upload once). 48-hour default retention.

**WebRTC**: E2E encrypted audio/video calls. ICE candidates exchanged via SMP. Self-hostable TURN/STUN. Available on mobile and desktop (not CLI).

**vs Signal**: SimpleX uses X3DH (Curve448) vs Signal's Curve25519, adds NaCl per-queue encryption, has no user identifiers (Signal requires phone number), and has built-in 2-hop onion routing.

## Voice, Files, and Calls

- **Voice messages**: Received via `NewChatItems` with file info. Send via `APISendMessages` with `MsgContent` type `voice`. Integration with speech-to-text: `.agents/tools/voice/speech-to-speech.md`
- **File transfer**: `/f @contact /path/to/file` (CLI) or `APISendMessages` with file attachment. Bot must share filesystem with CLI.
- **Calls**: WebRTC-based, mobile/desktop only. CLI does not support calls. Self-hosted TURN/STUN: `simplex.chat/docs/webrtc.html`

## Multi-Platform Usage

| Platform | Features | Notes |
|----------|----------|-------|
| **iOS/Android** | Full chat, calls, groups, files | App Store / Play Store |
| **Linux/macOS/Windows Desktop** | Full chat, calls, groups, files | Flathub / DMG / MSI |
| **Terminal CLI** | Chat, groups, files, bot API | No calls, no GUI |

**Incognito mode**: Random profile name per connection/group join. Real profile never shared.

**Multiple profiles**: Single app can have multiple chat profiles with separate contacts, groups, and settings.

## Cross-Device Workarounds

**Core limitation**: SimpleX cannot sync a profile across multiple devices simultaneously.

### Workaround 1: Remote Control Protocol (XRCP)

```bash
# 1. On server: run CLI
simplex-chat -p 5225

# 2. On desktop app: Settings > Developer Tools > Enable
# 3. Desktop app: Linked Mobile > + Link a Mobile > local address 127.0.0.1, port 12345 > copy link

# 4. SSH tunnel from desktop to server
ssh -R 12345:127.0.0.1:12345 -N user@server

# 5. In CLI on server:
/crc <link>
/verify remote ctrl <code>
```

### Workaround 2: Cloud CLI + tmux

```bash
useradd -m -s /bin/bash simplex-cli
tmux new -s simplex-cli
su - simplex-cli && simplex-chat -p 5225
# Detach: Ctrl+B D | Reattach: tmux attach -t simplex-cli
```

### Workaround 3: Database Migration

Settings > Database > Export → transfer → Settings > Database > Import. **Warning**: Running the same database on two devices simultaneously causes message delivery failures and potential data corruption.

## Self-Hosted Servers

### SMP Server (Message Relay)

**Requirements**: VPS with domain name, ports 443 + 5223 open.

```bash
curl --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh \
  -o simplex-server-install.sh
less simplex-server-install.sh && bash simplex-server-install.sh  # Choose option 1

su smp -c 'smp-server init --yes --store-log --control-port --fqdn=smp.example.com'
systemctl enable --now smp-server.service
cat /etc/opt/simplex/fingerprint
```

Server address format: `smp://<fingerprint>[:<password>]@<hostname>[,<onion>]`

**Docker deployment**:

```bash
mkdir smp-server && cd smp-server
cat > .env <<'EOF'
ADDR=smp.example.com
EOF
curl -fsSL https://raw.githubusercontent.com/simplex-chat/simplexmq/refs/heads/stable/scripts/docker/docker-compose-smp-complete.yml -o docker-compose.yml
docker compose up -d
```

**Security best practices**: Initialize offline, move CA key to secure storage, rotate online certs every 3 months, enable Tor hidden service, use Caddy for TLS termination, enable `control_port` for monitoring.

> **Development only**: `--no-password` disables server password authentication. Never use in production.

### XFTP Server (File Relay)

```bash
# Install via same script, choose option 2
su xftp -c 'xftp-server init -l --fqdn=xftp.example.com -q 100gb -p /srv/xftp/'
systemctl enable --now xftp-server.service
```

Server address format: `xftp://<fingerprint>[:<password>]@<hostname>[,<onion>]`

**Configuring apps**: Settings > Network & Servers > SMP/XFTP Servers > Add server address. Note: changing servers only affects new connections.

## Upstream Contributions

SimpleX Chat is AGPL-3.0 licensed. **AGPLv3 server requirement**: If you modify and run an SMP/XFTP server, you must publish your source code.

| Repository | Purpose |
|------------|---------|
| [simplex-chat](https://github.com/simplex-chat/simplex-chat) | Chat apps, CLI, bot API, TypeScript SDK |
| [simplexmq](https://github.com/simplex-chat/simplexmq) | SMP/XFTP servers and protocol libraries |

Contributing: fork → branch from `stable` (not `master`) → follow code style → submit PR. See [contributing guide](https://simplex.chat/docs/contributing.html).

When encountering SimpleX limitations during aidevops usage, log them at `~/.aidevops/.agent-workspace/work/simplex/upstream-feedback.md` for potential upstream contribution.

## Limitations

- **Cross-device**: Cannot sync profile across multiple devices simultaneously. See [Cross-Device Workarounds](#cross-device-workarounds).
- **Single profile per instance**: One active profile per CLI process. Workaround: multiple CLI instances with different database prefixes (`-d bot1`, `-d bot2`) on different ports.
- **Owner role recovery**: If group owner profile is lost, owner role cannot be recovered. Mitigation: add backup owner before primary is lost.
- **Group stability**: Decentralized groups can have delayed delivery, member list desync, and scalability limits (1000+ members experimental).
- **No server-side search**: All messages E2E encrypted. Local search available in mobile/desktop apps but not CLI.
- **Bot WebSocket API security**: No built-in authentication. Must use TLS-terminating reverse proxy + HTTP basic auth + firewall restriction.
- **XFTP file limits**: Practical limits depend on server storage quota and 48-hour default retention.
- **AGPL-3.0 SDK license**: Bot code importing the SDK must be AGPL-3.0 compatible or use the raw WebSocket API directly. Internal-only bots are not affected by AGPL's source disclosure requirement.
- **Push notifications**: Optional via Apple/Google services — privacy trade-off (push service learns message timing). Alternative: periodic background fetch.

## Matterbridge Integration

[matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) bridges SimpleX to 40+ platforms via [Matterbridge](https://github.com/42wim/matterbridge). Uses same WebSocket API as bots. Bridges contact and group chats. Docker-compose deployment (3 containers). `/hide` prefix for SimpleX-only messages. Requires matterbridge >1.26.0. MIT licensed.

See `t1328` for full Matterbridge integration task.

## Security Considerations

**Threat model**: SimpleX protects against server compromise (E2E encrypted), network surveillance (2-hop onion routing), identity correlation (no user identifiers), and traffic analysis (message padding, queue rotation). Does **not** protect against device compromise, endpoint metadata (timing analysis), or social engineering.

**Bot security model**:

1. Treat all inbound messages as untrusted input — sanitize before passing to AI models
2. DM pairing — require approval before processing messages from unknown contacts
3. Command sandboxing — bot commands should run in restricted environments
4. Credential isolation — never expose secrets to chat context or tool output
5. Leak detection — scan outbound messages for credential patterns before sending
6. Per-group permissions — different groups can have different command access levels

**Operational security**: Use Tor (`-x`), self-host SMP/XFTP servers, enable database passphrase, use incognito mode for sensitive connections, rotate contact addresses periodically, back up database securely.

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

**Slash command coexistence**: SimpleX bot commands (`/help`, `/status`) and aidevops commands (`/define`, `/pr`) both use `/` but operate in separate contexts (chat vs terminal). No technical conflict.

## Related

- `.agents/services/communications/matrix-bot.md` — Matrix messaging integration
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice note transcription
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- SimpleX Docs: https://simplex.chat/docs/
- SimpleX Bot API: https://github.com/simplex-chat/simplex-chat/tree/stable/bots
- SimpleX Whitepaper: https://github.com/simplex-chat/simplexmq/blob/stable/protocol/overview-tjr.md
- Matterbridge-SimpleX: https://github.com/UnkwUsr/matterbridge-simplex
