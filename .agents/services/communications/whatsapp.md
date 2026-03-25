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
- **Session store**: File-based example (`useMultiFileAuthState`) included; SQLite/Redis/PostgreSQL require custom `AuthenticationState` implementation
- **Docs**: https://github.com/WhiskeySockets/Baileys | https://whiskeysockets.github.io/Baileys/
- **npm**: `baileys` (formerly `@whiskeysockets/baileys`)

**Key differentiator**: Baileys connects as a linked device to an existing WhatsApp account, giving access to the full WhatsApp feature set without the WhatsApp Business API's approval process or per-conversation pricing. However, it is unofficial and carries ToS violation risk.

**When to use WhatsApp (Baileys) vs other protocols**:

| Criterion | WhatsApp (Baileys) | WhatsApp Business API | SimpleX | Matrix |
|-----------|--------------------|-----------------------|---------|--------|
| Official API | No (reverse-engineered) | Yes (Meta-approved) | N/A | N/A |
| Cost | Free (MIT library) | Per-conversation pricing | Free | Free |
| Approval required | No | Yes (Meta review) | No | No |
| Account ban risk | Yes (ToS violation) | No | No | No |
| Phone number required | Yes | Yes | No | Optional |
| Metadata privacy | Poor (Meta harvests) | Poor (Meta harvests) | Excellent | Moderate |
| Best for | Existing WhatsApp users, rapid prototyping | Production business messaging | Maximum privacy | Team collaboration |

<!-- AI-CONTEXT-END -->

## Architecture

```text
WhatsApp Mobile App (primary device, scans QR to link bot)
    │ WhatsApp multi-device protocol (Signal Protocol E2E)
    ▼
WhatsApp Servers + Meta Infrastructure (metadata collection, ad targeting)
    │ Noise protocol (encrypted transport)
    ▼
Baileys Client (Node.js / Bun)
    ├── Auth store (session)
    ├── Message handler
    ├── Media encoder/decoder
    └── Event emitter
    │ Application logic
    ▼
Bot Process (TypeScript / Bun)
    ├── Command router
    ├── Access control
    ├── aidevops dispatch
    └── Matterbridge relay
```

**Multi-device model**: Baileys registers as a "linked device". The primary phone does not need to stay online after initial pairing. Sessions persist across restarts if the auth store is preserved.

## Installation

```bash
npm install baileys          # or: bun add baileys
npm install @bufbuild/protobuf  # Optional: better protobuf performance
```

**Dependencies**: `baileys` (required), `qrcode-terminal` (QR linking), `pino` (logging), `link-preview-js` (optional), `sharp` (optional, thumbnails), `fluent-ffmpeg` (optional, audio/video).

### Minimal Setup

```typescript
import makeWASocket, { DisconnectReason, useMultiFileAuthState, WASocket, proto, downloadMediaMessage } from "baileys"
import { Boom } from "@hapi/boom"
import pino from "pino"

async function startBot(): Promise<void> {
  const { state, saveCreds } = await useMultiFileAuthState("./auth_info")

  const sock: WASocket = makeWASocket({
    auth: state,
    logger: pino({ level: "warn" }),
    printQRInTerminal: true,
    browser: ["aidevops Bot", "Chrome", "1.0.0"],
  })

  sock.ev.on("creds.update", saveCreds)

  sock.ev.on("connection.update", (update) => {
    const { connection, lastDisconnect } = update
    if (connection === "close") {
      const reason = (lastDisconnect?.error as Boom)?.output?.statusCode
      if (reason !== DisconnectReason.loggedOut) setTimeout(() => startBot(), 3000)
    }
    if (connection === "open") console.log("Connected to WhatsApp")
  })

  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return
    for (const msg of messages) {
      if (msg.key.fromMe || !msg.message) continue
      const sender = msg.key.remoteJid!
      const text = msg.message.conversation || msg.message.extendedTextMessage?.text || ""
      if (text.startsWith("/ping")) await sock.sendMessage(sender, { text: "pong" })
    }
  })
}

startBot()
```

