---
description: WhatsApp bot integration via Baileys (unofficial) — E2E encrypted messaging owned by Meta, Signal Protocol encryption but extensive metadata harvesting
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

# WhatsApp Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: E2E encrypted messaging owned by Meta — content encrypted but metadata extensively harvested
- **License**: Baileys (MIT, unofficial), WhatsApp Business API (proprietary, official)
- **Bot tool**: Baileys (TypeScript, 10k+ stars, unofficial WhatsApp Web API)
- **Protocol**: Signal Protocol (same as Signal app)
- **Encryption**: E2E by default (Signal Protocol — Curve25519, AES-256, HMAC-SHA256)
- **Docs**: https://github.com/WhiskeySockets/Baileys | https://developers.facebook.com/docs/whatsapp/
- **Config**: `~/.config/aidevops/whatsapp-bot.json` (600 permissions)
- **Helper**: `whatsapp-dispatch-helper.sh [setup|start|stop|status|test|logs]`

**Key differentiator**: WhatsApp has the largest messenger user base globally (2B+ users). Message content is E2E encrypted using the Signal Protocol — the same protocol used by Signal. However, Meta collects extensive metadata (contacts, timing, groups, device info, usage patterns) and uses it for ad targeting across Meta platforms. Think of it as: "your letters are sealed, but the postal service photographs every envelope and sells that data."

**When to use WhatsApp over other messengers**:

| Criterion | WhatsApp | Signal | SimpleX | Matrix |
|-----------|----------|--------|---------|--------|
| User base | 2B+ (largest) | ~40M | Small | ~100M |
| Content encryption | Signal Protocol | Signal Protocol | Double ratchet | Megolm/Olm |
| Metadata privacy | Poor (Meta harvests) | Good (minimal) | Excellent (none) | Moderate |
| User identifiers | Phone number | Phone number | None | `@user:server` |
| Bot ecosystem | Unofficial (Baileys) + official Business API | Minimal | Growing | Mature |
| Open source client | No | Yes | Yes (AGPL-3.0) | Yes |
| Best for | Reaching existing users | Privacy-conscious users | Maximum privacy | Federation, bridges |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐
│ WhatsApp Mobile App   │
│ (iOS / Android)       │
│                       │
│ User sends message    │
└──────────┬───────────┘
           │ Signal Protocol (E2E encrypted)
           │
┌──────────▼───────────┐     ┌──────────────────────┐
│ WhatsApp Servers      │     │ Meta Metadata         │
│ (Meta infrastructure) │     │ Collection            │
│                       │     │                       │
│ Cannot read content   │     │ Records: who, when,   │
│ (E2E encrypted)       │     │ how often, groups,    │
│                       │     │ contacts, device,     │
│ Routes messages only  │     │ IP, location          │
└──────────┬───────────┘     └──────────────────────┘
           │
┌──────────▼───────────┐
│ WhatsApp Web          │
│ Multi-Device Protocol │
│ (no phone needed      │
│  after initial link)  │
└──────────┬───────────┘
           │ WebSocket
           │
┌──────────▼───────────┐
│ Baileys Library       │
│ (TypeScript)          │
│                       │
│ Unofficial WA Web API │
│ Handles encryption,   │
│ session management,   │
│ message parsing       │
└──────────┬───────────┘
           │
┌──────────▼───────────┐
│ Bot Process            │
│ (TypeScript/Bun)       │
│                        │
│ ├─ Command router      │
│ ├─ Message handler     │
│ ├─ Media handler       │
│ ├─ Access control      │
│ └─ aidevops dispatch   │
└────────────────────────┘
```

**Message flow**:

1. User sends message via WhatsApp mobile app
2. Message encrypted with Signal Protocol (Curve25519, AES-256, HMAC-SHA256)
3. Encrypted message routed through Meta's servers (content unreadable to Meta)
4. Meta records metadata: sender, recipient, timestamp, group, device info, IP
5. Multi-device protocol delivers to linked WhatsApp Web session
6. Baileys receives via WebSocket, decrypts using stored session keys
7. Bot process handles message, dispatches to aidevops runner
8. Response sent back through Baileys → WhatsApp servers → recipient

## Installation

### Prerequisites

- **Node.js** >= 18 or **Bun** >= 1.0
- **WhatsApp account** with active phone number
- A phone to scan QR code during initial setup (only needed once)

### Baileys Library Setup

```bash
# Using Bun (recommended)
bun add @whiskeysockets/baileys

