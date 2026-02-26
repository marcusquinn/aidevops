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
┌──────────────────────┐
│ SimpleX Mobile/       │
│ Desktop App           │
│ (iOS, Android,        │
│  Linux, macOS, Win)   │
└──────────┬───────────┘
           │ SimpleX Protocol (E2E encrypted)
           │ No user IDs — uni-directional queues
           │
┌──────────▼───────────┐     ┌──────────────────────┐
│ SMP Relay Servers     │     │ XFTP Relay Servers    │
│ (stateless, messages  │     │ (file chunks, padded  │
│  in memory only)      │     │  E2E encrypted)       │
└──────────┬───────────┘     └──────────────────────┘
           │
┌──────────▼───────────┐
│ SimpleX CLI            │
│ (WebSocket server      │
│  on port 5225)         │
└──────────┬───────────┘
           │ WebSocket JSON API
           │
┌──────────▼───────────┐
│ Bot Process            │
│ (TypeScript/Bun)       │
│                        │
│ ├─ Command router      │
│ ├─ Event handler       │
│ ├─ File/voice handler  │
│ └─ aidevops dispatch   │
└────────────────────────┘
```

**Message flow**:

1. Sender's app encrypts message with double ratchet (X3DH + Curve448)
2. Message wrapped in NaCl crypto_box for the SMP queue (Curve25519)
3. Sent via TLS 1.3 to sender's chosen SMP relay
4. 2-hop onion routing hides sender IP from recipient's relay
5. Recipient's app retrieves from their relay, decrypts both layers
6. Relay deletes message from memory after delivery

## Installation

### CLI (Linux/macOS)

```bash
# Download installer (recommended: download, review, then execute)
curl -fsSLo simplex-install.sh https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh

# Review before executing
less simplex-install.sh

# Execute
bash simplex-install.sh

# Verify installation
simplex-chat --version
```

> **Convenience alternative** (skips review — use only if you trust the source):
>
> ```bash
> curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash
> # or: wget -qO- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash
> ```

On macOS, allow Gatekeeper: System Settings > Privacy & Security > Allow.

### CLI (Windows)

Download the binary from [latest release](https://github.com/simplex-chat/simplex-chat/releases) and move to `%APPDATA%/local/bin/simplex-chat.exe`.

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
git clone git@github.com:simplex-chat/simplex-chat.git
cd simplex-chat
git checkout stable

# Docker (Linux)
DOCKER_BUILDKIT=1 docker build --output ~/.local/bin .

# Or via Haskell (any OS) — requires GHCup, GHC 9.6.3, cabal 3.10.1.0
cabal update && cabal install simplex-chat
```

## CLI Usage

### Running

```bash
# Start interactive chat (default data in ~/.simplex/)
simplex-chat

# Custom database prefix
simplex-chat -d mybot

# Custom SMP server
simplex-chat -s smp://fingerprint@smp.example.com

# Run as WebSocket server for bot API
simplex-chat -p 5225

# Access via Tor
simplex-chat -x

# Custom SOCKS proxy
simplex-chat --socks-proxy=127.0.0.1:9050

# Create bot profile on first run
simplex-chat -p 5225 --create-bot-display-name "MyBot" --create-bot-allow-files

# See all options
simplex-chat -h
```

### Essential Commands

| Command | Description |
|---------|-------------|
| `/c` | Create one-time invitation link |
| `/c <link>` | Accept invitation / connect to address |
| `@<name> <msg>` | Send message to contact |
| `#<group> <msg>` | Send message to group |
| `/g <name>` | Create group |
| `/a <group> <name>` | Add contact to group |
| `/f @<contact> <path>` | Send file to contact |
| `/f #<group> <path>` | Send file to group |
| `/ad` | Create long-term contact address |
| `/ac <name>` | Accept connection request |
| `/rc <name>` | Reject connection request |
| `/help` | Show all commands |
| `/help groups` | Group commands |
| `/help files` | File commands |
| `/help address` | Address commands |

### Database

- **Location**: `~/.simplex/` (Linux/macOS), `%APPDATA%/simplex` (Windows)
- **Files**: `simplex_v1_chat.db` (messages, contacts), `simplex_v1_agent.db` (protocol state)
- **Engine**: SQLite with WAL mode
- **Encryption**: Optional database passphrase (configurable in app settings)
- **Backup**: Copy both `.db` files while CLI is stopped, or use app export