## QR Code Linking

```typescript
// Terminal QR (default)
const sock = makeWASocket({ auth: state, printQRInTerminal: true })

// Pairing code (alternative to QR)
if (!sock.authState.creds.registered) {
  const code = await sock.requestPairingCode("1234567890")
  console.log(`Enter this code on your phone: ${code}`)
  // User enters in WhatsApp > Linked Devices > Link with phone number
}
```

**Session persistence**: After initial QR/pairing, the session is stored in the auth state directory. Subsequent starts reconnect automatically.

**Session invalidation**: WhatsApp may invalidate sessions after ~14 days of inactivity or if the primary phone unlinks the device. Monitor `connection.update` for `DisconnectReason.loggedOut`.

## Multi-Device Support

- **No phone dependency** after initial QR pairing
- **Up to 4 linked devices** per account (phone + 3 companions, or phone + 4 with WhatsApp Business)
- **Independent encryption**: Each linked device has its own Signal Protocol session keys
- **History sync**: On linking, WhatsApp sends recent message history (~3 months default)

**Running multiple bots**: Each bot needs a separate WhatsApp account. You cannot run multiple Baileys instances on the same account.

## Messaging Features

### Text Messages

```typescript
await sock.sendMessage(jid, { text: "Hello!" })
await sock.sendMessage(groupJid, { text: "@user1 check this", mentions: ["user1@s.whatsapp.net"] })
await sock.sendMessage(jid, { text: "Replying" }, { quoted: originalMsg })
```

### Media Messages

```typescript
import { readFileSync } from "fs"

// Image
await sock.sendMessage(jid, { image: readFileSync("./photo.jpg"), caption: "Caption", mimetype: "image/jpeg" })
await sock.sendMessage(jid, { image: { url: "https://example.com/photo.jpg" }, caption: "From URL" })

// Video
await sock.sendMessage(jid, { video: readFileSync("./video.mp4"), caption: "Caption", mimetype: "video/mp4" })

// Audio (voice note)
await sock.sendMessage(jid, { audio: readFileSync("./voice.ogg"), mimetype: "audio/ogg; codecs=opus", ptt: true })

// Document
await sock.sendMessage(jid, { document: readFileSync("./report.pdf"), mimetype: "application/pdf", fileName: "report.pdf" })

// Sticker (512x512 WebP)
await sock.sendMessage(jid, { sticker: readFileSync("./sticker.webp") })

// Location
await sock.sendMessage(jid, { location: { degreesLatitude: 51.5074, degreesLongitude: -0.1278 } })
```

### Downloading Media

```typescript
import { downloadMediaMessage } from "baileys"
sock.ev.on("messages.upsert", async ({ messages }) => {
  for (const msg of messages) {
    if (msg.message?.imageMessage) {
      const buffer = await downloadMediaMessage(msg, "buffer", {})
      writeFileSync("./downloaded.jpg", buffer as Buffer)
    }
  }
})
```

### Reactions, Polls, Presence

```typescript
// Reaction
await sock.sendMessage(jid, { react: { text: "👍", key: originalMsg.key } })
await sock.sendMessage(jid, { react: { text: "", key: originalMsg.key } })  // Remove

// Poll
await sock.sendMessage(jid, { poll: { name: "What next?", values: ["Feature A", "Feature B", "Bug fixes"], selectableCount: 1 } })
sock.ev.on("messages.update", (updates) => { /* process pollUpdates */ })

// Presence
await sock.readMessages([msg.key])
await sock.sendPresenceUpdate("composing", jid)
await sock.sendPresenceUpdate("paused", jid)

// Status broadcast
await sock.sendMessage("status@broadcast", { text: "Bot is online!" })
```

## Group Management