# Using npm
npm install @whiskeysockets/baileys

# Additional dependencies
bun add qrcode-terminal  # QR code display in terminal
bun add pino              # Logger (required by Baileys)
```

### QR Code Authentication

Baileys authenticates by emulating WhatsApp Web. On first run, you scan a QR code with your phone's WhatsApp app to link the device.

```typescript
import makeWASocket, {
  DisconnectReason,
  useMultiFileAuthState,
} from "@whiskeysockets/baileys";
import { Boom } from "@hapi/boom";
import qrcode from "qrcode-terminal";

async function connectToWhatsApp() {
  // Auth state persisted to filesystem — survives restarts
  const { state, saveCreds } = await useMultiFileAuthState("auth_info_baileys");

  const sock = makeWASocket({
    auth: state,
    printQRInTerminal: true, // Display QR in terminal
  });

  // Save credentials whenever they update
  sock.ev.on("creds.update", saveCreds);

  // Handle connection state changes
  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      // QR code displayed — scan with phone
      // WhatsApp app > Settings > Linked Devices > Link a Device
      console.log("Scan QR code with WhatsApp mobile app");
    }

    if (connection === "close") {
      const reason = (lastDisconnect?.error as Boom)?.output?.statusCode;
      if (reason !== DisconnectReason.loggedOut) {
        // Reconnect on non-logout disconnections
        connectToWhatsApp();
      } else {
        console.log("Logged out — delete auth_info_baileys/ and restart");
      }
    }

    if (connection === "open") {
      console.log("Connected to WhatsApp");
    }
  });

  return sock;
}
```

### Multi-Device Support

After the initial QR code scan, the bot runs independently — the phone does not need to stay online. WhatsApp's multi-device protocol syncs encryption keys across linked devices.

**Limitations**:

- Maximum 4 linked devices per WhatsApp account
- Phone must remain registered (active SIM / WhatsApp account)
- If the phone's WhatsApp is uninstalled, all linked devices are disconnected
- Linked devices are automatically unlinked after 14 days of phone inactivity

### Session Persistence

Auth state is stored in the `auth_info_baileys/` directory. This directory contains:

- Session encryption keys
- Device registration data
- Pre-keys and identity keys

**Back up this directory securely** — it grants full access to the WhatsApp account. Set file permissions to 700:

```bash
chmod 700 auth_info_baileys/
```

## Bot API Integration

### Message Handling

```typescript
import makeWASocket, { useMultiFileAuthState } from "@whiskeysockets/baileys";

async function startBot() {
  const { state, saveCreds } = await useMultiFileAuthState("auth_info_baileys");
  const sock = makeWASocket({ auth: state, printQRInTerminal: true });
  sock.ev.on("creds.update", saveCreds);

  // Listen for incoming messages
  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return; // Only process new messages

    for (const msg of messages) {
      // Skip own messages
      if (msg.key.fromMe) continue;

      // Extract sender and chat info
      const chatId = msg.key.remoteJid!; // JID of chat (DM or group)
      const isGroup = chatId.endsWith("@g.us");
      const sender = isGroup ? msg.key.participant! : chatId;
      const pushName = msg.pushName || "Unknown"; // Display name

      // Extract text content
      const text =
        msg.message?.conversation ||
        msg.message?.extendedTextMessage?.text ||
        "";

      if (!text) continue; // Skip non-text messages

      console.log(`[${isGroup ? "GROUP" : "DM"}] ${pushName}: ${text}`);

      // Command routing
      if (text.startsWith("/")) {
        await handleCommand(sock, chatId, sender, text);
      }
    }
  });

  return sock;
}

async function handleCommand(
  sock: ReturnType<typeof makeWASocket>,
  chatId: string,
  sender: string,
  text: string,
) {
  const [command, ...args] = text.slice(1).split(" ");
  const prompt = args.join(" ");

  switch (command) {
    case "help":
      await sock.sendMessage(chatId, {
        text: "Available commands:\n/help - Show this message\n/ask <question> - Ask AI\n/status - System status",
      });
      break;

    case "ask":
      if (!prompt) {
        await sock.sendMessage(chatId, { text: "Usage: /ask <question>" });
        return;
      }
      // Dispatch to aidevops runner
      await sock.sendMessage(chatId, {
        text: "Processing your request...",
      });
      // runner-helper.sh dispatch would go here
      break;

    case "status":
      await sock.sendMessage(chatId, { text: "Bot is running." });
      break;

    default:
      await sock.sendMessage(chatId, {
        text: `Unknown command: /${command}`,
      });
  }
}

