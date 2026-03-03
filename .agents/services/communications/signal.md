---
description: Signal — E2E encrypted messaging gold standard, signal-cli bot integration (JSON-RPC), registration, daemon mode, group messaging, security model, matterbridge bridging, and limitations
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

# Signal Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: E2E encrypted messaging — gold standard for privacy
- **License**: AGPL-3.0 (client + server)
- **Bot tool**: signal-cli (Java/native, GPLv3) — NOT an official bot API
- **Protocol**: Signal Protocol (Double Ratchet + X3DH)
- **Encryption**: E2E by default for ALL messages (Curve25519, AES-256, HMAC-SHA256)
- **Registration**: Requires phone number (E.164 format, e.g., `+14155551234`)
- **Daemon mode**: `signal-cli -a +NUMBER daemon --http --receive-mode=on-connection`
- **API**: JSON-RPC over HTTP + Server-Sent Events for incoming messages
- **Data**: `~/.local/share/signal-cli/` (account data, keys, message store)
- **Docs**: https://github.com/AsamK/signal-cli | https://signal.org/docs/
- **User base**: 40M+ monthly active users (largest E2E encrypted messenger)

**Key differentiator**: Signal is the gold standard for mainstream encrypted messaging. E2E encryption is on by default for ALL messages — no opt-in required. The Signal Protocol is the most widely adopted secure messaging protocol, also used by WhatsApp, Google Messages (RCS), and Facebook Messenger.

**When to use Signal over SimpleX**:

| Criterion | Signal | SimpleX |
|-----------|--------|---------|
| User identifiers | Phone number | None |
| E2E encryption | Default, all messages | Default, all messages |
| Server metadata | Minimal (sealed sender) | Stateless (memory only) |
| User base | 40M+ MAU | Growing niche |
| Bot ecosystem | signal-cli (unofficial) | WebSocket API (official) |
| Group scalability | Production-grade (1000+) | Experimental (1000+) |
| Best for | Privacy-conscious mainstream users | Maximum privacy, zero identifiers |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐
│ Signal Mobile/         │
│ Desktop App            │
│ (iOS, Android,         │
│  Linux, macOS, Win)    │
└──────────┬────────────┘
           │ Signal Protocol (E2E encrypted)
           │ Double Ratchet + X3DH
           │
┌──────────▼────────────┐
│ Signal Servers          │
│ (sealed sender,         │
│  minimal metadata,      │
│  message queuing)       │
└──────────┬────────────┘
           │
┌──────────▼────────────┐
│ signal-cli Daemon       │
│ (JSON-RPC over HTTP     │
│  + SSE for events)      │
└──────────┬────────────┘
           │ JSON-RPC / SSE
┌──────────▼────────────┐
│ Bot Process             │
│ ├─ Command router       │
│ ├─ Message handler      │
│ ├─ Group handler        │
│ └─ aidevops dispatch    │
└─────────────────────────┘
```

**Message flow**:

1. Sender's app encrypts message with Signal Protocol (Double Ratchet + X3DH, Curve25519)
2. Message encrypted with AES-256-CBC, authenticated with HMAC-SHA256
3. Sealed sender envelope hides sender identity from Signal servers
4. Signal server queues encrypted message for recipient
5. Recipient's app (or signal-cli) retrieves and decrypts
6. Server deletes message after delivery confirmation

## Installation

### signal-cli (Native Binary — Recommended)

```bash
# Download latest native binary (no Java required)
# Check https://github.com/AsamK/signal-cli/releases for latest version
SIGNAL_CLI_VERSION="0.13.12"
curl -fsSLo signal-cli.tar.gz \
  "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m).tar.gz"

tar xf signal-cli.tar.gz
sudo mv signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli /usr/local/bin/
sudo mv signal-cli-${SIGNAL_CLI_VERSION}/lib/ /usr/local/lib/signal-cli/
signal-cli --version
```

### signal-cli (Java)

```bash
# Requires Java 21+
SIGNAL_CLI_VERSION="0.13.12"
curl -fsSLo signal-cli.tar.gz \
  "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz"