```typescript
const group = await sock.groupCreate("Project Team", ["user1@s.whatsapp.net", "user2@s.whatsapp.net"])
const metadata = await sock.groupMetadata(groupJid)

await sock.groupParticipantsUpdate(groupJid, ["user3@s.whatsapp.net"], "add"|"remove"|"promote"|"demote")
await sock.groupUpdateSubject(groupJid, "New Group Name")
await sock.groupUpdateDescription(groupJid, "New description")
await sock.groupSettingUpdate(groupJid, "announcement"|"not_announcement"|"locked"|"unlocked")
await sock.groupLeave(groupJid)

const code = await sock.groupInviteCode(groupJid)
console.log(`https://chat.whatsapp.com/${code}`)
```

## JID Format

| Type | Format | Example |
|------|--------|---------|
| Individual | `<phone>@s.whatsapp.net` | `1234567890@s.whatsapp.net` |
| Group | `<id>@g.us` | `120363012345678901@g.us` |
| Status broadcast | `status@broadcast` | `status@broadcast` |

**Phone number format**: Country code + number, no `+` prefix, no spaces or dashes.

## Access Control

```typescript
const ALLOWED_USERS = new Set(["1234567890@s.whatsapp.net"])
const ALLOWED_GROUPS = new Set(["120363012345678901@g.us"])
const ADMIN_USERS = new Set(["1234567890@s.whatsapp.net"])

function isAuthorized(jid: string, sender: string): boolean {
  if (jid.endsWith("@s.whatsapp.net")) return ALLOWED_USERS.has(jid)
  if (jid.endsWith("@g.us")) return ALLOWED_GROUPS.has(jid) && ALLOWED_USERS.has(sender)
  return false
}

// Rate limiting
const rateLimits = new Map<string, number[]>()
function isRateLimited(sender: string): boolean {
  const now = Date.now()
  const recent = (rateLimits.get(sender) || []).filter(t => now - t < 60_000)
  if (recent.length >= 10) return true
  recent.push(now)
  rateLimits.set(sender, recent)
  return false
}
```

**Command permission levels**: Public (`/help`, `/status`, `/ping`) → Standard (`/ask`, `/search`) → Privileged (`/run`, `/deploy`) → Owner (`/config`, `/allow`).

## Privacy and Security Assessment

### What Is Protected (Signal Protocol E2E)

Message text, media files, voice/video calls, group messages, and status broadcasts are E2E encrypted between sender and recipient devices. Baileys does not implement encryption itself — it uses WhatsApp's built-in Signal Protocol via the linked device protocol.

### What Is NOT Protected (Metadata Harvesting)

**Meta collects extensive metadata** regardless of E2E encryption:

| Data Category | What Meta Collects |
|---------------|-------------------|
| **Contact graph** | Who you message, how often, when |
| **Group membership** | All groups, members, join/leave times |
| **Usage patterns** | Online/offline times, app usage duration |
| **Device info** | Phone model, OS, IP address |
| **Location** | IP-based location, shared locations |
| **Phone number** | Required — links identity across Meta services |
| **Message timing** | Send/receive timestamps, read receipts |
| **Push notifications** | Via FCM/APNs — Google/Apple learn message timing |

### Critical Privacy Warnings

1. Meta's privacy policy allows using metadata for ad targeting across Facebook, Instagram, and WhatsApp
2. Backups (Google Drive / iCloud) may use Meta-held keys — if so, Meta can read backed-up messages
3. Phone number is mandatory — ties account to real-world identity
4. Closed-source server — no way to verify what the server actually does with data
5. AI features (Meta AI in WhatsApp) process message content when invoked

### Terms of Service Risk (Baileys)

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| **Account ban** | Medium-High | Use a dedicated number, not personal |
| **IP ban** | Low-Medium | Use residential proxy or VPN |
| **API changes** | High | Pin Baileys version, monitor releases |
| **Rate limiting** | Medium | Implement delays between messages |

**Mitigation strategy**: Dedicated phone number (prepaid SIM), human-like delays (2-5 seconds), avoid bulk messaging, keep message volume reasonable, have a fallback plan (WhatsApp Business API or alternative protocol).

### Comparison with Privacy-Respecting Alternatives

| Aspect | WhatsApp | SimpleX | Matrix | XMTP |
|--------|----------|---------|--------|------|
| Message content | E2E encrypted | E2E encrypted | E2E optional | E2E encrypted |
| Metadata collection | Extensive (Meta) | Minimal (stateless) | Moderate (server) | Minimal (nodes) |
| Identity required | Phone number | None | Optional | Wallet/DID |
| Data used for ads | Yes | No | No | No |
| Recommendation | Use only when recipients are already on WhatsApp | Preferred for privacy | Preferred for teams | Preferred for Web3 |

## aidevops Runner Dispatch Integration

### Command Router Pattern

```typescript
import { WASocket, proto } from "baileys"