startBot();
```

### Media Support

Baileys supports sending and receiving various media types:

```typescript
// Send image
await sock.sendMessage(chatId, {
  image: { url: "./photo.jpg" }, // or Buffer
  caption: "Image caption",
});

// Send video
await sock.sendMessage(chatId, {
  video: { url: "./video.mp4" },
  caption: "Video caption",
  gifPlayback: false, // true for GIF-style playback
});

// Send audio (voice note)
await sock.sendMessage(chatId, {
  audio: { url: "./audio.ogg" },
  mimetype: "audio/ogg; codecs=opus",
  ptt: true, // true = voice note, false = audio file
});

// Send document
await sock.sendMessage(chatId, {
  document: { url: "./report.pdf" },
  mimetype: "application/pdf",
  fileName: "report.pdf",
});

// Send sticker
await sock.sendMessage(chatId, {
  sticker: { url: "./sticker.webp" },
});

// Download received media
import { downloadMediaMessage } from "@whiskeysockets/baileys";
const buffer = await downloadMediaMessage(msg, "buffer", {});
```

### Reactions, Read Receipts, and Polls

```typescript
// Send reaction
await sock.sendMessage(chatId, {
  react: { text: "👍", key: msg.key },
});

// Remove reaction
await sock.sendMessage(chatId, {
  react: { text: "", key: msg.key },
});

// Mark message as read
await sock.readMessages([msg.key]);

// Send poll (WhatsApp polls)
await sock.sendMessage(chatId, {
  poll: {
    name: "What should we deploy?",
    values: ["Frontend", "Backend", "Both", "Neither"],
    selectableCount: 1, // single-select (use higher for multi-select)
  },
});

// Send status/stories broadcast
await sock.sendMessage("status@broadcast", {
  text: "System maintenance at 3 AM UTC",
});
```

### Access Control

```typescript
// Allowlist-based access control
const ALLOWED_USERS = new Set([
  "44123456789@s.whatsapp.net", // Phone number JID format
  "44987654321@s.whatsapp.net",
]);

const ADMIN_USERS = new Set(["44123456789@s.whatsapp.net"]);

function isAllowed(sender: string): boolean {
  // Empty allowlist = allow all
  if (ALLOWED_USERS.size === 0) return true;
  return ALLOWED_USERS.has(sender);
}

function isAdmin(sender: string): boolean {
  return ADMIN_USERS.has(sender);
}

// In message handler
sock.ev.on("messages.upsert", async ({ messages, type }) => {
  if (type !== "notify") return;
  for (const msg of messages) {
    if (msg.key.fromMe) continue;
    const sender = msg.key.remoteJid?.endsWith("@g.us")
      ? msg.key.participant!
      : msg.key.remoteJid!;

    if (!isAllowed(sender)) {
      console.log(`Blocked message from unauthorized user: ${sender}`);
      continue;
    }
    // Process message...
  }
});
```

### Group Management

```typescript
// Get group metadata
const groupMeta = await sock.groupMetadata(groupId);
console.log(groupMeta.subject); // Group name
console.log(groupMeta.participants); // Member list

// Check if bot is admin
const botJid = sock.user?.id;
const botParticipant = groupMeta.participants.find(
  (p) => p.id === botJid,
);
const isBotAdmin = botParticipant?.admin === "admin" || botParticipant?.admin === "superadmin";