tar xf signal-cli.tar.gz
sudo mv signal-cli-${SIGNAL_CLI_VERSION} /opt/signal-cli
sudo ln -sf /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli
signal-cli --version
```

### macOS / Docker

```bash
# macOS
brew install signal-cli

# Docker
docker run --rm -v ~/.local/share/signal-cli:/home/.local/share/signal-cli \
  registry.gitlab.com/packaging/signal-cli/signal-cli-native:latest --version
```

## Registration

Signal requires a phone number for registration. Two methods are available.

### Method 1: Link to Existing Account (Recommended for Bots)

Link signal-cli as a secondary device to an existing Signal account. Avoids needing a separate phone number.

```bash
# Generate linking URI — displays a QR code or URI
signal-cli link -n "aidevops-bot"

# Scan the QR code from your Signal app:
# Signal app > Settings > Linked Devices > Link New Device
# Credentials stored in ~/.local/share/signal-cli/data/
```

### Method 2: Register New Number (SMS/Voice Verification)

```bash
# Step 1: Request verification (may need CAPTCHA from https://signalcaptchas.org/registration/generate.html)
signal-cli -a +14155551234 register --captcha "CAPTCHA_TOKEN"

# Step 2: Verify with SMS code
signal-cli -a +14155551234 verify 123456

# Step 3: Set profile name (required)
signal-cli -a +14155551234 updateProfile --given-name "AI Bot" --family-name "DevOps"
```

### Verify Installation

```bash
signal-cli -a +14155551234 listAccounts
signal-cli -a +14155551234 send -m "Hello from signal-cli" +14155559876
```

## Daemon Mode (JSON-RPC API)

For bot integration, run signal-cli as a persistent daemon with HTTP JSON-RPC and Server-Sent Events.

```bash
# Basic daemon (default port 8080)
signal-cli -a +14155551234 daemon --http --receive-mode=on-connection

# Custom port
signal-cli -a +14155551234 daemon --http=localhost:7583 --receive-mode=on-connection

# Unix socket for local-only access
signal-cli -a +14155551234 daemon --socket=/tmp/signal-cli.socket
```

### Receive Modes

| Mode | Description | Use case |
|------|-------------|----------|
| `on-connection` | Fetch messages when client connects via SSE | Real-time bots |
| `manual` | Only receive when explicitly requested | Polling-based bots |

### systemd Service

```ini
# /etc/systemd/system/signal-cli.service
[Unit]
Description=signal-cli daemon
After=network.target

[Service]
Type=simple
User=signal-bot
ExecStart=/usr/local/bin/signal-cli -a +14155551234 daemon --http=localhost:7583 --receive-mode=on-connection
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now signal-cli.service
```

## Bot API Integration

### JSON-RPC Commands

signal-cli daemon exposes a JSON-RPC 2.0 API over HTTP.

```bash
# Send text message to individual
curl -s -X POST http://localhost:7583/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"send","params":{"recipient":["+14155559876"],"message":"Hello!"},"id":1}'

# Send to group
curl -s -X POST http://localhost:7583/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"send","params":{"groupId":"BASE64_GROUP_ID","message":"Hello group!"},"id":2}'

# Send with attachment
curl -s -X POST http://localhost:7583/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"send","params":{"recipient":["+14155559876"],"message":"Report","attachments":["/path/to/report.pdf"]},"id":3}'
```

### Receiving Messages (Server-Sent Events)

```bash
curl -N http://localhost:7583/api/v1/events
```

SSE events are JSON objects:

```json
{
  "envelope": {
    "source": "+14155559876",
    "sourceUuid": "a1b2c3d4-e5f6-...",
    "sourceName": "Alice",
    "timestamp": 1700000000000,
    "dataMessage": {
      "message": "/status",
      "timestamp": 1700000000000,
      "groupInfo": null,
      "attachments": [],
      "mentions": [],
      "quote": null,
      "reaction": null
    }
  }
}
```

### Key JSON-RPC Methods

| Method | Description |
|--------|-------------|
| `send` | Send message (text, attachments, quotes, reactions) |
| `sendReaction` | Send emoji reaction (`emoji`, `targetAuthor`, `targetTimestamp`) |
| `sendReceipt` | Send read/delivery receipt (`type`, `targetTimestamps`) |
| `sendTyping` | Send typing indicator |
| `listGroups` | List all groups |
| `listContacts` | List all contacts |
| `getContactName` | Get contact profile name |
| `updateGroup` | Modify group settings |
| `quitGroup` | Leave a group |
| `joinGroup` | Join via group invite link |
| `updateProfile` | Update bot's profile name/avatar |
| `getUserStatus` | Check if number is registered on Signal |

### Basic Bot Implementation (Bun/TypeScript)

```typescript
// signal-bot.ts — minimal Signal bot using signal-cli JSON-RPC + SSE
const SIGNAL_CLI_URL = "http://localhost:7583"