## Bot API

### Overview

SimpleX CLI runs as a local WebSocket server. Bots connect as standalone processes and exchange JSON messages. This is the officially supported integration method — no need to reimplement the SMP protocol.

### Starting the WebSocket Server

```bash
# Start CLI as WebSocket server on port 5225
simplex-chat -p 5225

# With bot profile creation on first run
simplex-chat -p 5225 --create-bot-display-name "AIBot" --create-bot-allow-files
```

### Command Format

Bot sends commands to CLI:

```json
{
  "corrId": "1",
  "cmd": "/ad"
}
```

CLI responds with correlated results:

```json
{
  "corrId": "1",
  "resp": {
    "type": "userContactLinkCreated",
    "connLinkContact": {
      "connFullLink": "simplex:/contact#...",
      "connShortLink": "https://simplex.chat/c#..."
    }
  }
}
```

### Event Format

CLI pushes events (no `corrId`):

```json
{
  "resp": {
    "type": "newChatItems",
    "chatItems": [
      {
        "chatItem": {
          "content": {
            "type": "rcvMsgContent",
            "msgContent": {
              "type": "text",
              "text": "/help"
            }
          }
        }
      }
    ]
  }
}
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
| Member joined | `joinedGroupMember` | New group member | Optional: welcome |
| Member removed | `deletedMemberUser` | Bot removed from group | Cleanup |

**Error events** (`messageError`, `chatError`, `chatErrors`): Log but do not fail — these are common network/delivery errors, not bot failures.

### ChatRef Syntax

Commands use these prefixes to target chats:

| Prefix | Target | Example |
|--------|--------|---------|
| `@<contactId>` | Direct chat | `/_send @42 json [...]` |
| `#<groupId>` | Group chat | `/_send #7 json [...]` |
| `*<noteFolderId>` | Local notes | `/_send *1 json [...]` |

### Network Usage Classification

| Classification | Behaviour | Examples |
|----------------|-----------|----------|
| `no` | Instant, no network | List contacts, get profile |
| `interactive` | Waits for network before responding | Connect, create address |
| `background` | Responds immediately, network async | Send message, delete chat |

### TypeScript SDK

```bash
npm install simplex-chat @simplex-chat/types
```

The SDK provides a typed WebSocket client with sequential command queue and typed event handling.

```typescript
import {ChatClient} from "simplex-chat"
import {ChatType} from "simplex-chat/dist/command"

// Connect to CLI WebSocket server
const chat = await ChatClient.create("ws://localhost:5225")

// Get active user
const user = await chat.apiGetActiveUser()

// Get or create address (userId required by SDK)
const address = await chat.apiGetUserAddress(user.userId)
  || await chat.apiCreateUserAddress(user.userId)

// Enable auto-accept for incoming contacts
await chat.enableAddressAutoAccept()

// Send text message to contact or group (use ChatType enum)
const contactId = 1  // obtained from contactConnected event
const groupId = 1    // obtained from joinedGroupMember event
await chat.apiSendTextMessage(ChatType.Direct, contactId, "Hello!")
await chat.apiSendTextMessage(ChatType.Group, groupId, "Hello group!")

// Raw command (for commands not wrapped by SDK)
const resp = await chat.sendChatCmd(`/_show_address ${user.userId}`)

// Event loop — process incoming messages (runs indefinitely)
for await (const event of chat.msgQ) {
  switch (event.type) {
    case "contactConnected":
      // New contact connected — send welcome
      break
    case "newChatItems":
      // Message received — parse and respond
      break
  }
}
```

**Bun compatibility**: Bun has native WebSocket — `isomorphic-ws` (SDK dependency) uses the native impl. Use `bun:sqlite` for session storage instead of `better-sqlite3` to avoid native module compilation.