// Only respond to mentions in groups (optional)
const mentionedJids = msg.message?.extendedTextMessage?.contextInfo?.mentionedJid || [];
if (isGroup && !mentionedJids.includes(botJid!)) {
  return; // Only respond when @mentioned in groups
}
```

## Security Considerations

### Encryption: What IS Protected

WhatsApp uses the **Signal Protocol** for end-to-end encryption — the same protocol used by Signal. This is genuinely strong encryption:

- **Key exchange**: Extended Triple Diffie-Hellman (X3DH) with Curve25519
- **Message encryption**: AES-256 in CBC mode
- **Message authentication**: HMAC-SHA256
- **Forward secrecy**: Double Ratchet algorithm — compromise of current keys does not reveal past messages
- **Key verification**: QR code / 60-digit security code for manual verification

**What Meta cannot read**: Message text, images, videos, voice notes, documents, and call audio are end-to-end encrypted. Meta's servers transport ciphertext they cannot decrypt.

### Metadata: What IS Harvested

**This is the critical privacy issue with WhatsApp.** Despite strong content encryption, Meta collects extensive metadata:

| Metadata Category | What Meta Collects | Used For |
|-------------------|--------------------|----------|
| **Social graph** | Who you message, how often, when | Ad targeting, "People You May Know" |
| **Group data** | Group names, participants, activity | Interest profiling, social mapping |
| **Phone contacts** | All contacts uploaded (even non-WhatsApp users) | Cross-platform identity linking |
| **Device info** | Phone model, OS, carrier, battery level, signal strength | Device fingerprinting |
| **IP addresses** | Connection IPs, approximate location | Location-based ad targeting |
| **Usage patterns** | Session duration, frequency, feature usage | Engagement profiling |
| **Profile data** | Photo, status, about text, last seen | Identity enrichment |
| **Business interactions** | Messages to/from business accounts | Commerce targeting |
| **Payments** | Transaction details (where available) | Financial profiling |
| **Registration** | Phone number, verification timestamps | Core identity |

**The analogy**: Your letters are sealed with the strongest encryption available, but the postal service photographs every envelope — recording sender, recipient, timestamp, weight, and frequency — and sells that data to advertisers.

### Server Access

- **Content**: Meta **CANNOT** read message content (E2E encryption is mathematically enforced)
- **Metadata**: Meta **HAS** and **USES** all metadata listed above for ad targeting across Facebook, Instagram, and WhatsApp
- **Backups**: Cloud backups (Google Drive / iCloud) are **NOT** E2E encrypted by default. WhatsApp offers optional E2E encrypted backups — users must explicitly enable this. Unencrypted backups are accessible to Google/Apple and law enforcement.

### Push Notifications

- iOS: Push notifications via Apple Push Notification service (APNs)
- Android: Push notifications via Firebase Cloud Messaging (FCM / Google)
- Notification metadata (sender, timing) is visible to Apple/Google
- Message content is not included in push payloads (only notification trigger)

### AI Training and Data Use

**CRITICAL WARNING**: Meta's privacy policy explicitly permits using WhatsApp metadata for AI model training and advertising:

- WhatsApp metadata feeds Meta's advertising algorithms across all Meta platforms
- Meta has integrated AI features into WhatsApp (Meta AI chatbot) that process conversations users opt into
- WhatsApp Business API messages may be processed by Meta's AI systems for business insights
- Meta's terms of service allow them to update data usage policies with notice but without requiring explicit consent
- Business accounts interacting via the official Business API have additional data shared with Meta for "business messaging quality" and analytics

### Open Source Status

- **Client**: CLOSED source — no independent audit of client-side behavior
- **Server**: CLOSED source — no verification of server-side data handling
- **Protocol**: Signal Protocol is open source and independently audited, but WhatsApp's implementation is unverifiable
- **Baileys**: MIT-licensed OPEN source reverse-engineering of WhatsApp Web protocol — community-maintained, not endorsed by Meta

### Jurisdiction

- **Meta Platforms, Inc.** — headquartered in Menlo Park, California, USA
- **Meta Platforms Ireland Ltd** — data controller for EU/EEA users
- Subject to GDPR in the EU, but Meta has been fined repeatedly (e.g., EUR 225M in 2021, EUR 1.2B in 2023) for privacy violations
- Subject to US CLOUD Act — US government can compel data disclosure
- WhatsApp has cooperated with law enforcement by providing metadata (not message content)

### Bot-Specific Risks

| Risk | Severity | Detail |
|------|----------|--------|
| **Account ban** | HIGH | WhatsApp actively detects and bans unofficial API usage (Baileys). Detection methods include behavioral analysis, API call patterns, and protocol version checks. Bans are permanent for the phone number. |
| **Phone number exposure** | MEDIUM | Bot requires a real phone number. This phone number is visible to all contacts and group members. |
| **Business API cost** | LOW | Official WhatsApp Business API requires Meta business verification, monthly fees, and per-message pricing. Avoids ban risk but grants Meta more data access. |
| **Session hijacking** | HIGH | The `auth_info_baileys/` directory contains full session credentials. Anyone with access can impersonate the WhatsApp account. Secure with 700 permissions and encrypted backups. |
| **Rate limiting** | MEDIUM | WhatsApp has aggressive anti-spam detection. Sending too many messages too quickly triggers temporary or permanent bans. |

### Comparison: Content Security vs Metadata Privacy

| Messenger | Content Security | Metadata Privacy | Open Source | Overall Privacy |
|-----------|-----------------|-------------------|-------------|-----------------|
| Signal | Excellent (Signal Protocol) | Good (minimal collection) | Yes | Excellent |
| SimpleX | Excellent (Double Ratchet) | Excellent (no identifiers) | Yes (AGPL-3.0) | Best available |
| WhatsApp | Excellent (Signal Protocol) | **Poor** (Meta harvests) | No | **Poor overall** |
| Matrix | Good (Megolm/Olm) | Moderate (server-dependent) | Yes | Good (self-hosted) |
| Telegram | Moderate (MTProto, not default E2E) | Poor (phone number, server-side) | Partial (client only) | Moderate |

**Bottom line**: WhatsApp's content encryption is as strong as Signal's. But metadata privacy is among the worst of mainstream messengers because Meta's entire business model depends on harvesting this data for advertising. Use WhatsApp when you need to reach users who are already on it — not when privacy is the primary requirement.

## aidevops Integration

### Helper Script

`whatsapp-dispatch-helper.sh` follows the same pattern as `matrix-dispatch-helper.sh` and `simplex-helper.sh`:

```bash
# Setup (interactive wizard)
whatsapp-dispatch-helper.sh setup