// Allowed users (E.164 phone numbers)
const ALLOWED_USERS = new Set(["+14155559876", "+14155559877"])

// JSON-RPC helper
async function rpc(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  const resp = await fetch(`${SIGNAL_CLI_URL}/api/v1/rpc`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", method, params, id: Date.now() }),
  })
  const json = await resp.json()
  if (json.error) throw new Error(`RPC error: ${json.error.message}`)
  return json.result
}

// Send message to individual or group
async function sendMessage(recipient: string, message: string, groupId?: string): Promise<void> {
  const params: Record<string, unknown> = { message }
  if (groupId) { params.groupId = groupId } else { params.recipient = [recipient] }
  await rpc("send", params)
}

// SSE event listener — main loop
async function listen(): Promise<void> {
  const response = await fetch(`${SIGNAL_CLI_URL}/api/v1/events`)
  if (!response.body) throw new Error("No response body from SSE endpoint")

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ""

  while (true) {
    const { done, value } = await reader.read()
    if (done) break

    buffer += decoder.decode(value, { stream: true })
    const lines = buffer.split("\n")
    buffer = lines.pop() || ""

    for (const line of lines) {
      if (!line.startsWith("data:")) continue
      const data = line.slice(5).trim()
      if (!data) continue

      try {
        const event = JSON.parse(data)
        const env = event.envelope
        if (!env?.dataMessage?.message) continue

        const source = env.source
        const groupId = env.dataMessage.groupInfo?.groupId
        const text = env.dataMessage.message.trim()

        // Access control
        if (!ALLOWED_USERS.has(source)) {
          if (!groupId) await sendMessage(source, "Unauthorized.")
          continue
        }

        // Command routing
        if (text.startsWith("/")) {
          const [cmd] = text.slice(1).split(/\s+/)
          switch (cmd.toLowerCase()) {
            case "help":
              await sendMessage(source, "/help /status /ping /whoami", groupId)
              break
            case "status":
              await sendMessage(source, `Online. Uptime: ${process.uptime().toFixed(0)}s`, groupId)
              break
            case "ping":
              await sendMessage(source, "pong", groupId)
              break
            default:
              await sendMessage(source, `Unknown: /${cmd}`, groupId)
          }
        }
      } catch (err) {
        console.error("SSE parse error:", err)
      }
    }
  }
}

