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

- **Repo**: [github.com/simplex-chat/simplex-chat](https://github.com/simplex-chat/simplex-chat) (10.5K stars, AGPL-3.0)
- **Protocol**: SMP (SimpleX Messaging Protocol) — no user IDs, no phone numbers
- **Servers**: SMP (messaging relay) + XFTP (file transfer)
- **Bot SDK**: TypeScript (`simplex-chat-client`) + Haskell reference
- **Docs**: [simplex.chat/docs](https://simplex.chat/docs/)
- **Business**: [simplex.chat/docs/business.html](https://simplex.chat/docs/business.html)

**Key differentiator**: No persistent user identifiers. Each contact pair uses independent, rotating message queues. Metadata is near-zero by design.

<!-- AI-CONTEXT-END -->

## Protocol Overview

SimpleX uses two custom protocols:

### SMP (SimpleX Messaging Protocol)

- **Purpose**: Message relay between clients
- **Design**: Each connection uses a unique, one-time queue on an SMP server
- **No user IDs**: Servers see only queue IDs, not sender/recipient identities
- **E2E encryption**: Double Ratchet (Signal-compatible) + NaCl for transport
- **Whitepaper**: [github.com/simplex-chat/simplexmq/blob/stable/protocol/overview-tjr.md](https://github.com/simplex-chat/simplexmq/blob/stable/protocol/overview-tjr.md)

### XFTP (SimpleX File Transfer Protocol)

- **Purpose**: Encrypted file/media transfer
- **Design**: Files chunked, encrypted, distributed across XFTP servers
- **No metadata**: Server sees only encrypted chunks, not file names or sizes
- **Self-hostable**: Separate `xftp-server` binary

### Address Format

```
simplex://<fingerprint>[:<password>]@<host>[,<onion_host>]
```

SMP server address example:

```
smp://d5fcsc7hhtPpexYUbI2XPxDbyU2d3WsVmROimcL90ss=@smp.example.com
```

Contact/business address (app-generated link):

```
https://simplex.chat/contact#/?v=1&smp=smp%3A%2F%2F...
```

## Installation

### Mobile / Desktop Apps

| Platform | Download |
|----------|----------|
| iOS | App Store: "SimpleX Chat" |
| Android | Google Play or F-Droid (no Google Services) |
| macOS | [simplex.chat/downloads](https://simplex.chat/downloads/) |
| Windows | [simplex.chat/downloads](https://simplex.chat/downloads/) |
| Linux | AppImage or Flatpak |

### Terminal CLI

```bash
# Install script (Linux/macOS)
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash

# Verify
simplex-chat --version

# Run
simplex-chat
```

The CLI stores its database at `~/.simplex/` by default.

### CLI in Cloud (for Business Profiles)

```bash
# Create dedicated user
useradd -m -s /bin/bash simplex-cli

# Create tmux session
tmux new -s simplex-cli

# Switch to user
su - simplex-cli

# Install and run
curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash
simplex-chat

# Detach: Ctrl+B then D
# Reattach: tmux attach -t simplex-cli
```

## Bot API

SimpleX bots communicate via the CLI's JSON API over a local socket or stdin/stdout.

### TypeScript SDK

```bash
npm install @simplex-chat/client
```

```typescript
import { ChatClient } from "@simplex-chat/client";

// Connect to running simplex-chat CLI
const client = await ChatClient.create("ws://localhost:5225");

// Listen for messages
client.on("message", async (event) => {
  const { chatInfo, chatItem } = event;
  const text = chatItem.content?.text;
  if (text?.startsWith("/hello")) {
    await client.apiSendTextMessage(chatInfo.id, "Hello back!");
  }
});

// Send a message
await client.apiSendTextMessage(contactId, "Hello from bot!");
```

Start the CLI with WebSocket API enabled:

```bash
simplex-chat -p 5225  # Listen on port 5225
```

### Haskell Reference Bot

```bash
# Clone and build advanced bot example
git clone https://github.com/simplex-chat/simplex-chat
cd simplex-chat/apps/simplex-bot-advanced
stack build
stack exec simplex-bot-advanced
```

### CLI Commands for Bots

```bash
# In simplex-chat CLI:
/create contact          # Create new contact address
/show address            # Show your contact address
/connect <link>          # Connect to a contact
/send @contact message   # Send message
/groups                  # List groups
/create group MyGroup    # Create group
/add #group @contact     # Add contact to group
/broadcast message       # Broadcast to all contacts (business use)
```

## Business Addresses

From v6.2, SimpleX supports business addresses — a single address that creates a new conversation per customer.

### How Business Addresses Work

1. Business creates a **business contact address** in the app
2. Customer connects via the address link
3. App creates a **new group-like conversation** for each customer
4. Business can add team members to individual customer conversations
5. Customer sees business name/logo; business sees customer name/avatar

### Setup

```bash
# In simplex-chat CLI or desktop app:
/create address          # Create contact address
/set profile name "Acme Support"
/set profile image /path/to/logo.png
/show address            # Get shareable link
```

### Multi-Agent Business Setup

For teams with multiple support agents:

1. Run CLI on a cloud VM (always-on)
2. Agents connect to the CLI via Desktop app remote profile:
   - Desktop: Settings → Linked mobile → + Link a mobile → choose `127.0.0.1:PORT`
   - SSH tunnel: `ssh -R PORT:127.0.0.1:PORT -N user@server`
   - CLI: `/crc <link>` → `/verify remote ctrl ...`
3. Agents take turns managing the profile

### Customer Broadcasts

```bash
# CLI only (or chat console in desktop/mobile)
/broadcast Important announcement to all customers
```

## Voice and Video Calls

- **Protocol**: WebRTC (direct peer-to-peer when possible)
- **Fallback**: TURN servers (configurable, self-hostable)
- **E2E**: Yes — WebRTC DTLS-SRTP, keys negotiated via SimpleX messaging channel
- **Custom TURN**: Settings → Network & servers → WebRTC ICE servers

```bash
# Self-hosted TURN server (coturn)
apt install coturn
# Configure /etc/turnserver.conf
# Add to SimpleX: stun:your-server.com:3478 or turn:user:pass@your-server.com:3478
```

## File Transfer

- **Protocol**: XFTP (encrypted, chunked)
- **Max size**: Configurable on self-hosted XFTP server (default: 1GB)
- **E2E**: Yes — files encrypted before upload, keys shared via SMP channel
- **Storage**: Files stored on XFTP server until downloaded or expired

Files are sent via the app UI or CLI:

```bash
/file @contact /path/to/file.pdf
```

## Multi-Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| iOS | Full | App Store |
| Android | Full | Play Store + F-Droid (no GMS) |
| macOS | Full | Desktop app |
| Windows | Full | Desktop app |
| Linux | Full | AppImage/Flatpak + CLI |
| Web | No | By design (no web client) |
| CLI | Full | Headless, bot-friendly |

## Cross-Device Workarounds

SimpleX intentionally does not support simultaneous multi-device access (privacy trade-off). Workarounds:

### Option 1: Remote Profile via Desktop

Access a mobile or CLI profile from Desktop app:

1. Enable Developer tools in Desktop app
2. Desktop: Settings → Linked mobile → + Link a mobile → set port (e.g., 12345)
3. SSH tunnel from server to local: `ssh -R 12345:127.0.0.1:12345 -N user@server`
4. CLI on server: `/crc <link>` → `/verify remote ctrl ...`

**Limitation**: One controller at a time. Not simultaneous.

### Option 2: Multiple Profiles

- Create separate SimpleX profiles for different contexts
- Each profile has independent keys and contacts
- Switch between profiles in the app

### Option 3: CLI + Multiple Desktop Connections (Sequential)

For business use: run CLI on server, multiple agents connect sequentially (not simultaneously). Each agent detaches when done.

### Option 4: Planned Feature

SimpleX team is working on proper multi-device sync. No ETA as of 2026.

## Self-Hosted Servers

### SMP Server

```bash
# Quick install (Ubuntu, recommended)
curl --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh \
  -o simplex-server-install.sh
# Verify SHA256 before running (see simplex.chat/docs/server.html)
chmod +x ./simplex-server-install.sh
./simplex-server-install.sh
# Select option 1 (smp-server)

# Firewall
ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 5223/tcp

# Initialize
su smp -c 'smp-server init --yes \
  --store-log \
  --no-password \
  --control-port \
  --socks-proxy \
  --source-code \
  --fqdn=smp.example.com'

# Start
systemctl enable --now smp-server.service

# Get address
journalctl -u smp-server | grep "Server address:"
```

#### Docker (Automatic — Recommended)

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

#### SMP Server Address Format

```
smp://<fingerprint>[:<password>]@<hostname>[,<onion>]
```

Example:

```
smp://d5fcsc7hhtPpexYUbI2XPxDbyU2d3WsVmROimcL90ss=@smp.example.com,abc123.onion
```

#### Security: CA Key Protection

```bash
# After init, move CA key off server
scp smp@server:/etc/opt/simplex/ca.key ./ca.key.backup
# Store in Bitwarden, Tails USB, or offline machine
ssh smp@server "rm /etc/opt/simplex/ca.key"
```

#### Certificate Rotation (Every 3 Months)

```bash
# On local machine with ca.key
export SMP_SERVER_CFG_PATH=$HOME/simplex/smp/config
rsync -hzasP user@server:/etc/opt/simplex/ $HOME/simplex/smp/config/
cp ca.key.backup $HOME/simplex/smp/config/ca.key
smp-server cert
rm $HOME/simplex/smp/config/ca.key
rsync -hzasP $HOME/simplex/smp/config/ user@server:/etc/opt/simplex/
ssh user@server "systemctl restart smp-server"
```

#### Tor / Onion Address

```bash
# Install tor
apt install -y tor

# Configure /etc/tor/torrc
cat >> /etc/tor/torrc <<'EOF'
Log notice file /var/log/tor/notices.log
SOCKSPort 0
HiddenServiceNonAnonymousMode 1
HiddenServiceSingleHopMode 1
HiddenServiceDir /var/lib/tor/simplex-smp/
HiddenServicePort 5223 localhost:5223
HiddenServicePort 443 localhost:443
EOF

systemctl enable --now tor && systemctl restart tor
cat /var/lib/tor/simplex-smp/hostname  # Your .onion address
```

### XFTP Server

```bash
# Install (same script, select option 2)
./simplex-server-install.sh
# Select option 2 (xftp-server)

# Firewall
ufw allow 443/tcp

# Initialize
su xftp -c 'xftp-server init --yes \
  --store-log \
  --fqdn=xftp.example.com'

# Start
systemctl enable --now xftp-server.service
```

XFTP server address format:

```
xftp://<fingerprint>@<hostname>
```

### Configuring App to Use Custom Servers

In the app: Settings → Network & servers → SMP servers → Add server

Or via CLI:

```bash
/smp smp://fingerprint@smp.example.com
/xftp xftp://fingerprint@xftp.example.com
```

## Upstream Contributions

- **Repo**: [github.com/simplex-chat/simplex-chat](https://github.com/simplex-chat/simplex-chat)
- **Protocol**: [github.com/simplex-chat/simplexmq](https://github.com/simplex-chat/simplexmq)
- **License**: AGPL-3.0 (client + server) — modifications must be open-sourced
- **Contributing**: [simplex.chat/docs/contributing.html](https://simplex.chat/docs/contributing.html)
- **Translations**: [simplex.chat/docs/translations.html](https://simplex.chat/docs/translations.html)
- **Issues**: GitHub Issues (976 open as of 2026)
- **Discussions**: GitHub Discussions

**AGPLv3 server requirement**: If you modify and run an SMP/XFTP server, you must publish your source code. The `source_code:` field in `smp-server.ini` is mandatory if any `[INFORMATION]` fields are set.

## Limitations

| Limitation | Detail | Workaround |
|------------|--------|------------|
| No simultaneous multi-device | One active session per profile | Remote profile via SSH tunnel (sequential) |
| No web client | By design (privacy) | Desktop app or CLI |
| Group instability | Message delivery can fail/delay in large groups | Keep groups small; use CLI for reliability |
| Group owner recovery | Lost device = lost owner role | Create owner profiles on multiple devices |
| No cloud backup | Privacy trade-off | Manual database export + encrypted backup |
| Database loss = data loss | No server-side recovery | Regular encrypted backups of `~/.simplex/` |
| No username search | No central directory | Share contact links directly |
| Group member sync | Member lists can be out of sync | Known issue, being worked on |
| WhatsApp bridge | Via matterbridge-simplex adapter only | E2E broken at bridge boundary |
| No read receipts across platforms | SimpleX-only feature | N/A |

## Related

- `tools/security/opsec.md` — Threat modeling, SimpleX vs Matrix comparison, platform trust matrix
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Bridge SimpleX to other platforms (E2E broken at boundary)
- `tools/credentials/encryption-stack.md` — Secure credential storage for server configs