interface CommandContext {
  sock: WASocket; msg: proto.IWebMessageInfo; sender: string; jid: string
  args: string; isAdmin: boolean; isGroup: boolean
}

const commands = new Map<string, (ctx: CommandContext) => Promise<void>>()

commands.set("/ask", async (ctx) => {
  if (!ctx.args) { await ctx.sock.sendMessage(ctx.jid, { text: "Usage: /ask <question>" }); return }
  await ctx.sock.sendPresenceUpdate("composing", ctx.jid)
  const response = await dispatchToRunner("general", ctx.args, ctx.sender)
  await ctx.sock.sendMessage(ctx.jid, { text: response })
})

commands.set("/run", async (ctx) => {
  if (!ctx.isAdmin) { await ctx.sock.sendMessage(ctx.jid, { text: "Admin only." }); return }
  const response = await dispatchToRunner("ops", ctx.args, ctx.sender)
  await ctx.sock.sendMessage(ctx.jid, { text: response })
})

async function handleMessage(sock: WASocket, msg: proto.IWebMessageInfo): Promise<void> {
  const text = msg.message?.conversation || msg.message?.extendedTextMessage?.text || ""
  if (!text.startsWith("/")) return
  const jid = msg.key.remoteJid!
  const sender = msg.key.participant || jid
  if (!isAuthorized(jid, sender) || isRateLimited(sender)) return
  const [cmd, ...rest] = text.split(" ")
  const handler = commands.get(cmd.toLowerCase())
  if (handler) await handler({ sock, msg, sender, jid, args: rest.join(" "), isAdmin: isAdmin(sender), isGroup: jid.endsWith("@g.us") })
}
```

### Runner Dispatch via Shell

```typescript
import { execFileSync } from "child_process"

async function dispatchToRunner(runner: string, prompt: string, sender: string): Promise<string> {
  try {
    // execFileSync bypasses the shell entirely — no injection risk
    const result = execFileSync("./runner-helper.sh", ["dispatch", runner, prompt], {
      timeout: 120_000, encoding: "utf-8",
      env: { ...process.env, DISPATCH_SENDER: sender, DISPATCH_CHANNEL: "whatsapp" },
    })
    return result.trim() || "(no response)"
  } catch (error) {
    console.error("Runner dispatch failed:", error)
    return "Dispatch failed. Check bot logs."
  }
}
```

### Security for Runner Dispatch

1. **Use `execFileSync` with argument arrays** — never `execSync` with string interpolation. `execFileSync` bypasses the shell entirely, eliminating injection via `;`, `|`, `&&`, `$()`, backticks.
2. **Treat all inbound messages as untrusted input** — validate runner names against an allowlist, enforce prompt length limits
3. **Scan for prompt injection**: `prompt-guard-helper.sh scan "$message"` before dispatch
4. **Prefer JSON IPC over shell dispatch** — for complex payloads, write a JSON file and pass the path, or use stdin piping
5. **Command sandboxing**, **credential isolation**, **leak detection**, **per-group permissions**

Cross-reference: `tools/security/prompt-injection-defender.md`, `tools/credentials/gopass.md`

## Matterbridge Integration

Matterbridge natively supports WhatsApp via [whatsmeow](https://github.com/tulir/whatsmeow) (Go, not Baileys). Bridges WhatsApp to 20+ platforms without writing a custom bot.

```toml
[whatsapp]
  [whatsapp.mywa]
  # No token needed — uses QR code pairing on first run

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