listen().catch((err) => { console.error("Bot crashed:", err); process.exit(1) })
```

## Security Considerations

> **CRITICAL**: Signal is the gold standard for mainstream encrypted messaging. This section details the full security model — essential reading for any integration.

### Encryption

Signal Protocol is the most widely deployed E2E encryption protocol in the world.

- **Key agreement**: Extended Triple Diffie-Hellman (X3DH) with Curve25519
- **Ratchet**: Double Ratchet algorithm — forward secrecy AND future secrecy (post-compromise security)
- **Message encryption**: AES-256-CBC
- **Message authentication**: HMAC-SHA256
- **Key derivation**: HKDF
- **E2E by DEFAULT**: Every message — text, voice, video, file — is E2E encrypted. No opt-in, no "secret chat" mode. This is the single most important security property.

### Metadata Protection

- **Sealed sender**: Hides sender identity from Signal servers. Server knows the recipient but not the sender.
- **Server stores ONLY**: Phone number (hashed), registration date, last connection date.
- **Server does NOT store**: Message content, contacts, groups, profile info, message timestamps, delivery metadata.
- **Proven in court**: Multiple grand jury subpoenas (2016, 2021) — Signal could only provide: phone number, registration date, last connection date. Nothing else exists on their servers.

### Push Notifications

- Uses FCM (Android) and APNs (iOS) — push contains **no message content**, only a "new message available" signal
- Actual message fetched E2E encrypted directly from Signal servers
- Minimal metadata exposure — push service knows "a message arrived" but not content, sender, or type

### AI Training and Data Monetization

- Signal Foundation is a **501(c)(3) non-profit**
- Explicitly does **NOT** use any user data for AI training
- **No ads**, no tracking, no data monetization — ever
- Structurally enforced by non-profit charter, not just a policy choice

### Open Source and Auditing

- **Client + Server**: Open source, AGPL-3.0 (Signal-Android, Signal-iOS, Signal-Desktop, Signal-Server)
- **Regular independent security audits** by Trail of Bits, NCC Group, Cure53
- **Reproducible builds** for Android — published APK verifiable against source
- Signal Protocol formally verified by academic researchers

### Jurisdiction

- **Signal Foundation**, Mountain View, California, USA
- Subject to US law (FISA, NSLs) — but minimal data to hand over makes legal pressure largely ineffective
- 2021 grand jury subpoena response is public record

### Bot-Specific Security

- signal-cli is unofficial but well-maintained (GPLv3, active development)
- Bot messages are **still E2E encrypted** — signal-cli implements the full Signal Protocol
- Bot's decryption keys stored locally in `~/.local/share/signal-cli/` — **secure the host machine**
- HTTP API has **no built-in authentication** — bind to localhost only, or use a reverse proxy with auth
- Run signal-cli under a dedicated system user with minimal privileges

### Phone Number Requirement

- Signal requires a phone number — this is the **primary privacy weakness**
- Phone numbers are personally identifiable and linkable to real identities
- Signal developing **usernames** to reduce dependency
- For bots: use a dedicated VoIP or prepaid number not linked to personal identity

### Comparison with Other Platforms

| Property | Signal | SimpleX | Matrix | Telegram | WhatsApp |
|----------|--------|---------|--------|----------|----------|
| E2E encryption | Default, all | Default, all | Opt-in (rooms) | Opt-in (secret chats) | Default, all |
| User identifier | Phone number | None | @user:server | Phone/username | Phone number |
| Server metadata | Minimal | None (stateless) | Full history | Full history | Moderate |
| Open source | Client + server | Client + server | Client + server | Client only | Neither |
| Non-profit | Yes (501c3) | Yes | Yes (Foundation) | No (commercial) | No (Meta) |
| AI training | Never | Never | No (Foundation) | Yes (since 2024) | Yes (Meta) |

**Summary**: Strongest privacy of any **mainstream** messenger. Only SimpleX offers better metadata privacy (no identifiers at all), but Signal has vastly larger user base (~40M+ vs niche) and more mature ecosystem.

## Integration with aidevops

### Components

| Component | File | Purpose |
|-----------|------|---------|
| Subagent doc | `.agents/services/communications/signal.md` | This file |
| Helper script | `.agents/scripts/signal-dispatch-helper.sh` | Signal bot dispatch |
| Config | `~/.config/aidevops/signal-bot.json` | Bot configuration |

### Configuration

```json
{
  "account": "+14155551234",
  "daemon_url": "http://localhost:7583",
  "allowed_users": ["+14155559876", "+14155559877"],
  "allowed_groups": ["BASE64_GROUP_ID_1"],
  "command_prefix": "/",
  "dispatch_enabled": true
}
```

### Dispatch Pattern

```bash
# signal-dispatch-helper.sh pattern
# 1. Receive message via SSE
# 2. Check access control (phone number + UUID allowlist)
# 3. Parse command
# 4. Dispatch to aidevops runner or respond directly