See: [TypeScript SDK README](https://github.com/simplex-chat/simplex-chat/tree/stable/packages/simplex-chat-client/typescript)

### Key Types

```typescript
// Subset of types from @simplex-chat/types — see upstream for full definitions.
// Placeholders for types defined in @simplex-chat/types
type LinkPreview = { uri: string; title: string; description: string; image: string }
type CryptoFile = { filePath: string; cryptoArgs?: object }

// MsgContent — discriminated union (common variants; upstream also has video, report, chat, unknown)
type MsgContent =
  | { type: "text"; text: string }
  | { type: "image"; text: string; image: string }  // base64
  | { type: "file"; text: string }
  | { type: "voice"; text: string; duration: number }
  | { type: "link"; text: string; preview: LinkPreview }

// ComposedMessage — for APISendMessages
interface ComposedMessage {
  fileSource?: CryptoFile
  quotedItemId?: number   // int64
  msgContent: MsgContent
  mentions: { [displayName: string]: number }  // groupMemberId (int64)
}

// ChatBotCommand — for bot menus
type ChatBotCommand =
  | { type: "command"; keyword: string; label: string; params?: string }
  | { type: "menu"; label: string; commands: ChatBotCommand[] }

// AddressSettings
interface AddressSettings {
  businessAddress: boolean
  autoAccept?: { acceptIncognito: boolean }
  autoReply?: MsgContent
}

// GroupMemberRole
type GroupMemberRole = "observer" | "author" | "member" | "moderator" | "admin" | "owner"
```

### Bot Profile Configuration

**Requires CLI v6.4.3+.** Distinguish bot from regular user by setting `peerType: "bot"` in the profile. This enables:

- Command highlighting in messages (text starting with `/`)
- Command menu UI when users type `/` or tap `//` button
- Bot badge on profile

Set via CLI:

```text
/create bot [files=on] <name>[ <bio>]
```

Or via `APIUpdateProfile` command with `peerType` field.

### Bot Command Menus

Configure hierarchical command menus visible to users:

```text
/set bot commands 'Help':/help,'System Status':/status,'Ask AI':{'Quick question':/'ask <question>','Detailed analysis':/'analyze <topic>'},'DevOps':{'Run command':/'run <command>','Deploy':/'deploy <project>','View logs':/'logs <service>'},'Tasks':{'New task':/'task <description>','List tasks':/tasks}
```

This creates a tappable menu hierarchy — similar to Telegram inline keyboards but using SimpleX's native command menu system.

Commands in messages are highlighted based on the `/` character. Bots can send highlighted commands with parameters by surrounding them in single quotes: `/'role 2'` (quotes hidden in UI, tapping sends `/role 2`).

Configure different commands per contact via `APISetContactPrefs`.

### Important Bot API Constraints

- **No authentication on WebSocket API** — must run on localhost or behind TLS proxy with basic auth
- **Bot must tolerate unknown events** — ignore undocumented event types, allow additional JSON properties
- **File handling** — files stored on CLI's filesystem; bot accesses them via local path
- **Concurrent commands** — supported, but TypeScript SDK sends sequentially by default
- **Network usage** — some commands complete before response ("interactive"), others respond before network ("background")

## Business Addresses

Business addresses (v6.2+) create per-customer group chats — ideal for support bots.

### How It Works

1. Business creates a business address (special contact address)
2. Customer connects via the address
3. A new business chat is created (group under the hood)
4. Customer sees business name/logo; business sees customer name/avatar
5. Business can add team members to the conversation (escalation)
6. Bot commands configured on the business profile are available to customers

### Use Cases

| Scenario | Implementation |
|----------|----------------|
| **Customer support** | Bot accepts requests, answers FAQs, escalates to humans |
| **Sales** | Per-customer private channel with sales rep |
| **Service delivery** | Automated status updates, file delivery |
| **Multi-agent support** | Bot triages, adds appropriate team member |

### Setup

```bash
# Create business profile in CLI
simplex-chat -p 5225

# In CLI, create business address
/ad

# Share the generated link publicly
# Customers connect via the link
# Each connection creates a new business chat
```

Bot can automate acceptance of business connections and initial responses. Configure auto-accept and welcome message in app settings or programmatically via API.

## Protocol Overview

### SimpleX Messaging Protocol (SMP)

- **No user identifiers** — connections are pairs of uni-directional queues
- **Double ratchet** with X3DH key agreement (Curve448) + AES-GCM encryption
- **NaCl crypto_box** per-queue encryption (Curve25519) — second encryption layer
- **2-hop onion routing** — sender's IP hidden from recipient's server (even without Tor)
- **Stateless servers** — messages held in memory only, deleted after delivery
- **Queue rotation** — connections periodically rotate to fresh queues on potentially different servers
- **TLS 1.3** transport encryption with Ed448 server authentication
- **Message integrity** — digests of previous messages included for validation

### XFTP (File Transfer)

- Separate protocol for file transfer
- Files split into fixed-size chunks, padded, E2E encrypted
- Chunks distributed across multiple XFTP relays
- Recipient assembles chunks back into original file
- Efficient multi-recipient sending (upload once)
- No identifiers or ciphertext in common between sent and received traffic

### WebRTC (Audio/Video Calls)

- E2E encrypted audio and video calls
- ICE candidates exchanged via the chat protocol (SMP)
- Supports TURN/STUN relay servers (self-hostable)
- Available on mobile and desktop apps

### Comparison with Signal Protocol

| Aspect | SimpleX | Signal |
|--------|---------|--------|
| Key agreement | X3DH (Curve448) | X3DH (Curve25519) |
| Ratchet | Double ratchet | Double ratchet |
| Additional encryption | NaCl per-queue | None |
| Transport | Custom SMP + TLS 1.3 | Custom + TLS |
| User identifiers | None | Phone number |
| Server metadata | Minimal (stateless) | Moderate (sealed sender) |
| Onion routing | Built-in 2-hop | Not built-in |

## Voice, Files, and Calls

### Voice Messages

- Sent as file attachments (audio format)
- Bot receives voice notes via `NewChatItems` event with file info
- Bot can download the file from CLI's local filesystem
- Sending voice notes requires encoding audio to the expected format and attaching via `APISendMessages` with `MsgContent` type `voice` — there is no dedicated voice API
- Integration with speech-to-text for transcription (see `.agents/tools/voice/speech-to-speech.md`)

### File Transfer

```bash
# CLI: send file to contact
/f @contact /path/to/file

# CLI: send file to group
/f #group /path/to/file
```

Bot API: use `APISendMessages` with file attachment. Files are stored on CLI's filesystem — bot must have access to the same filesystem.

### Audio/Video Calls

- WebRTC-based, E2E encrypted
- Available on mobile and desktop apps
- CLI does not support calls directly
- Self-hosted TURN/STUN servers supported (see `simplex.chat/docs/webrtc.html`)

## Multi-Platform Usage

### Supported Platforms

| Platform | Features | Notes |
|----------|----------|-------|
| **iOS** | Full chat, calls, groups, files | App Store |
| **Android** | Full chat, calls, groups, files | Play Store, F-Droid, APK |
| **Linux Desktop** | Full chat, calls, groups, files | Flathub, AppImage |
| **macOS Desktop** | Full chat, calls, groups, files | DMG |
| **Windows Desktop** | Full chat, calls, groups, files | MSI |
| **Terminal CLI** | Chat, groups, files, bot API | No calls, no GUI |

### Incognito Mode

When enabled, a random profile name is generated for each new connection or group join. The real profile is never shared. This is independent of chat profiles — it works across all profiles.

### Multiple Chat Profiles

A single app installation can have multiple chat profiles, each with separate contacts, groups, and settings. Useful for separating personal and business identities.

## Cross-Device Workarounds

**Core limitation**: SimpleX cannot sync a profile across multiple devices simultaneously. Each profile lives on one device at a time.

### Workaround 1: Remote Control Protocol (XRCP)

Control a CLI running in the cloud from a desktop app:

```bash
# 1. On server: run CLI
simplex-chat -p 5225

# 2. On desktop app: enable Developer Tools
# Settings > Developer Tools > Enable

# 3. On desktop app: Linked Mobile > + Link a Mobile
# Choose local address 127.0.0.1, enter a port (e.g., 12345)
# Copy the generated link

# 4. Create SSH tunnel from desktop to server
ssh -R 12345:127.0.0.1:12345 -N user@server

# 5. In CLI on server, paste the link:
/crc <link>

# 6. CLI prints verification code — copy and paste the /verify line
/verify remote ctrl <code>
```

Now the desktop app controls the CLI profile. Multiple people can take turns controlling the same CLI profile this way.

### Workaround 2: Cloud CLI + tmux

Run CLI in a persistent tmux session on a cloud server:

```bash
# On server
useradd -m -s /bin/bash simplex-cli
tmux new -s simplex-cli
su - simplex-cli
simplex-chat -p 5225

# Detach: Ctrl+B then D
# Reattach: tmux attach -t simplex-cli
```

This keeps the profile always online and accessible from any SSH client.

### Workaround 3: Database Migration

Export the database from one device, import on another. Only one device can use the database at a time.

1. Source device: Settings > Database > Export
2. Transfer the exported file
3. Target device: Settings > Database > Import

**Warning**: Running the same database on two devices simultaneously will cause message delivery failures and potential data corruption.

## Self-Hosted Servers

### Why Self-Host

- **Full control** over message relay infrastructure
- **No trust** in third-party server operators
- **Custom retention** and storage policies
- **Tor onion** addresses for maximum anonymity
- **Compliance** with organizational security requirements

Default SimpleX servers are pre-configured in apps but can be replaced entirely.

### SMP Server (Message Relay)

**Requirements**: VPS with domain name, ports 443 + 5223 open.

```bash
# Download server install script
curl --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh \
  -o simplex-server-install.sh

# Review before executing
less simplex-server-install.sh
bash simplex-server-install.sh
# Choose option 1 for smp-server

# Initialize
su smp -c 'smp-server init --yes --store-log --control-port --fqdn=smp.example.com'

# Start
systemctl enable --now smp-server.service

# Check address
cat /etc/opt/simplex/fingerprint
```

Server address format: `smp://<fingerprint>[:<password>]@<hostname>[,<onion>]`

#### Docker Deployment

```bash
mkdir smp-server && cd smp-server

# Create .env
cat > .env <<'EOF'
ADDR=smp.example.com
# PASS=optional-queue-creation-password
EOF

# Download docker-compose.yml from simplex docs
curl -fsSL https://raw.githubusercontent.com/simplex-chat/simplexmq/refs/heads/stable/scripts/docker/docker-compose-smp-complete.yml \
  -o docker-compose.yml

docker compose up -d
```

See also: https://simplex.chat/docs/server.html

**Security best practices**:

- Initialize offline, move CA key (`/etc/opt/simplex/ca.key`) to secure storage
- Rotate online certificates every 3 months
- Enable Tor hidden service for `.onion` address
- Use Caddy for TLS termination and server info page
- Enable `control_port` for monitoring (with admin/user passwords)

> **Development only**: For local testing without password protection, add `--no-password` to the init command. Never use `--no-password` in production — it disables server password authentication.

### XFTP Server (File Relay)

```bash
# Install via same script, choose option 2
# Initialize
su xftp -c 'xftp-server init -l --fqdn=xftp.example.com -q 100gb -p /srv/xftp/'

# Start
systemctl enable --now xftp-server.service
```

Server address format: `xftp://<fingerprint>[:<password>]@<hostname>[,<onion>]`

### WebRTC TURN/STUN Server

For self-hosted audio/video call relays, see https://simplex.chat/docs/webrtc.html

### Configuring Apps to Use Custom Servers

In the app: Settings > Network & Servers > SMP Servers / XFTP Servers > Add your server address.

**Note**: Changing servers only affects new connections. Existing contacts continue using their original servers unless manually migrated via "Change receiving address" in contact info.

## Upstream Contributions

SimpleX Chat is AGPL-3.0 licensed. Contributions are welcome.

**AGPLv3 server requirement**: If you modify and run an SMP/XFTP server, you must publish your source code. The `source_code:` field in `smp-server.ini` is mandatory if any `[INFORMATION]` fields are set.

### Repository Structure

| Repository | Purpose |
|------------|---------|
| [simplex-chat](https://github.com/simplex-chat/simplex-chat) | Chat apps, CLI, bot API, TypeScript SDK |
| [simplexmq](https://github.com/simplex-chat/simplexmq) | SMP/XFTP servers and protocol libraries |

### Contributing

1. Fork the repository
2. Branch from `stable` (not `master` — that is the development branch)
3. Follow existing code style and conventions
4. Submit PR with clear description
5. See [contributing guide](https://simplex.chat/docs/contributing.html)

### Useful Contribution Areas

| Area | Description |
|------|-------------|
| **Bot examples** | New bot implementations (listed in `bots/README.md`) |
| **Translations** | App UI translations (see `simplex.chat/docs/translations.html`) |
| **Server tooling** | Monitoring, deployment, management scripts |
| **Documentation** | Guides, tutorials, API documentation |
| **Bug reports** | Via GitHub Issues with reproduction steps |

### Feedback Channels

- **SimpleX Chat**: Connect to the team via the app's "Send questions and ideas" link
- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: General questions and ideas

### Logging Feedback for Upstream

When encountering SimpleX limitations or bugs during aidevops usage, log them for potential upstream contribution:

```bash
# Template for feedback log entry
# File: ~/.aidevops/.agent-workspace/work/simplex/upstream-feedback.md
#
# ## [Date] Issue Title
# - **Version**: simplex-chat vX.Y.Z
# - **Platform**: Linux CLI / iOS / Android / Desktop
# - **Severity**: bug / enhancement / question
# - **Description**: What happened vs what was expected
# - **Reproduction**: Steps to reproduce
# - **Workaround**: If any
# - **Upstream issue**: (link once filed)
```

## Limitations

### Cross-Device Message Visibility

SimpleX cannot access the same profile from multiple devices simultaneously. Messages received on one device are not visible on another. This is a fundamental design constraint — true multi-device sync without server-side storage requires complex cryptographic protocols not yet implemented.

**Workarounds**: Remote Control Protocol (XRCP), cloud CLI with tmux, or database migration. See [Cross-Device Workarounds](#cross-device-workarounds).

### Single Profile Per Device Instance

Each CLI or app instance operates one active profile at a time. Multiple profiles can exist in the same app but only one is active. For bots, this means one bot identity per CLI process.

**Workaround**: Run multiple CLI instances with different database prefixes (`simplex-chat -d bot1`, `simplex-chat -d bot2`) on different ports.

### Owner Role Recovery

If the device or data containing a group owner profile is lost, the owner role cannot be recovered. The group continues to function but nobody can perform owner-level actions.

**Mitigation**: Create owner profiles on multiple devices for important groups. Add a backup owner before the primary is lost.

### Group Stability

Decentralized groups can experience:

- Delayed message delivery
- Member list desynchronization between participants
- Scalability limits (groups of 1000+ members are experimental)

Large groups benefit from self-hosted SMP servers with higher capacity.

### No Server-Side Message Search

All messages are E2E encrypted. There is no server-side search capability. Local search is available in mobile/desktop apps but not in CLI.

### Bot WebSocket API Security

The WebSocket API has no built-in authentication. It binds to localhost only, but if exposed:

- **Must** use TLS-terminating reverse proxy (Caddy, Nginx)
- **Must** configure HTTP basic auth
- **Must** restrict firewall to bot process IP only

### File Size Limits

XFTP handles large files but practical limits depend on:

- Server-configured storage quota
- 48-hour default retention on XFTP relays
- Network conditions for chunk upload/download

### AGPL-3.0 SDK License

The TypeScript SDK (`simplex-chat`, `@simplex-chat/types`) is AGPL-3.0 licensed. Bot code that imports the SDK must be AGPL-3.0 compatible or use the raw WebSocket API directly (which does not create a derivative work). This affects distribution — internal-only bots are not affected by AGPL's source disclosure requirement.

### Push Notifications

Optional push notifications via Apple/Google services are available but represent a privacy trade-off — the push service learns that the device received a message (but not its content or sender).

Alternatives: periodic background fetch (lower battery, delayed), or keep app in foreground.

## Matterbridge Integration

[matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) bridges SimpleX to 40+ platforms via [Matterbridge](https://github.com/42wim/matterbridge).

```text
SimpleX CLI (WebSocket :5225)
    │
matterbridge-simplex (Node.js adapter)
    │
Matterbridge API (HTTP :4242)
    │
    ├── Matrix rooms
    ├── Telegram groups
    ├── Discord channels
    ├── Slack workspaces
    ├── IRC channels
    └── 40+ other platforms
```

**Key details**:

- Uses same WebSocket API as bots
- Bridges both contact and group chats
- Docker-compose deployment (3 containers)
- `/hide` prefix for SimpleX-only messages (not bridged)
- Requires matterbridge >1.26.0
- MIT licensed

**Privacy gradient**: Users who need maximum privacy use SimpleX directly; users who prefer convenience use Matrix/Telegram/etc. Messages flow between platforms transparently.

See `t1328` for full Matterbridge integration task.

## Security Considerations

### Threat Model

SimpleX protects against:

- **Server compromise** — servers see no message content (E2E encrypted) and minimal metadata
- **Network surveillance** — 2-hop onion routing hides sender IP from recipient's server
- **Identity correlation** — no user identifiers to correlate across connections
- **Traffic analysis** — message padding, queue rotation, multiple servers reduce correlation

SimpleX does **not** protect against:

- **Device compromise** — local database contains all messages in plaintext (unless passphrase set)
- **Endpoint metadata** — recipient's server knows when messages arrive (timing analysis)
- **Social engineering** — users can still be tricked into connecting with adversaries

### Bot Security Model

When running bots that accept messages from untrusted users:

1. **Treat all inbound messages as untrusted input** — sanitize before passing to AI models
2. **DM pairing** — require approval before processing messages from unknown contacts
3. **Command sandboxing** — bot commands from chat should run in restricted environments
4. **Credential isolation** — never expose secrets to chat context or tool output
5. **Leak detection** — scan outbound messages for credential patterns before sending
6. **Per-group permissions** — different groups can have different command access levels

Cross-reference: `.agents/tools/security/opsec.md` (when available), `.agents/tools/credentials/gopass.md`, `.agents/tools/security/tirith.md`

### Operational Security

- Use Tor (`-x` flag) for maximum anonymity
- Self-host SMP/XFTP servers to eliminate third-party trust
- Enable database passphrase
- Use incognito mode for sensitive connections
- Rotate contact addresses periodically
- Back up database securely (encrypted storage)

## Integration with aidevops

### Components

| Component | File | Task |
|-----------|------|------|
| Subagent doc | `.agents/services/communications/simplex.md` | t1327.2 |
| Helper script | `.agents/scripts/simplex-helper.sh` | t1327.3 |
| Bot framework | `.agents/scripts/simplex-bot/` (TypeScript/Bun) | t1327.4 |
| Mailbox transport | `.agents/scripts/mail-helper.sh` (SimpleX + Matrix adapters) | t1327.5 |
| Opsec agent | `.agents/tools/security/opsec.md` | t1327.6 |
| Prompt injection defense | `.agents/scripts/prompt-guard-helper.sh` | t1327.8 |
| Outbound leak detection | `.agents/scripts/simplex-bot/src/leak-detector.ts` | t1327.9 |
| Exec approval flow | `.agents/scripts/simplex-bot/src/approval.ts` | t1327.10 |

### Slash Command Coexistence

SimpleX bot commands and aidevops commands both use `/` prefix but operate in separate contexts:

| Context | Prefix | Examples |
|---------|--------|---------|
| SimpleX chat (bot) | `/` | `/help`, `/status`, `/ask`, `/run` |
| SimpleX chat (menu) | `//` button | Tapping shows bot command menu |
| Claude Code terminal | `/` | `/define`, `/pr`, `/ready` |

No technical conflict — SimpleX bot commands run in chat context, aidevops commands run in terminal context. Within SimpleX, the bot owns the `/` namespace.

## Related

- `.agents/services/communications/matrix-bot.md` — Matrix messaging integration (federated, user IDs)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice note transcription
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- `.agents/services/networking/netbird.md` — Mesh VPN (complementary to SimpleX for infrastructure)
- SimpleX Docs: https://simplex.chat/docs/
- SimpleX Bot API: https://github.com/simplex-chat/simplex-chat/tree/stable/bots
- SimpleX Whitepaper: https://github.com/simplex-chat/simplexmq/blob/stable/protocol/overview-tjr.md
- Matterbridge-SimpleX: https://github.com/UnkwUsr/matterbridge-simplex
