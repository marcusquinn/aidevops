---
description: WhatsApp bot integration via Baileys (TypeScript, unofficial WhatsApp Web API) — QR linking, multi-device, messaging features, access control, privacy/security assessment, aidevops runner dispatch, Matterbridge bridging
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

# WhatsApp Bot Integration (Baileys)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: WhatsApp Web API client — unofficial, reverse-engineered protocol
- **Library**: [Baileys](https://github.com/WhiskeySockets/Baileys) (TypeScript, MIT, 10K+ stars)
- **Runtime**: Node.js 20+ or Bun
- **Protocol**: WhatsApp multi-device (linked device, no phone required after pairing)
- **Encryption**: Signal Protocol E2E for message content (implemented by WhatsApp, not Baileys)
- **Auth**: QR code scan or pairing code from WhatsApp mobile app
- **Session store**: File-based example (`useMultiFileAuthState`) included; SQLite, Redis, PostgreSQL require custom `AuthenticationState` implementation
- **Docs**: https://github.com/WhiskeySockets/Baileys | https://whiskeysockets.github.io/Baileys/
- **npm**: `baileys` (formerly `@whiskeysockets/baileys`, which may stop receiving updates)

**Key differentiator**: Baileys connects as a linked device to an existing WhatsApp account, giving access to the full WhatsApp feature set (DMs, groups, media, reactions, polls, status broadcasts) without the WhatsApp Business API's approval process or per-conversation pricing. However, it is unofficial and carries ToS violation risk.

**When to use WhatsApp (Baileys) vs other protocols**:

| Criterion | WhatsApp (Baileys) | WhatsApp Business API | SimpleX | Matrix |
|-----------|--------------------|-----------------------|---------|--------|
| Official API | No (reverse-engineered) | Yes (Meta-approved) | N/A | N/A |
| Cost | Free (library is MIT) | Per-conversation pricing | Free | Free |
| Approval required | No | Yes (Meta review) | No | No |
| Account ban risk | Yes (ToS violation) | No | No | No |
| Phone number required | Yes | Yes | No | Optional |
| E2E encryption | Signal Protocol | Signal Protocol | Double ratchet | Megolm (optional) |
| Metadata privacy | Poor (Meta harvests) | Poor (Meta harvests) | Excellent | Moderate |
| Group messaging | Yes (1024 members) | Limited | Yes (experimental) | Yes (production) |
| Media support | Full | Full | Full | Full |
| Bot ecosystem | Community libraries | Official SDK | Growing | Mature |
| Best for | Existing WhatsApp users, rapid prototyping | Production business messaging | Maximum privacy | Team collaboration |

<!-- AI-CONTEXT-END -->

## Architecture

```text
+---------------------------+
| WhatsApp Mobile App       |
| (iOS / Android)           |
| - Primary device          |
| - Scans QR to link bot    |
+-------------+-------------+
              |
              | WhatsApp multi-device protocol
              | (Signal Protocol E2E encryption)
              |
+-------------v-------------+     +---------------------------+
| WhatsApp Servers          |     | Meta Infrastructure       |
| (Closed-source)           |     | - Metadata collection     |
|                           |     | - Contact graph           |
| - Message relay           |     | - Usage analytics         |
| - Media storage           |     | - Ad targeting signals    |
| - Push notifications      |     | - AI model training data  |
+-------------+-------------+     +---------------------------+
              |
              | Noise protocol (encrypted transport)
              |
+-------------v-------------+
| Baileys Client            |
| (Node.js / Bun process)   |
|                           |
| +-- Auth store (session)  |
| +-- Message handler       |
| +-- Media encoder/decoder |
| +-- Group manager         |
| +-- Event emitter         |
+-------------+-------------+
              |
              | Application logic
              |
+-------------v-------------+
| Bot Process               |
| (TypeScript / Bun)        |
|                           |
| +-- Command router        |
| +-- Access control        |
| +-- aidevops dispatch     |
| +-- Matterbridge relay    |
+---------------------------+
```

**Message flow**:

1. Bot process starts Baileys, loads session from auth store
2. If no session: generates QR code for scanning with WhatsApp mobile app
3. After linking: Baileys maintains a persistent WebSocket to WhatsApp servers
4. Incoming messages arrive as events (`messages.upsert`)
5. Bot processes message, optionally dispatches to aidevops runner
6. Outgoing messages sent via Baileys API, encrypted by Signal Protocol layer
7. WhatsApp servers relay to recipient(s)

**Multi-device model**: Baileys registers as a "linked device" (like WhatsApp Web/Desktop). The primary phone does not need to stay online after initial pairing. Sessions persist across restarts if the auth store is preserved.

## Installation

### npm / Bun

```bash
# npm
npm install baileys

# Bun (recommended — faster, native WebSocket)
bun add baileys

# Optional: better performance for protobuf
npm install @bufbuild/protobuf
```

### Dependencies

| Package | Purpose | Required |
|---------|---------|----------|
| `baileys` | WhatsApp Web API client | Yes |
| `qrcode-terminal` | QR code display in terminal | Yes (for QR linking) |
| `pino` | Logging (Baileys uses pino internally) | Yes |
| `link-preview-js` | URL preview generation | Optional |
| `sharp` | Image processing (thumbnails, stickers) | Optional |
| `fluent-ffmpeg` | Audio/video processing | Optional |

### Minimal Setup

```typescript
import makeWASocket, {
  DisconnectReason,
  useMultiFileAuthState,
  WASocket,
  proto,
  downloadMediaMessage,
} from "baileys"
import { Boom } from "@hapi/boom"
import pino from "pino"
import QRCode from "qrcode-terminal"

async function startBot(): Promise<void> {
  // Auth state persisted to ./auth_info/ directory
  const { state, saveCreds } = await useMultiFileAuthState("./auth_info")

  const sock: WASocket = makeWASocket({
    auth: state,
    logger: pino({ level: "warn" }),
    printQRInTerminal: true,
    // Browser identification shown in WhatsApp linked devices list
    browser: ["aidevops Bot", "Chrome", "1.0.0"],
  })

  // Save credentials on update (session persistence)
  sock.ev.on("creds.update", saveCreds)

  // Handle connection state changes
  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect, qr } = update

    if (qr) {
      // QR code displayed by printQRInTerminal option
      console.log("Scan QR code with WhatsApp mobile app")
    }

    if (connection === "close") {
      const reason = (lastDisconnect?.error as Boom)?.output?.statusCode
      const shouldReconnect = reason !== DisconnectReason.loggedOut
      console.log(`Connection closed: ${reason}. Reconnect: ${shouldReconnect}`)
      if (shouldReconnect) {
        setTimeout(() => startBot(), 3000) // Reconnect after backoff delay
      }
    }

    if (connection === "open") {
      console.log("Connected to WhatsApp")
    }
  })

  // Handle incoming messages
  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return

    for (const msg of messages) {
      // Skip own messages and protocol messages
      if (msg.key.fromMe) continue
      if (!msg.message) continue

      const sender = msg.key.remoteJid!
      const text =
        msg.message.conversation ||
        msg.message.extendedTextMessage?.text ||
        ""

      console.log(`[${sender}]: ${text}`)

      // Echo example — replace with command router
      if (text.startsWith("/ping")) {
        await sock.sendMessage(sender, { text: "pong" })
      }
    }
  })
}

startBot()
```

## QR Code Linking

### Terminal QR (Default)

```typescript
const sock = makeWASocket({
  auth: state,
  printQRInTerminal: true, // Prints QR to stdout
})
```

### Pairing Code (Phone Number)

Alternative to QR scanning — enter a code on the phone instead:

```typescript
const sock = makeWASocket({
  auth: state,
  printQRInTerminal: false,
})

// Request pairing code for a phone number
if (!sock.authState.creds.registered) {
  const code = await sock.requestPairingCode("1234567890")
  console.log(`Enter this code on your phone: ${code}`)
  // User enters code in WhatsApp > Linked Devices > Link with phone number
}
```

### Session Persistence

After initial QR/pairing, the session is stored in the auth state directory. Subsequent starts reconnect automatically without QR scanning.

```typescript
// File-based (default — simple, good for single instance)
const { state, saveCreds } = await useMultiFileAuthState("./auth_info")

// Custom store (production — requires your own implementation)
// Implement AuthenticationState interface for SQLite, Redis, or PostgreSQL:
// - get/set for creds (SignalIdentity)
// - get/set/delete for keys (pre-keys, sessions, sender-keys)
// Note: useMultiFileAuthState is a non-production example only
```

**Session invalidation**: WhatsApp may invalidate linked device sessions after ~14 days of inactivity or if the primary phone unlinks the device. Monitor `connection.update` for `DisconnectReason.loggedOut` and alert for re-linking.

## Multi-Device Support

Baileys operates as a linked device under WhatsApp's multi-device architecture:

- **No phone dependency**: After initial QR pairing, the phone does not need to stay online
- **Up to 4 linked devices**: WhatsApp allows 4 linked devices per account (phone + 3 companions, or phone + 4 with WhatsApp Business)
- **Independent encryption**: Each linked device has its own Signal Protocol session keys
- **Message sync**: Messages are delivered to all linked devices independently by WhatsApp servers
- **History sync**: On linking, WhatsApp sends recent message history (configurable, default ~3 months)

### Running Multiple Bots

Each bot needs a separate WhatsApp account (phone number). You cannot run multiple Baileys instances on the same account — they share the linked device slots.

```bash
# Bot 1: uses phone number +1...
node bot.js --auth-dir ./auth_bot1

# Bot 2: uses phone number +44...
node bot.js --auth-dir ./auth_bot2
```

## Messaging Features

### Text Messages

```typescript
// Simple text
await sock.sendMessage(jid, { text: "Hello!" })

// With mentions
await sock.sendMessage(groupJid, {
  text: "@user1 @user2 check this out",
  mentions: ["user1@s.whatsapp.net", "user2@s.whatsapp.net"],
})

// Reply to a message
await sock.sendMessage(jid, { text: "Replying to you" }, { quoted: originalMsg })

// With link preview
await sock.sendMessage(jid, {
  text: "Check out https://example.com",
  // Baileys auto-generates preview if link-preview-js is installed
})
```

### Media Messages

```typescript
import { readFileSync } from "fs"

// Image
await sock.sendMessage(jid, {
  image: readFileSync("./photo.jpg"),
  caption: "Photo caption",
  mimetype: "image/jpeg",
})

// Image from URL
await sock.sendMessage(jid, {
  image: { url: "https://example.com/photo.jpg" },
  caption: "From URL",
})

// Video
await sock.sendMessage(jid, {
  video: readFileSync("./video.mp4"),
  caption: "Video caption",
  mimetype: "video/mp4",
})

// Audio (voice note)
await sock.sendMessage(jid, {
  audio: readFileSync("./voice.ogg"),
  mimetype: "audio/ogg; codecs=opus",
  ptt: true, // Push-to-talk (voice note UI)
})

// Document
await sock.sendMessage(jid, {
  document: readFileSync("./report.pdf"),
  mimetype: "application/pdf",
  fileName: "report.pdf",
})

// Sticker
await sock.sendMessage(jid, {
  sticker: readFileSync("./sticker.webp"),
  // Must be 512x512 WebP
})

// Location
await sock.sendMessage(jid, {
  location: { degreesLatitude: 51.5074, degreesLongitude: -0.1278 },
})

// Contact card (vCard)
await sock.sendMessage(jid, {
  contacts: {
    displayName: "John Doe",
    contacts: [
      {
        vcard:
          "BEGIN:VCARD\nVERSION:3.0\nFN:John Doe\nTEL:+1234567890\nEND:VCARD",
      },
    ],
  },
})
```

### Downloading Media

```typescript
import { downloadMediaMessage } from "baileys"
import { writeFileSync } from "fs"

sock.ev.on("messages.upsert", async ({ messages }) => {
  for (const msg of messages) {
    if (msg.message?.imageMessage) {
      const buffer = await downloadMediaMessage(msg, "buffer", {})
      writeFileSync("./downloaded.jpg", buffer as Buffer)
    }
  }
})
```

### Reactions

```typescript
// Send reaction
await sock.sendMessage(jid, {
  react: {
    text: "👍", // Emoji reaction
    key: originalMsg.key, // Message to react to
  },
})

// Remove reaction
await sock.sendMessage(jid, {
  react: {
    text: "", // Empty string removes reaction
    key: originalMsg.key,
  },
})
```

### Polls

```typescript
// Create poll
await sock.sendMessage(jid, {
  poll: {
    name: "What should we work on next?",
    values: ["Feature A", "Feature B", "Bug fixes", "Documentation"],
    selectableCount: 1, // Single choice (use higher for multi-select)
  },
})

// Poll votes arrive as messages.update events
sock.ev.on("messages.update", (updates) => {
  for (const update of updates) {
    if (update.update?.pollUpdates) {
      // Process poll votes
      const pollVotes = update.update.pollUpdates
      console.log("Poll votes:", pollVotes)
    }
  }
})
```

### Read Receipts and Presence

```typescript
// Mark message as read
await sock.readMessages([msg.key])

// Send typing indicator
await sock.sendPresenceUpdate("composing", jid)

// Clear typing indicator
await sock.sendPresenceUpdate("paused", jid)

// Set online/offline presence
await sock.sendPresenceUpdate("available")
await sock.sendPresenceUpdate("unavailable")
```

### Status Broadcasts

```typescript
// Post text status
await sock.sendMessage("status@broadcast", { text: "Bot is online!" })

// Post image status
await sock.sendMessage("status@broadcast", {
  image: readFileSync("./status.jpg"),
  caption: "Daily update",
})
```

## Group Management

```typescript
// Create group
const group = await sock.groupCreate("Project Team", [
  "user1@s.whatsapp.net",
  "user2@s.whatsapp.net",
])
console.log("Group JID:", group.id)

// Get group metadata
const metadata = await sock.groupMetadata(groupJid)
console.log("Members:", metadata.participants.length)

// Add members
await sock.groupParticipantsUpdate(groupJid, ["user3@s.whatsapp.net"], "add")

// Remove members
await sock.groupParticipantsUpdate(groupJid, ["user3@s.whatsapp.net"], "remove")

// Promote to admin
await sock.groupParticipantsUpdate(groupJid, ["user1@s.whatsapp.net"], "promote")

// Demote from admin
await sock.groupParticipantsUpdate(groupJid, ["user1@s.whatsapp.net"], "demote")

// Update group subject (name)
await sock.groupUpdateSubject(groupJid, "New Group Name")

// Update group description
await sock.groupUpdateDescription(groupJid, "New description")

// Group settings
await sock.groupSettingUpdate(groupJid, "announcement") // Only admins can send
await sock.groupSettingUpdate(groupJid, "not_announcement") // All can send
await sock.groupSettingUpdate(groupJid, "locked") // Only admins edit info
await sock.groupSettingUpdate(groupJid, "unlocked") // All can edit info

// Leave group
await sock.groupLeave(groupJid)

// Get invite code
const code = await sock.groupInviteCode(groupJid)
console.log(`https://chat.whatsapp.com/${code}`)
```

## JID Format

WhatsApp uses JIDs (Jabber IDs) to identify chats:

| Type | Format | Example |
|------|--------|---------|
| Individual | `<phone>@s.whatsapp.net` | `1234567890@s.whatsapp.net` |
| Group | `<id>@g.us` | `120363012345678901@g.us` |
| Status broadcast | `status@broadcast` | `status@broadcast` |
| Business | `<phone>@s.whatsapp.net` | Same as individual |

**Phone number format**: Country code + number, no `+` prefix, no spaces or dashes.

## Access Control

### Allowlist Pattern

```typescript
// Configuration
const ALLOWED_USERS = new Set([
  "1234567890@s.whatsapp.net", // Admin
  "0987654321@s.whatsapp.net", // Developer
])

const ALLOWED_GROUPS = new Set([
  "120363012345678901@g.us", // Dev team group
])

const ADMIN_USERS = new Set([
  "1234567890@s.whatsapp.net", // Can run privileged commands
])

function isAuthorized(jid: string, sender: string): boolean {
  // Check individual DM
  if (jid.endsWith("@s.whatsapp.net")) {
    return ALLOWED_USERS.has(jid)
  }
  // Check group + sender within group
  if (jid.endsWith("@g.us")) {
    return ALLOWED_GROUPS.has(jid) && ALLOWED_USERS.has(sender)
  }
  return false
}

function isAdmin(sender: string): boolean {
  return ADMIN_USERS.has(sender)
}
```

### Command Permission Levels

| Level | Commands | Who |
|-------|----------|-----|
| Public | `/help`, `/status`, `/ping` | All allowed users |
| Standard | `/ask`, `/search`, `/summarize` | Allowed users |
| Privileged | `/run`, `/deploy`, `/task` | Admin users only |
| Owner | `/config`, `/allow`, `/deny` | Bot owner only |

### Rate Limiting

```typescript
const rateLimits = new Map<string, number[]>()
const MAX_REQUESTS = 10
const WINDOW_MS = 60_000 // 1 minute

function isRateLimited(sender: string): boolean {
  const now = Date.now()
  const timestamps = rateLimits.get(sender) || []
  const recent = timestamps.filter((t) => now - t < WINDOW_MS)
  if (recent.length >= MAX_REQUESTS) return true
  recent.push(now)
  rateLimits.set(sender, recent)
  return false
}
```

## Privacy and Security Assessment

### What Is Protected (Signal Protocol E2E)

WhatsApp uses the Signal Protocol for end-to-end encryption of message content:

- **Message text**: E2E encrypted between sender and recipient devices
- **Media files**: E2E encrypted (images, videos, audio, documents)
- **Voice/video calls**: E2E encrypted
- **Group messages**: Each message encrypted per-member (sender keys)
- **Status broadcasts**: E2E encrypted to viewers

Baileys does not implement encryption itself — it uses WhatsApp's built-in Signal Protocol implementation via the linked device protocol. The encryption is handled by the WhatsApp client layer, not by Baileys.

### What Is NOT Protected (Metadata Harvesting)

**Meta collects extensive metadata** regardless of E2E encryption:

| Data Category | What Meta Collects | Used For |
|---------------|-------------------|----------|
| **Contact graph** | Who you message, how often, when | Social graph analysis, ad targeting |
| **Group membership** | All groups, members, join/leave times | Interest profiling |
| **Usage patterns** | Online/offline times, app usage duration | Behavioral profiling |
| **Device info** | Phone model, OS, IP address, battery level | Device fingerprinting |
| **Location** | IP-based location, shared locations | Geographic targeting |
| **Phone number** | Required for account creation | Identity linking across Meta services |
| **Message timing** | Send/receive timestamps, read receipts | Activity pattern analysis |
| **Media metadata** | File sizes, types, frequency | Content profiling |
| **Business interactions** | Messages to business accounts | Commercial interest profiling |
| **Push notifications** | Via FCM (Google) / APNs (Apple) | Google/Apple learn message timing |

### Critical Privacy Warnings

1. **Meta's privacy policy** explicitly allows using metadata for ad targeting across Facebook, Instagram, and WhatsApp
2. **WhatsApp Business API messages** may be processed by Meta's AI systems for business features
3. **Backups** (Google Drive / iCloud) are encrypted with a user-provided password OR Meta-held key — if the user chose Meta-held key, Meta can read backed-up messages
4. **Link previews** are generated server-side for some content, potentially exposing URLs to Meta
5. **Phone number is mandatory** — ties the account to a real-world identity
6. **Closed-source server** — no way to verify what the server actually does with data
7. **AI features** (Meta AI in WhatsApp) process message content when invoked by users

### Terms of Service Risk (Baileys)

**Baileys is an unofficial, reverse-engineered client.** Using it violates WhatsApp's Terms of Service:

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Account ban** | Medium-High | Loss of WhatsApp account | Use a dedicated number, not personal |
| **IP ban** | Low-Medium | Need new IP to reconnect | Use residential proxy or VPN |
| **Legal action** | Very Low | Cease and desist | Baileys is MIT-licensed; Meta targets large-scale abuse |
| **API changes** | High | Bot breaks until Baileys updates | Pin Baileys version, monitor releases |
| **Rate limiting** | Medium | Temporary send restrictions | Implement delays between messages |

**Mitigation strategy**:

- Use a **dedicated phone number** (prepaid SIM) — never your personal number
- Implement **human-like delays** between messages (2-5 seconds)
- Avoid **bulk messaging** or rapid group operations
- Keep **message volume reasonable** (not thousands per day)
- Monitor the [Baileys GitHub](https://github.com/WhiskeySockets/Baileys) for breaking changes
- Have a **fallback plan** (WhatsApp Business API, or alternative protocol) if banned

### Comparison with Privacy-Respecting Alternatives

| Aspect | WhatsApp | SimpleX | Matrix | XMTP |
|--------|----------|---------|--------|------|
| Message content | E2E encrypted | E2E encrypted | E2E optional | E2E encrypted |
| Metadata collection | Extensive (Meta) | Minimal (stateless) | Moderate (server) | Minimal (nodes) |
| Identity required | Phone number | None | Optional | Wallet/DID |
| Server source code | Closed | Open (AGPL-3.0) | Open (Apache-2.0) | Open (MIT) |
| Data used for ads | Yes | No | No | No |
| Regulatory compliance | GDPR (with caveats) | GDPR-friendly | GDPR-friendly | GDPR-friendly |
| Recommendation | Use only when recipients are already on WhatsApp | Preferred for privacy | Preferred for teams | Preferred for Web3 |

**Bottom line**: WhatsApp provides strong message content encryption but poor metadata privacy. Use it when you need to reach people who are already on WhatsApp. For new deployments where you control both ends, prefer SimpleX (maximum privacy) or Matrix (team collaboration).

## aidevops Runner Dispatch Integration

### Command Router Pattern

```typescript
import { WASocket, proto } from "baileys"

interface CommandContext {
  sock: WASocket
  msg: proto.IWebMessageInfo
  sender: string
  jid: string
  args: string
  isAdmin: boolean
  isGroup: boolean
}

type CommandHandler = (ctx: CommandContext) => Promise<void>

const commands = new Map<string, CommandHandler>()

// Register commands
commands.set("/help", async (ctx) => {
  const helpText = [
    "*Available Commands:*",
    "/help - Show this message",
    "/status - Bot status",
    "/ask <question> - Ask AI a question",
    "/task <description> - Create a task",
    "/run <command> - Run a command (admin only)",
  ].join("\n")
  await ctx.sock.sendMessage(ctx.jid, { text: helpText })
})

commands.set("/ask", async (ctx) => {
  if (!ctx.args) {
    await ctx.sock.sendMessage(ctx.jid, { text: "Usage: /ask <question>" })
    return
  }
  await ctx.sock.sendPresenceUpdate("composing", ctx.jid)

  // Dispatch to aidevops runner
  const response = await dispatchToRunner("general", ctx.args, ctx.sender)
  await ctx.sock.sendMessage(ctx.jid, { text: response })
})

commands.set("/run", async (ctx) => {
  if (!ctx.isAdmin) {
    await ctx.sock.sendMessage(ctx.jid, { text: "Admin only." })
    return
  }
  // Dispatch privileged command
  const response = await dispatchToRunner("ops", ctx.args, ctx.sender)
  await ctx.sock.sendMessage(ctx.jid, { text: response })
})

// Message handler
async function handleMessage(
  sock: WASocket,
  msg: proto.IWebMessageInfo,
): Promise<void> {
  const text =
    msg.message?.conversation ||
    msg.message?.extendedTextMessage?.text ||
    ""
  if (!text.startsWith("/")) return

  const jid = msg.key.remoteJid!
  const sender = msg.key.participant || jid // participant set in groups
  const isGroup = jid.endsWith("@g.us")

  if (!isAuthorized(jid, sender)) return
  if (isRateLimited(sender)) {
    await sock.sendMessage(jid, { text: "Rate limited. Try again shortly." })
    return
  }

  const [cmd, ...rest] = text.split(" ")
  const handler = commands.get(cmd.toLowerCase())
  if (!handler) return

  await handler({
    sock,
    msg,
    sender,
    jid,
    args: rest.join(" "),
    isAdmin: isAdmin(sender),
    isGroup,
  })
}
```

### Runner Dispatch via Shell

```typescript
import { execFileSync } from "child_process"

async function dispatchToRunner(
  runner: string,
  prompt: string,
  sender: string,
): Promise<string> {
  try {
    // execFileSync bypasses the shell entirely — no injection risk
    // Arguments are passed as an array, never interpolated into a command string
    const result = execFileSync(
      "./runner-helper.sh",
      ["dispatch", runner, prompt],
      {
        timeout: 120_000,
        encoding: "utf-8",
        env: {
          ...process.env,
          DISPATCH_SENDER: sender,
          DISPATCH_CHANNEL: "whatsapp",
        },
      },
    )
    return result.trim() || "(no response)"
  } catch (error) {
    console.error("Runner dispatch failed:", error)
    return "Dispatch failed. Check bot logs."
  }
}
```

### Security for Runner Dispatch

1. **Use `execFileSync` with argument arrays** — never `execSync` with string interpolation. `execFileSync` bypasses the shell entirely, eliminating injection via `;`, `|`, `&&`, `$()`, backticks, and all other shell metacharacters. No input sanitization regex can match this level of safety.
2. **Treat all inbound messages as untrusted input** — even with `execFileSync`, validate that runner names match an allowlist and prompts don't exceed length limits
3. **Scan for prompt injection**: `prompt-guard-helper.sh scan "$message"` before dispatch
4. **Prefer JSON IPC over shell dispatch** — for complex payloads, write a JSON file and pass the path as an argument, or use stdin piping with `execFileSync` (set `input` option). This avoids argument length limits and encoding issues.
5. **Command sandboxing** — runner commands should run in restricted environments
6. **Credential isolation** — never expose secrets to chat context or tool output
7. **Leak detection** — scan outbound messages for credential patterns before sending
8. **Per-group permissions** — different groups can have different command access levels

Cross-reference: `tools/security/prompt-injection-defender.md`, `tools/credentials/gopass.md`

## Matterbridge Integration

Matterbridge natively supports WhatsApp via the [whatsmeow](https://github.com/tulir/whatsmeow) Go library (not Baileys). This means you can bridge WhatsApp to 20+ platforms without writing a custom bot.

### Matterbridge WhatsApp Config

```toml
# In matterbridge.toml
[whatsapp]
  [whatsapp.mywa]
  # No token needed — uses QR code pairing on first run
  # Session stored in ./whatsapp-session/ directory

[general]
RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

[[gateway]]
name="wa-matrix-bridge"
enable=true

  [[gateway.inout]]
  account="whatsapp.mywa"
  channel="120363012345678901"  # WhatsApp group JID (without @g.us)

  [[gateway.inout]]
  account="matrix.home"
  channel="#bridged:example.com"
```

### Build with WhatsApp Multi-Device Support

The default Matterbridge binary does not include WhatsApp multi-device support due to GPL3 licensing of whatsmeow. Build from source with the tag:

```bash
# Build with WhatsApp multidevice support
go install -tags whatsappmulti github.com/42wim/matterbridge@latest

# Without MS Teams (saves ~2.5GB RAM during build) + with WhatsApp
go install -tags nomsteams,whatsappmulti github.com/42wim/matterbridge@latest
```

### First Run (QR Pairing)

On first run, Matterbridge prints a QR code to the terminal. Scan it with WhatsApp on your phone (Settings > Linked Devices > Link a Device).

### Baileys vs Matterbridge (whatsmeow)

| Aspect | Baileys (custom bot) | Matterbridge (whatsmeow) |
|--------|---------------------|--------------------------|
| Language | TypeScript/Node.js | Go |
| Use case | Custom bot logic, AI dispatch | Platform bridging |
| Flexibility | Full API access | Bridge-only |
| Setup | Code required | Config file only |
| Maintenance | You maintain bot code | Matterbridge community |
| Best for | aidevops runner integration | Cross-platform chat bridging |

**Recommendation**: Use Matterbridge for pure bridging (WhatsApp <-> Matrix/Discord/etc.). Use Baileys for custom bot logic with aidevops runner dispatch. They can coexist on different WhatsApp accounts.

### Privacy at Bridge Boundaries

E2E encryption is broken at the bridge. Messages are decrypted by the bridge process and re-encrypted (or sent plaintext) for the destination platform. The bridge host has access to all message content in plaintext. See `tools/security/opsec.md` for implications.

## Connection Management

### Reconnection Strategy

```typescript
sock.ev.on("connection.update", (update) => {
  const { connection, lastDisconnect } = update

  if (connection === "close") {
    const statusCode = (lastDisconnect?.error as Boom)?.output?.statusCode

    switch (statusCode) {
      case DisconnectReason.loggedOut:
        // Session invalidated — need new QR scan
        console.error("Logged out. Delete auth_info/ and restart for new QR.")
        break
      case DisconnectReason.restartRequired:
        // Normal restart — reconnect after short delay to avoid stack growth
        setTimeout(() => startBot(), 1000)
        break
      case DisconnectReason.connectionClosed:
      case DisconnectReason.connectionLost:
      case DisconnectReason.timedOut:
        // Network issue — reconnect with backoff
        setTimeout(() => startBot(), 5000)
        break
      default:
        // Unknown — reconnect with longer backoff
        setTimeout(() => startBot(), 15000)
    }
  }
})
```

### Health Monitoring

```typescript
let lastMessageTime = Date.now()

// Update on any message
sock.ev.on("messages.upsert", () => {
  lastMessageTime = Date.now()
})

// Periodic health check
setInterval(() => {
  const silentMinutes = (Date.now() - lastMessageTime) / 60_000
  if (silentMinutes > 30) {
    console.warn(`No messages for ${silentMinutes.toFixed(0)} minutes`)
    // Optionally: send a keepalive or alert
  }
}, 300_000) // Check every 5 minutes
```

## Limitations

### Account Ban Risk

Baileys is unofficial. WhatsApp actively detects and bans accounts using unofficial clients. Risk increases with:

- High message volume
- Rapid group operations
- Bulk contact additions
- Automated behavior without human-like delays

**Mitigation**: Dedicated number, rate limiting, human-like delays. See [Terms of Service Risk](#terms-of-service-risk-baileys).

### No Voice/Video Calls

Baileys does not support voice or video calls. WhatsApp's call protocol is separate from the messaging protocol and is not reverse-engineered in Baileys.

### History Sync Limitations

On linking, WhatsApp sends recent history, but:

- History may be incomplete (depends on WhatsApp's sync behavior)
- Very old messages may not be synced
- Media from old messages may not be downloadable

### Platform Dependency

WhatsApp is a closed-source platform controlled by Meta. Any protocol change can break Baileys without warning. The library maintainers typically update within days, but downtime is possible.

### Group Size

WhatsApp groups support up to 1024 members. For larger communities, WhatsApp Communities (groups of groups) support more, but Baileys support for Communities features may lag behind the official app.

### No Desktop-Only Account

A phone number and the WhatsApp mobile app are required for initial setup. There is no way to create a WhatsApp account without a phone.

## Related

- `services/communications/simplex.md` — SimpleX (maximum privacy, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge (native WhatsApp support)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, wallet identity)
- `services/communications/twilio.md` — Twilio (official WhatsApp Business API via CPaaS)
- `tools/security/opsec.md` — Platform trust matrix, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection defense for bot inputs
- Baileys GitHub: https://github.com/WhiskeySockets/Baileys
- Baileys Docs: https://whiskeysockets.github.io/Baileys/
- WhatsApp Security Whitepaper: https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf
- Matterbridge WhatsApp: https://github.com/42wim/matterbridge (build with `-tags whatsappmulti`)