# Entity resolution:
# - Phone number (+E.164) → user identity
# - Group ID (base64) → channel context
# - UUID → stable user identifier (survives number change)
```

### Runner Dispatch

Signal messages can trigger aidevops task execution:

```bash
# User sends: /run deploy staging
# Bot parses: command=run, args=["deploy", "staging"]
# Bot dispatches: aidevops runner with task context
# Bot responds: "Task dispatched. Tracking ID: t1234"
# Bot follows up: "Deploy complete. PR #567 merged."
```

## Matterbridge Integration

signal-cli has native support in [Matterbridge](https://github.com/42wim/matterbridge) for bridging Signal to 40+ platforms.

```text
Signal (via signal-cli)
    │
Matterbridge
    │
    ├── Matrix rooms
    ├── Telegram groups
    ├── Discord channels
    ├── Slack workspaces
    ├── SimpleX chats
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

```toml
# matterbridge.toml — Signal gateway

[signal.mybot]
Number = "+14155551234"
SignalCLIConfig = "/home/signal-bot/.local/share/signal-cli"

[gateway.bridge-main]
name = "main-bridge"
enable = true

  [[gateway.bridge-main.inout]]
  account = "signal.mybot"
  channel = "BASE64_GROUP_ID"

  [[gateway.bridge-main.inout]]
  account = "matrix.mybot"
  channel = "#devops:matrix.example.com"
```

### Key Details

- Matterbridge uses signal-cli's dbus or JSON-RPC interface
- Bridges both DM and group messages
- Supports text, images, and file attachments
- Signal group to platform channel mapping is 1:1 per gateway
- Requires signal-cli registered and running as daemon

**Privacy gradient**: Users who need maximum privacy use Signal directly. Users who prefer convenience use bridged platforms. Messages flow between platforms transparently via Matterbridge.

## Limitations

### Phone Number Required

Signal requires a phone number for registration. This is the main privacy limitation — phone numbers are personally identifiable. Signal is developing username support but phone numbers remain mandatory for account creation.

**Mitigation**: Use a dedicated VoIP or prepaid number for bot accounts.

### No Official Bot API

signal-cli is unofficial. Signal does not provide an official bot API or SDK:

- No guaranteed API stability between signal-cli versions
- Feature parity with official apps may lag
- Breaking changes in Signal Protocol updates may require signal-cli updates

**Mitigation**: Pin signal-cli version, test updates in staging before production.

### Java Dependency

signal-cli requires Java 21+ (Java distribution) or native GraalVM builds (~100MB+).

**Mitigation**: Use native binary builds where available, or Docker containers.

### No Rich Interactive Elements

Signal does not support inline keyboards, buttons, interactive cards, or bot command menus. Bot interaction is limited to plain text, attachments, reactions, and quoted replies.

### Group Admin Features Limited

signal-cli has limited group admin capabilities compared to the official app. Advanced features (permissions, disappearing messages timer, group link management) may be unavailable. Group v2 features require signal-cli to be up-to-date.

### Rate Limiting

Signal enforces rate limits on message sending. No official documentation on exact limits. Implement backoff and queuing in bot code. Group messages count against rate limits per recipient.

### Single Account Per Daemon

Each signal-cli daemon instance handles one Signal account. Multiple bot identities require multiple daemon processes on different ports.

### Linked Device Limitations

When signal-cli is linked as a secondary device: depends on primary device being online periodically for key sync; if primary is removed, linked device loses access; message history before linking is unavailable.

## Related

- `.agents/services/communications/simplex.md` — SimpleX Chat (zero-identifier messaging, strongest metadata privacy)
- `.agents/services/communications/matrix-bot.md` — Matrix messaging integration (federated, user IDs)
- `.agents/services/communications/matterbridge.md` — Cross-platform message bridging
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice note transcription
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Signal Protocol specification: https://signal.org/docs/
- signal-cli repository: https://github.com/AsamK/signal-cli
- Signal Foundation: https://signalfoundation.org/
- Signal source code: https://github.com/signalapp/