# Start bot (foreground)
whatsapp-dispatch-helper.sh start

# Start bot (daemon)
whatsapp-dispatch-helper.sh start --daemon

# Stop bot
whatsapp-dispatch-helper.sh stop

# Check status
whatsapp-dispatch-helper.sh status

# Test dispatch
whatsapp-dispatch-helper.sh test "Ask a question"

# View logs
whatsapp-dispatch-helper.sh logs
whatsapp-dispatch-helper.sh logs --follow
```

### Configuration

`~/.config/aidevops/whatsapp-bot.json` (600 permissions):

```json
{
  "authDir": "~/.aidevops/.agent-workspace/whatsapp-bot/auth_info_baileys",
  "allowedUsers": [
    "44123456789@s.whatsapp.net"
  ],
  "adminUsers": [
    "44123456789@s.whatsapp.net"
  ],
  "botPrefix": "/",
  "defaultRunner": "general",
  "groupMappings": {
    "120363012345678901@g.us": "code-reviewer"
  },
  "ignoreOwnMessages": true,
  "maxPromptLength": 3000,
  "responseTimeout": 600,
  "sessionIdleTimeout": 300,
  "respondToMentionsOnly": true
}
```

### Runner Dispatch

The bot dispatches to aidevops runners via `runner-helper.sh`:

```bash
# Create runners for WhatsApp chats
runner-helper.sh create general \
  --description "General AI assistant for WhatsApp"

runner-helper.sh create code-reviewer \
  --description "Code review and security analysis"
```

### Entity Resolution

WhatsApp users are resolved to entities via `entity-helper.sh`:

- **Channel**: `whatsapp`
- **Channel ID**: Phone number JID (e.g., `44123456789@s.whatsapp.net`)
- **Display name**: Push name from WhatsApp profile
- **Cross-channel**: Can link to same entity on Matrix, SimpleX, email

### Session State Management

Baileys auth state is stored at `~/.aidevops/.agent-workspace/whatsapp-bot/auth_info_baileys/`. This directory must be:

- Persisted across bot restarts (contains session keys)
- Backed up securely (grants full account access)
- Set to 700 permissions
- Never committed to version control

Conversation sessions follow the same Layer 0/1/2 model as the Matrix bot, stored in the shared `memory.db`.

## Matterbridge Integration

Matterbridge has native WhatsApp support via [whatsmeow](https://github.com/tulir/whatsmeow) (Go WhatsApp library, similar to Baileys but in Go).

```text
WhatsApp (whatsmeow)
    │