**Build with WhatsApp multi-device support** (default binary excludes it due to GPL3 licensing):

```bash
go install -tags whatsappmulti github.com/42wim/matterbridge@latest
go install -tags nomsteams,whatsappmulti github.com/42wim/matterbridge@latest  # Without MS Teams
```

| Aspect | Baileys (custom bot) | Matterbridge (whatsmeow) |
|--------|---------------------|--------------------------|
| Use case | Custom bot logic, AI dispatch | Platform bridging |
| Setup | Code required | Config file only |
| Best for | aidevops runner integration | Cross-platform chat bridging |

**Privacy at bridge boundaries**: E2E encryption is broken at the bridge. The bridge host has access to all message content in plaintext. See `tools/security/opsec.md`.

## Connection Management

```typescript
sock.ev.on("connection.update", (update) => {
  const { connection, lastDisconnect } = update
  if (connection === "close") {
    const statusCode = (lastDisconnect?.error as Boom)?.output?.statusCode
    switch (statusCode) {
      case DisconnectReason.loggedOut:
        console.error("Logged out. Delete auth_info/ and restart for new QR."); break
      case DisconnectReason.restartRequired:
        setTimeout(() => startBot(), 1000); break
      case DisconnectReason.connectionClosed:
      case DisconnectReason.connectionLost:
      case DisconnectReason.timedOut:
        setTimeout(() => startBot(), 5000); break
      default:
        setTimeout(() => startBot(), 15000)
    }
  }
})

// Health monitoring
let lastMessageTime = Date.now()
sock.ev.on("messages.upsert", () => { lastMessageTime = Date.now() })
setInterval(() => {
  const silentMinutes = (Date.now() - lastMessageTime) / 60_000
  if (silentMinutes > 30) console.warn(`No messages for ${silentMinutes.toFixed(0)} minutes`)
}, 300_000)
```

## Limitations

- **Account ban risk**: Baileys is unofficial. Risk increases with high message volume, rapid group operations, bulk contact additions, automated behavior without human-like delays. See [Terms of Service Risk](#terms-of-service-risk-baileys).
- **No voice/video calls**: Baileys does not support calls. WhatsApp's call protocol is not reverse-engineered in Baileys.
- **History sync**: May be incomplete; very old messages and their media may not be available.
- **Platform dependency**: Any WhatsApp protocol change can break Baileys without warning. Library maintainers typically update within days.
- **Group size**: Up to 1024 members. Baileys support for WhatsApp Communities features may lag behind the official app.
- **No desktop-only account**: A phone number and WhatsApp mobile app are required for initial setup.

## Related

- `services/communications/simplex.md` — SimpleX (maximum privacy, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot for aidevops runner dispatch
- `services/communications/matterbridge.md` — Multi-platform chat bridge (native WhatsApp support)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, wallet identity)
- `tools/security/opsec.md` — Platform trust matrix, metadata warnings
- `tools/security/prompt-injection-defender.md` — Prompt injection defense for bot inputs
- Baileys GitHub: https://github.com/WhiskeySockets/Baileys
- Baileys Docs: https://whiskeysockets.github.io/Baileys/
- WhatsApp Security Whitepaper: https://www.whatsapp.com/security/WhatsApp-Security-Whitepaper.pdf
- Matterbridge WhatsApp: https://github.com/42wim/matterbridge (build with `-tags whatsappmulti`)