Matterbridge
    │
    ├── Matrix rooms
    ├── SimpleX contacts
    ├── Telegram groups
    ├── Discord channels
    ├── Slack workspaces
    ├── IRC channels
    └── 40+ other platforms
```

### Matterbridge Configuration

`matterbridge.toml`:

```toml
[whatsapp.mywhatsapp]
# No token needed — QR code auth on first run
# Matterbridge will display QR in terminal

[[gateway]]
name = "whatsapp-bridge"
enable = true

[[gateway.inout]]
account = "whatsapp.mywhatsapp"
channel = "120363012345678901@g.us"  # WhatsApp group JID

[[gateway.inout]]
account = "matrix.mymatrix"
channel = "#bridged-room:example.com"
```

**Key details**:

- Uses whatsmeow (Go) — more stable than Baileys for bridging
- Same QR code auth flow as Baileys
- Same account ban risk as any unofficial WhatsApp API usage
- Bridges text, images, videos, documents
- Does not bridge reactions, polls, or voice notes
- See `services/communications/matterbridge.md` for full Matterbridge setup

## Limitations

### Unofficial API (Account Ban Risk)

Baileys and whatsmeow are unofficial reverse-engineered libraries. WhatsApp's Terms of Service prohibit automated or bulk messaging via unofficial clients. Meta actively detects and permanently bans accounts using unofficial APIs. There is no appeal process for bans.

**Mitigation**: Use a dedicated phone number for the bot (not your personal number). Accept that the account may be banned at any time.

### Phone Number Required

Every WhatsApp account requires a phone number. Unlike SimpleX (no identifiers) or Matrix (email optional), there is no way to use WhatsApp without a phone number. This phone number is visible to all contacts.

### No Official Bot API for Personal Accounts

The official WhatsApp Business API is only available for business accounts with Meta business verification. Personal accounts have no official bot API — Baileys is the only option, with all the ban risks that entails.

### WhatsApp Business API Costs

The official Business API has per-conversation pricing:

| Category | Approximate Cost (varies by country) |
|----------|--------------------------------------|
| Marketing | $0.05 - $0.15 per conversation |
| Utility | $0.03 - $0.08 per conversation |
| Authentication | $0.02 - $0.06 per conversation |
| Service | Free (first 1000/month), then $0.03+ |

Plus Business Solution Provider (BSP) fees if using a third-party platform.

### File Size Limits

| Media Type | Maximum Size |
|------------|-------------|
| Image | 16 MB |
| Video | 16 MB |
| Audio | 16 MB |
| Document | 100 MB |
| Sticker | 500 KB (static), 500 KB (animated) |

### Rate Limiting

WhatsApp has aggressive anti-spam detection:

- Sending too many messages in a short period triggers warnings or bans
- New accounts have lower sending limits
- Business API has defined rate limits (varies by tier)
- Unofficial API usage has unpredictable limits — no documented thresholds

### Multi-Device Limitations

- Maximum 4 linked devices per account (1 phone + 4 companions)
- Linked devices are unlinked after 14 days of phone inactivity
- Broadcast lists and status updates have device-specific limitations
- Some features may not be available on linked devices

### No Federation

WhatsApp is a centralized, closed platform. There is no federation, no self-hosted servers, no alternative clients (officially). All traffic routes through Meta's infrastructure. You cannot run your own WhatsApp server.

### Group Limitations

- Maximum 1024 members per group
- Community groups: up to 5000 members across linked groups
- Admin-only messaging available but reduces bot utility
- No threaded conversations (all messages in single timeline)

## Related

- `.agents/services/communications/simplex.md` — SimpleX (maximum privacy, no identifiers)
- `.agents/services/communications/matrix-bot.md` — Matrix bot integration (federated, self-hosted)
- `.agents/services/communications/matterbridge.md` — Matterbridge cross-platform bridging
- `.agents/services/communications/bitchat.md` — BitChat (Bitcoin-native messaging)
- `.agents/services/communications/xmtp.md` — XMTP (Ethereum-native messaging)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/voice/speech-to-speech.md` — Voice note transcription
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Baileys GitHub: https://github.com/WhiskeySockets/Baileys
- WhatsApp Business API: https://developers.facebook.com/docs/whatsapp/
- Signal Protocol: https://signal.org/docs/
- whatsmeow (Go library): https://github.com/tulir/whatsmeow
